// The resumable half of the upload manager: the queue's "soft" pause (a file
// keeps its place) and ChunkJob, the uploader that sends a file in pieces to
// `ResumableUpload`. The server is played by a fake XMLHttpRequest that keeps
// bytes and answers with offsets, exactly as the plug does.
//
//   node --test test/js/upload_manager_resumable.test.cjs

const fs = require("fs");
const path = require("path");
const assert = require("node:assert");
const { test } = require("node:test");
const { webcrypto } = require("node:crypto");

const SOURCE = path.join(
  __dirname, "..", "..", "priv", "static", "assets", "phoenix_kit_upload_manager.js"
);

function load(env = {}) {
  const window = { crypto: webcrypto, ...env.window };
  const fake = {
    setTimeout: env.setTimeout || ((fn) => setImmediate(fn)),
    XMLHttpRequest: env.XMLHttpRequest,
    navigator: env.navigator || { onLine: true }
  };
  new Function("window", "document", "setTimeout", "XMLHttpRequest", "navigator",
    fs.readFileSync(SOURCE, "utf8"))(window, {}, fake.setTimeout, fake.XMLHttpRequest, fake.navigator);
  return window.PhoenixKitUploadManager;
}

// ---------------------------------------------------------------- queue ----
const { UploadQueue } = load();
const file = (name, size, lastModified = 1) => ({ name, size, lastModified });

function sending(queue, f = file("a.bin", 1000)) {
  const [item] = queue.add([f]);
  queue.next(0);
  queue.observe([{ ref: "r1", key: item.key, size: f.size, progress: 40, done: false, error: "" }], 100);
  return item;
}

test("resumable: pausing a file in flight keeps its entry and its progress", () => {
  const q = new UploadQueue({ resumable: true });
  const item = sending(q);

  assert.strictEqual(q.pause(item.id), null, "nothing to cancel on the server");
  assert.strictEqual(item.state, "paused");
  assert.strictEqual(item.soft, true);
  assert.strictEqual(item.ref, "r1");
  assert.strictEqual(item.bytes, 400);
});

test("resumable: resuming goes on with the same entry; it is not handed over again", () => {
  const q = new UploadQueue({ resumable: true });
  const item = sending(q);
  q.pause(item.id);
  q.resume(item.id);

  assert.strictEqual(item.state, "uploading");
  assert.strictEqual(item.soft, false);
  assert.strictEqual(item.ref, "r1");
  assert.deepStrictEqual(q.next(200), [], "nothing new to feed");
  assert.strictEqual(item.bytes, 400, "the place is kept");
});

test("resumable: skip and restore keep the place too", () => {
  const q = new UploadQueue({ resumable: true });
  const item = sending(q);

  assert.strictEqual(q.skip(item.id), null);
  assert.strictEqual(item.state, "skipped");
  assert.strictEqual(item.bytes, 400);
  q.restore(item.id);
  assert.strictEqual(item.state, "uploading");
  assert.strictEqual(item.ref, "r1");
});

test("resumable: 'upload this next' on a stopped file resumes it in place", () => {
  const q = new UploadQueue({ resumable: true });
  const item = sending(q);
  q.pause(item.id);
  q.prioritize(item.id);

  assert.strictEqual(item.state, "uploading");
  assert.strictEqual(item.ref, "r1");
});

test("resumable: cancelling a stopped file lets go of its entry", () => {
  const q = new UploadQueue({ resumable: true });
  const item = sending(q);
  q.pause(item.id);

  assert.strictEqual(q.cancel(item.id), "r1");
  assert.strictEqual(item.state, "cancelled");
  assert.strictEqual(item.soft, false);
  assert.strictEqual(q.stale.r1, true, "an entry that comes back is cancelled again");
});

test("resumable: cancel all reaches the stopped ones", () => {
  const q = new UploadQueue({ resumable: true });
  const item = sending(q);
  q.pause(item.id);
  assert.deepStrictEqual(q.cancelAll(), ["r1"]);
});

test("not resumable: pausing a file in flight still cancels it and starts over", () => {
  const q = new UploadQueue();
  const item = sending(q);

  assert.strictEqual(q.pause(item.id), "r1");
  assert.strictEqual(item.soft, false);
  assert.strictEqual(item.bytes, 0);
  assert.strictEqual(item.ref, null);
});

