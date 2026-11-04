// The upload manager when the LiveView socket drops: a file handed over while
// the socket is down is ignored by LiveView, so the queue must not give up on
// it (nor feed anything) until the connection is back, and must feed a Retry
// as a fresh File. Pure queue logic, plus the hook's two connection callbacks.
//
//   node --test test/js/upload_manager_reconnect.test.cjs

const fs = require("fs");
const path = require("path");
const assert = require("node:assert");
const { test } = require("node:test");

const SOURCE = path.join(
  __dirname, "..", "..", "priv", "static", "assets", "phoenix_kit_upload_manager.js"
);

const dom = { querySelector: () => null, getElementById: () => null };

function load() {
  const window = {};
  new Function("window", "document", fs.readFileSync(SOURCE, "utf8"))(window, dom);
  return window;
}

const win = load();
const { UploadQueue } = win.PhoenixKitUploadManager;
const Hook = win.PhoenixKitHooks.UploadManager;
const { ChunkJob, chunked } = win.PhoenixKitUploadManager;

const photo = () => new File(["x".repeat(2000)], "IMG_1.jpg", { type: "image/jpeg", lastModified: 1700000000000 });

function sameBytesDifferentObject(a, b) {
  assert.notStrictEqual(a, b, "a new File object");
  assert.strictEqual(b.name, a.name);
  assert.strictEqual(b.size, a.size);
  assert.strictEqual(b.type, a.type);
  assert.strictEqual(b.lastModified, a.lastModified);
}

test("the first feed gives the picked File itself", () => {
  const q = new UploadQueue();
  const f = photo();
  const [item] = q.add([f]);
  q.next(0);
  assert.strictEqual(item.feeds, 1);
  assert.strictEqual(q.fileToFeed(item), f);
});

test("Retry after not_accepted feeds a fresh File", () => {
  const q = new UploadQueue();
  const f = photo();
  const [item] = q.add([f]);
  q.next(0);
  assert.strictEqual(q.fileToFeed(item), f);

  q.observe([], 9000);
  assert.strictEqual(item.state, "failed");
  assert.strictEqual(item.error, "not_accepted");

  q.retry(item.id);
  assert.strictEqual(item.attempts, 0, "retry starts the attempts over");
  q.next(10000);
  assert.strictEqual(item.feeds, 2, "but not the count of feeds");
  sameBytesDifferentObject(f, q.fileToFeed(item));

  // And the one after that is not the one before.
  const second = item.file;
  q.observe([], 20000);
  q.retry(item.id);
  q.next(21000);
  sameBytesDifferentObject(second, q.fileToFeed(item));
});

test("requeueUnseen returns unseen files to the queue and leaves the rest alone", () => {
  const q = new UploadQueue({ cap: 5 });
  const [unseen, seen, waiting] = q.add([
    new File(["a"], "a.jpg", { lastModified: 1 }),
    new File(["bb"], "b.jpg", { lastModified: 2 }),
    new File(["ccc"], "c.jpg", { lastModified: 3 })
  ]);
  q.tune.target = 2;
  q.next(0);
  q.observe([{ ref: "r1", key: seen.key, size: seen.size, progress: 50, done: false, error: "" }], 100);
  assert.strictEqual(unseen.state, "uploading");
  assert.strictEqual(seen.seen, true);
  assert.strictEqual(waiting.state, "queued");
  const seenBytes = seen.bytes;

  q.requeueUnseen();

  assert.strictEqual(unseen.state, "queued");
  assert.strictEqual(unseen.error, null);
  assert.strictEqual(unseen.attempts, 0, "not an attempt");
  assert.strictEqual(seen.state, "uploading");
  assert.strictEqual(seen.ref, "r1");
  assert.strictEqual(seen.bytes, seenBytes);
  assert.strictEqual(seen.attempts, 1);
  assert.strictEqual(waiting.state, "queued");
});

test("a file already tried and unseen keeps its other attempts when requeued", () => {
  const q = new UploadQueue();
  const [item] = q.add([photo()]);
  q.next(0);
  item.attempts = 2; // sent twice already, this is the second
  q.requeueUnseen();
  assert.strictEqual(item.attempts, 1);
  assert.strictEqual(item.state, "queued");
});

test("while offline nothing is fed and an unseen file is not given up on", () => {
  const q = new UploadQueue();
  const [item] = q.add([photo()]);
  q.next(0);

  q.offline = true;
  q.observe([], 60000);
  assert.strictEqual(item.state, "uploading", "no verdict while the socket is down");
  assert.strictEqual(item.error, null);

  const [late] = q.add([new File(["z"], "late.jpg", { lastModified: 9 })]);
  assert.deepStrictEqual(q.next(61000), [], "nothing is handed to a dead socket");
  assert.strictEqual(late.state, "queued");
  assert.strictEqual(late.feeds, 0);
});

