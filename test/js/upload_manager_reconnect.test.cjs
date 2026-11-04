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

function load() {
  const window = {};
  new Function("window", "document", fs.readFileSync(SOURCE, "utf8"))(window, {});
  return window;
}

const win = load();
const { UploadQueue } = win.PhoenixKitUploadManager;
const Hook = win.PhoenixKitHooks.UploadManager;

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