test("resumable: a quiet file is not cancelled by the stall watchdog", () => {
  const q = new UploadQueue({ resumable: true });
  const item = sending(q);
  const cancels = q.observe(
    [{ ref: "r1", key: item.key, size: 1000, progress: 40, done: false, error: "" }], 100 + 120000
  );

  assert.deepStrictEqual(cancels, []);
  assert.strictEqual(item.state, "uploading");
});

test("not resumable: the same quiet file is cancelled and sent again", () => {
  const q = new UploadQueue();
  const item = sending(q);
  const cancels = q.observe(
    [{ ref: "r1", key: item.key, size: 1000, progress: 40, done: false, error: "" }], 100 + 120000
  );

  assert.deepStrictEqual(cancels, ["r1"]);
});

test("what the server already had when a resumed file began is not speed", () => {
  const q = new UploadQueue({ resumable: true });
  const item = sending(q, file("big.bin", 1000));
  item.base = 400;

  assert.strictEqual(q.movedBytes(), 0);
});

// ------------------------------------------------------------ ChunkJob ----
// The server: bytes held per url, a log of requests, switches for trouble.
function makeServer(size, { held = 0, token = "tok" } = {}) {
  return {
    size, held, token,
    body: Buffer.alloc(held),
    log: [],
    failNext: 0,       // network errors to inject on PATCH
    status: null,      // force a status on PATCH
    hold: null         // a promise a PATCH waits on before answering
  };
}

function makeXHR(server) {
  return class FakeXHR {
    constructor() { this.upload = {}; this.headers = {}; this.aborted = false; }
    open(method, url) { this.method = method; this.url = url; }
    setRequestHeader(k, v) { this.headers[k.toLowerCase()] = v; }
    getResponseHeader(k) { return this.resHeaders && this.resHeaders[k.toLowerCase()] != null ? String(this.resHeaders[k.toLowerCase()]) : null; }
    abort() {
      this.aborted = true;
      if (this.pending) { this.pending = false; this.onabort && this.onabort(); }
    }
    send(body) {
      this.pending = true;
      Promise.resolve().then(async () => {
        if (this.method === "PATCH" && server.hold) await server.hold;
        if (!this.pending) return;
        this.pending = false;
        const entry = { method: this.method, offset: this.headers["upload-offset"], token: this.headers["x-upload-token"], sha: this.headers["x-chunk-sha256"], length: body ? body.size : 0 };
        server.log.push(entry);
        if (this.method === "PATCH" && server.failNext > 0) { server.failNext -= 1; return this.onerror(); }
        const reply = (status) => { this.status = status; this.resHeaders = { "upload-offset": server.held }; this.onload && this.onload(); };
        if (this.headers["x-upload-token"] !== server.token) { this.status = 401; this.resHeaders = {}; return this.onload && this.onload(); }
        if (this.method === "GET") return reply(200);
        if (this.method === "DELETE") { server.deleted = true; return reply(204); }
        if (server.status) return reply(server.status);
        const start = parseInt(this.headers["upload-offset"], 10);
        if (start !== server.held) return reply(409);
        const buf = Buffer.from(await body.arrayBuffer());
        server.body = Buffer.concat([server.body, buf]);
        server.held += buf.length;
        reply(200);
      });
    }
  };
}

function makeEntry(bytes, server, over = {}) {
  const f = new File([bytes], "f.bin");
  const entry = {
    ref: "e" + Math.random(), file: f,
    meta: { url: "/u/x", token: server.token, chunk_size: 65536, ...over },
    pct: [], err: null, cancelCb: null,
    progress(p) { this.pct.push(p); },
    error(r) { this.err = r; },
    onCancel(cb) { this.cancelCb = cb; }
  };
  return entry;
}

function setup(server, env = {}) {
  return load({ XMLHttpRequest: makeXHR(server), ...env });
}

const until = async (fn, ms = 2000) => {
  const t = Date.now();
  while (!fn()) { if (Date.now() - t > ms) throw new Error("timed out"); await new Promise((r) => setImmediate(r)); }
};

const bytes = (n) => Buffer.from(Array.from({ length: n }, (_, i) => i % 251));