test("after the reconnect the file is fed again, as a fresh File, with a fresh clock", () => {
  const q = new UploadQueue();
  const f = photo();
  const [item] = q.add([f]);
  q.next(0);

  q.offline = true;
  q.observe([], 60000);
  q.offline = false;
  q.requeueUnseen();
  q.observe([], 60100);
  assert.strictEqual(item.state, "queued");

  const fed = q.next(60200);
  assert.deepStrictEqual(fed.map((i) => i.id), [item.id]);
  assert.strictEqual(item.fedAt, 60200);
  sameBytesDifferentObject(f, q.fileToFeed(item));

  // The grace period runs from the new feed, not from before the outage.
  q.observe([], 60200 + 7000);
  assert.strictEqual(item.state, "uploading");
  q.observe([], 60200 + 9000);
  assert.strictEqual(item.state, "failed");
});

test("the hook marks the queue offline, then on reconnect requeues and syncs", () => {
  const q = new UploadQueue();
  const [item] = q.add([photo()]);
  q.next(0);
  let syncs = 0;
  const ctx = { queue: q, sync() { syncs += 1; } };

  Hook.disconnected.call(ctx);
  assert.strictEqual(q.offline, true);
  assert.strictEqual(syncs, 0);

  Hook.reconnected.call(ctx);
  assert.strictEqual(q.offline, false);
  assert.strictEqual(item.state, "queued");
  assert.strictEqual(syncs, 1);
});

test("autoTune does not run while offline", () => {
  const q = new UploadQueue({ cap: 5 });
  q.add([photo()]);
  q.next(0);
  q.offline = true;
  const before = JSON.stringify(q.tune);
  q.autoTune(30000);
  assert.strictEqual(JSON.stringify(q.tune), before);
});

test("requeueUnseen starts the tuning over when nothing is left sending", () => {
  const q = new UploadQueue({ cap: 5 });
  const [item] = q.add([photo()]);
  q.next(0);
  q.tune.target = 4;
  q.tune.phase = "settled";
  q.requeueUnseen();
  assert.strictEqual(item.state, "queued");
  assert.strictEqual(q.tune.target, 1);
  assert.strictEqual(q.tune.phase, "probe");
});

test("requeueUnseen keeps the tuning while a file is still sending", () => {
  const q = new UploadQueue({ cap: 5 });
  q.tune.target = 2;
  const [a, b] = q.add([
    new File(["a"], "a.jpg", { lastModified: 1 }),
    new File(["bb"], "b.jpg", { lastModified: 2 })
  ]);
  q.next(0);
  q.observe([{ ref: "r1", key: b.key, size: b.size, progress: 50, done: false, error: "" }], 100);
  q.tune.phase = "settled";
  q.requeueUnseen();
  assert.strictEqual(a.state, "queued");
  assert.strictEqual(q.tune.target, 2);
  assert.strictEqual(q.tune.phase, "settled");
});

test("the stall watchdog stands down while offline and its clock does not run", () => {
  const q = new UploadQueue(); // not resumable
  const [item] = q.add([photo()]);
  q.next(0);
  const row = { ref: "r1", key: item.key, size: item.size, progress: 30, done: false, error: "" };
  q.observe([row], 100);
  q.offline = true;
  q.observe([row], 100 + 60000);
  assert.strictEqual(item.state, "uploading");
  assert.deepStrictEqual(q.observe([row], 100 + 60000), []);
  q.offline = false;
  q.observe([row], 100 + 60000 + 5000);
  assert.strictEqual(item.state, "uploading", "the time offline is not held against it");
});

test("a not_accepted verdict reached before the drop was noticed is undone on reconnect", () => {
  const q = new UploadQueue();
  const [item] = q.add([photo()]);
  q.next(0);
  q.observe([], 9000);
  assert.strictEqual(item.error, "not_accepted");

  q.requeueUnseen();
  assert.strictEqual(item.state, "queued");
  assert.strictEqual(item.error, null);
  assert.strictEqual(item.attempts, 0);
});

test("a failure that was not a missing entry stays failed on reconnect", () => {
  const q = new UploadQueue();
  const [item] = q.add([photo()]);
  q.next(0);
  q.observe([{ ref: "r1", key: item.key, size: item.size, progress: 0, done: false, error: "too_large" }], 100);
  assert.strictEqual(item.state, "failed");
  q.requeueUnseen();
  assert.strictEqual(item.state, "failed");
  assert.strictEqual(item.error, "too_large");
});