test("a file goes in chunks, in order, and LiveView is told 100 only at the end", async () => {
  const data = bytes(200000);
  const server = makeServer(data.length);
  const { ChunkJob } = setup(server);
  const entry = makeEntry(data, server);
  await new ChunkJob(entry).run();

  assert.ok(server.body.equals(data), "every byte arrived, in order");
  assert.deepStrictEqual(server.log.filter((l) => l.method === "PATCH").map((l) => l.offset), ["0", "65536", "131072", "196608"]);
  assert.strictEqual(entry.pct[entry.pct.length - 1], 100);
  assert.ok(entry.pct.slice(0, -1).every((p) => p < 100), "99 at most until the server has it all");
  assert.deepStrictEqual(entry.pct, [...entry.pct].sort((a, b) => a - b), "progress never goes back");
});

test("every chunk carries the token and a checksum", async () => {
  const data = bytes(70000);
  const server = makeServer(data.length);
  const { ChunkJob } = setup(server);
  await new ChunkJob(makeEntry(data, server)).run();

  const patches = server.log.filter((l) => l.method === "PATCH");
  assert.ok(patches.every((l) => l.token === "tok" && /^[0-9a-f]{64}$/.test(l.sha)));
});

test("a file the server already has part of goes on from there", async () => {
  const data = bytes(200000);
  const server = makeServer(data.length, { held: 131072 });
  server.body = Buffer.from(data.subarray(0, 131072));
  const { ChunkJob } = setup(server);
  const entry = makeEntry(data, server);
  const job = new ChunkJob(entry);
  await job.run();

  assert.strictEqual(job.start, 131072, "the manager is told where it began");
  assert.deepStrictEqual(server.log.filter((l) => l.method === "PATCH").map((l) => l.offset), ["131072", "196608"]);
  assert.ok(server.body.equals(data));
  assert.ok(entry.pct[0] >= 65, "progress starts where the file already was");
});

test("a file the server already has whole is finished without sending anything", async () => {
  const data = bytes(1000);
  const server = makeServer(data.length, { held: 1000 });
  server.body = Buffer.from(data);
  const { ChunkJob } = setup(server);
  const entry = makeEntry(data, server);
  await new ChunkJob(entry).run();

  assert.strictEqual(server.log.filter((l) => l.method === "PATCH").length, 0);
  assert.strictEqual(entry.pct[entry.pct.length - 1], 100);
});

test("pause stops sending; resume goes on from what the server confirms, never from the start", async () => {
  const data = bytes(262144);
  const server = makeServer(data.length);
  const { ChunkJob } = setup(server);
  const entry = makeEntry(data, server);
  const job = new ChunkJob(entry);
  const running = job.run();

  await until(() => server.held >= 65536);
  // The next chunk is on its way when the pause lands.
  let release;
  server.hold = new Promise((r) => (release = r));
  await until(() => job.xhr && job.xhr.method === "PATCH");
  const heldAtPause = server.held;
  job.pause();
  release();
  await new Promise((r) => setTimeout(r, 30));

  assert.strictEqual(server.held, heldAtPause, "the chunk on its way was dropped, not finished");
  const requestsAtPause = server.log.length;
  await new Promise((r) => setTimeout(r, 50));
  assert.strictEqual(server.held, heldAtPause, "nothing is sent while paused");
  assert.strictEqual(server.log.length, requestsAtPause, "and nothing is asked: a paused job waits, it does not spin");
  assert.ok(heldAtPause < data.length);

  server.hold = null;
  job.resume();
  await running;

  const patches = server.log.filter((l) => l.method === "PATCH").map((l) => parseInt(l.offset, 10));
  assert.ok(!patches.slice(1).includes(0), "never restarted at 0");
  assert.ok(server.body.equals(data), "the file is whole and in order");
  assert.strictEqual(entry.pct[entry.pct.length - 1], 100);
});

test("a dropped connection is retried and the file still arrives whole", async () => {
  const data = bytes(150000);
  const server = makeServer(data.length);
  server.failNext = 3;
  const { ChunkJob } = setup(server);
  const entry = makeEntry(data, server);
  const job = new ChunkJob(entry);
  await job.run();

  assert.ok(server.body.equals(data));
  assert.strictEqual(entry.err, null);
});