// ------------------------------------------------------- the hook's side ----
// A page stand-in: an input registered under the upload's ref, found by the
// same selector the hook uses, and a DataTransfer that keeps what it is given.

class FakeDataTransfer {
  constructor() { const list = []; this.items = { add: (f) => list.push(f) }; this.files = list; }
}
globalThis.DataTransfer = FakeDataTransfer;

function page(ref) {
  const input = {
    tagName: "INPUT", type: "file", files: [], value: "x", fed: [],
    getAttribute(name) { return name === "data-phx-upload-ref" ? input.ref : null; },
    dispatchEvent(ev) { input.fed.push({ ev, files: input.files.slice() }); return true; }
  };
  input.ref = ref;
  dom.querySelector = (sel) => {
    const m = sel.match(/data-phx-upload-ref="([^"]*)"/);
    return m && m[1] === input.ref ? input : null;
  };
  return input;
}

function hookCtx(ref) {
  const ctx = Object.assign(Object.create(Hook), {
    el: { dataset: { uploadRef: ref } },
    queue: new UploadQueue({ cap: 5 }),
    resumable: false,
    leftovers: [],
    uploadName: "photos",
    _rows: () => [],
    _announce() {},
    _saveLeftovers() {},
    render() {}
  });
  return ctx;
}

const pick = (input, files) => {
  input.files = files;
  let stopped = false;
  const ev = { target: input, stopImmediatePropagation() { stopped = true; } };
  return { ev, stopped: () => stopped };
};

test("the hook follows the upload's ref when a rejoin changes it", () => {
  const input = page("phx-OLD");
  const ctx = hookCtx("phx-OLD");
  assert.strictEqual(ctx._input(), input);

  // The rejoined LiveView registers the upload again under a new ref.
  input.ref = "phx-NEW";
  ctx.el.dataset.uploadRef = "phx-NEW";
  assert.strictEqual(ctx._input(), input, "the input is found under the new ref");

  const p = pick(input, [photo()]);
  ctx._onPick(p.ev);
  assert.ok(p.stopped(), "the pick is taken");
  assert.strictEqual(ctx.queue.items.length, 1);
});

test("a pick from an input that is not this upload's is left alone", () => {
  const input = page("phx-OTHER");
  const ctx = hookCtx("phx-NEW");
  const p = pick(input, [photo()]);
  ctx._onPick(p.ev);
  assert.ok(!p.stopped());
  assert.strictEqual(ctx.queue.items.length, 0);
});

test("a pick while offline waits, and is fed as a fresh File after reconnected", () => {
  const input = page("phx-1");
  const ctx = hookCtx("phx-1");
  const original = photo();

  Hook.disconnected.call(ctx);
  ctx._onPick(pick(input, [original]).ev);
  assert.strictEqual(input.fed.length, 0, "nothing is dispatched to a dead socket");
  assert.strictEqual(ctx.queue.items[0].state, "queued");

  // The socket comes back with a new ref, as after any rejoin.
  input.ref = "phx-2";
  ctx.el.dataset.uploadRef = "phx-2";
  Hook.reconnected.call(ctx);

  assert.strictEqual(input.fed.length, 1);
  assert.strictEqual(input.fed[0].ev.__pkUploadManagerFeed, true);
  assert.strictEqual(input.fed[0].files[0], original, "the first hand-over is the picked File");
  assert.strictEqual(ctx.queue.items[0].state, "uploading");
});

test("_feed gives LiveView what fileToFeed returns, so a re-send is a fresh File", () => {
  const input = page("phx-1");
  const ctx = hookCtx("phx-1");
  const original = photo();
  ctx._onPick(pick(input, [original]).ev);
  assert.strictEqual(input.fed[0].files[0], original);

  // Never showed up: the connection dropped and came back.
  Hook.disconnected.call(ctx);
  Hook.reconnected.call(ctx);

  assert.strictEqual(input.fed.length, 2);
  sameBytesDifferentObject(original, input.fed[1].files[0]);
  assert.strictEqual(input.fed[1].files[0], ctx.queue.items[0].file);
});

test("nothing is pushed to cancel an entry while offline", () => {
  const ctx = hookCtx("phx-1");
  const pushed = [];
  ctx.pushEvent = (...a) => pushed.push(a);
  ctx.queue.offline = true;
  ctx._cancelEntry("ref-1");
  assert.deepStrictEqual(pushed, []);
  ctx.queue.offline = false;
  ctx._cancelEntry("ref-1");
  assert.strictEqual(pushed.length, 1);
});

// -------------------------------- a file that was mid-transfer at the drop ----

function sendingSeen(q, f = photo(), ref = "7") {
  const [item] = q.add([f]);
  q.next(0);
  q.observe([{ ref, key: item.key, size: item.size, progress: 17, done: false, error: "" }], 100);
  assert.strictEqual(item.seen, true);
  return item;
}

test("a row that disappears while offline finishes nothing", () => {
  const q = new UploadQueue();
  const item = sendingSeen(q);
  q.offline = true;
  q.observe([], 200);
  q.observe([], 60000);
  assert.strictEqual(item.state, "uploading");
  assert.strictEqual(q.doneBytes, 0);
});

test("a row that disappears while connected is still a file the host consumed", () => {
  const q = new UploadQueue();
  const item = sendingSeen(q);
  q.observe([], 200);
  assert.strictEqual(item.state, "done");
});

test("requeueSeen puts a mid-transfer file back, without a failure or an attempt", () => {
  const q = new UploadQueue();
  const item = sendingSeen(q);
  const attempts = item.attempts;
  q.offline = true;

  assert.deepStrictEqual(q.requeueSeen(), ["7"], "the lost entry, to stop its transfer");
  assert.strictEqual(item.state, "queued");
  assert.strictEqual(item.error, null);
  assert.strictEqual(item.attempts, attempts - 1);
  assert.strictEqual(item.ref, null);
  assert.strictEqual(item.seen, false);
  assert.strictEqual(item.bytes, 0);
  assert.strictEqual(item.base, 0);
});

test("requeueSeen leaves finished, failed and waiting files alone", () => {
  const q = new UploadQueue();
  q.tune.target = 3;
  const [done, failed, waiting] = q.add([
    new File(["a"], "a.jpg", { lastModified: 1 }),
    new File(["bb"], "b.jpg", { lastModified: 2 }),
    new File(["ccc"], "c.jpg", { lastModified: 3 })
  ]);
  q.next(0);
  q.observe([
    { ref: "1", key: done.key, size: done.size, progress: 100, done: true, error: "" },
    { ref: "2", key: failed.key, size: failed.size, progress: 0, done: false, error: "too_large" }
  ], 100);
  assert.deepStrictEqual([done.state, failed.state, waiting.state], ["done", "failed", "uploading"]);

  q.requeueSeen();
  assert.deepStrictEqual([done.state, failed.state, waiting.state], ["done", "failed", "uploading"]);
});

test("a file paused in place is made an ordinary paused file, ready to be fed anew", () => {
  const q = new UploadQueue({ resumable: true });
  const item = sendingSeen(q);
  q.pause(item.id);
  assert.strictEqual(item.soft, true);

  assert.deepStrictEqual(q.requeueSeen(), ["7"]);
  assert.strictEqual(item.state, "paused");
  assert.strictEqual(item.soft, false);
  assert.strictEqual(item.ref, null);

  q.resume(item.id);
  assert.strictEqual(item.state, "queued", "resuming it hands it over again");
});

function fakeJob(ref) {
  const entry = { ref, meta: {}, file: { size: 100 }, progress() {}, onCancel() {}, error() {} };
  return new ChunkJob(entry);
}

test("on reconnect a mid-transfer file's old job is stopped and the file is fed as a fresh File", () => {
  const input = page("phx-1");
  const ctx = hookCtx("phx-1");
  ctx.resumable = true;
  const original = photo();
  ctx._onPick(pick(input, [original]).ev);
  const item = ctx.queue.items[0];
  item.progressAt = 0;

  // LiveView shows its entry, and a job is sending it.
  const job = fakeJob("9");
  ctx._rows = () => [{ ref: "9", key: item.key, size: item.size, progress: 17, done: false, error: "" }];
  ctx.sync();
  assert.strictEqual(item.seen, true);
  assert.notStrictEqual(chunked.info("9"), null);

  // The socket drops; the new process knows no entries.
  Hook.disconnected.call(ctx);
  ctx._rows = () => [];
  ctx.sync();
  assert.strictEqual(item.state, "uploading", "not reported done");
  assert.strictEqual(job.stopped, false, "left to carry on while the socket is down");

  Hook.reconnected.call(ctx);

  assert.strictEqual(job.stopped, true, "the old job is stopped");
  assert.strictEqual(chunked.info("9"), null);
  assert.strictEqual(item.state, "uploading", "and it is on its way again");
  assert.strictEqual(item.feeds, 2);
  assert.strictEqual(input.fed.length, 2);
  sameBytesDifferentObject(original, input.fed[1].files[0]);
  assert.strictEqual(item.attempts, 1, "no attempt was used up");
});