test("a connection that never comes back fails the entry, after the retries", async () => {
  const data = bytes(1000);
  const server = makeServer(data.length);
  server.failNext = 1000;
  const { ChunkJob } = setup(server);
  const entry = makeEntry(data, server);
  await new ChunkJob(entry).run();

  assert.strictEqual(entry.err, "network");
  assert.ok(!entry.pct.includes(100));
});

test("an offset the server disagrees with is taken from the server, not argued", async () => {
  const data = bytes(150000);
  const server = makeServer(data.length);
  const { ChunkJob } = setup(server);
  const entry = makeEntry(data, server);
  const job = new ChunkJob(entry);
  // Another tab sent the first chunk between our status check and our send.
  const first = data.subarray(0, 65536);
  const realSend = job.send.bind(job);
  let tampered = false;
  job.send = function () {
    if (!tampered) { tampered = true; server.body = Buffer.from(first); server.held = 65536; }
    return realSend();
  };
  await job.run();

  assert.ok(server.body.equals(data), "no byte twice, none missing");
});

test("a refused token fails the entry and sends no bytes", async () => {
  const data = bytes(1000);
  const server = makeServer(data.length, { token: "right" });
  const { ChunkJob } = setup(server);
  const entry = makeEntry(data, server, { token: "wrong" });
  await new ChunkJob(entry).run();

  assert.strictEqual(entry.err, "unauthorized");
  assert.strictEqual(server.held, 0);
});

test("a chunk the server calls too large fails the entry", async () => {
  const data = bytes(1000);
  const server = makeServer(data.length);
  server.status = 413;
  const { ChunkJob } = setup(server);
  const entry = makeEntry(data, server);
  await new ChunkJob(entry).run();

  assert.strictEqual(entry.err, "too_large");
});

test("an empty file is one empty chunk", async () => {
  const server = makeServer(0);
  const { ChunkJob } = setup(server);
  const entry = makeEntry(Buffer.alloc(0), server);
  await new ChunkJob(entry).run();

  assert.strictEqual(server.log.filter((l) => l.method === "PATCH").length, 1);
  assert.strictEqual(entry.pct[entry.pct.length - 1], 100);
});

test("discard stops the job and asks the server to drop the partial file", async () => {
  const data = bytes(262144);
  const server = makeServer(data.length);
  const { ChunkJob, chunked } = setup(server);
  const entry = makeEntry(data, server);
  const job = new ChunkJob(entry);
  const running = job.run();
  await until(() => server.held >= 65536);

  chunked.discard(entry.ref);
  await running;
  await new Promise((r) => setTimeout(r, 20));

  assert.strictEqual(server.deleted, true);
  assert.ok(server.held < data.length, "no more is sent");
  assert.ok(!entry.pct.includes(100));
});

test("LiveView cancelling the entry stops the job but leaves the partial file", async () => {
  const data = bytes(262144);
  const server = makeServer(data.length);
  const { ChunkJob } = setup(server);
  const entry = makeEntry(data, server);
  const running = new ChunkJob(entry).run();
  await until(() => server.held >= 65536);

  entry.cancelCb();
  await running;
  assert.notStrictEqual(server.deleted, true, "a reload or navigation must not throw the bytes away");
});

test("the manager can ask how a job is doing", async () => {
  const data = bytes(262144);
  const server = makeServer(data.length, { held: 65536 });
  server.body = Buffer.from(data.subarray(0, 65536));
  const { ChunkJob, chunked } = setup(server);
  const entry = makeEntry(data, server);
  const running = new ChunkJob(entry).run();
  await until(() => chunked.info(entry.ref) && chunked.info(entry.ref).start > 0);

  assert.strictEqual(chunked.info(entry.ref).start, 65536);
  await running;
  assert.strictEqual(chunked.info(entry.ref), null, "a finished job is forgotten");
});

test("a token that stops being good part way fails the entry and sends no more", async () => {
  const data = bytes(262144);
  const server = makeServer(data.length);
  const { ChunkJob } = setup(server);
  const entry = makeEntry(data, server);
  const running = new ChunkJob(entry).run();
  await until(() => server.held >= 65536);
  server.token = "expired";
  await running;

  assert.strictEqual(entry.err, "unauthorized");
  assert.ok(server.held < data.length);
});
