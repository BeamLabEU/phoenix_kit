// The upload manager's queue: what it sends, how many at a time, and what the
// controls do. Pure logic — the file is loaded into a stub `window`.
//
//   node --test test/js/upload_manager_queue.test.cjs

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
  return window.PhoenixKitUploadManager;
}

const { UploadQueue, fileKey, formatBytes, formatDuration } = load();

const file = (name, size, lastModified = 1) => ({ name, size, lastModified });
const files = (n, size = 5_000_000) => Array.from({ length: n }, (_, i) => file(`f${i}.bin`, size, i));

// A connection: each transfer is held to `perStream` bytes/s, and all of them
// together to `link`. Time runs in 250 ms ticks, as in the page.
function simulate(queue, { perStream, link, seconds, start = 0 }) {
  let now = start;
  const rows = new Map(); // key -> {ref, key, size, bytes}
  let ref = 0;
  const trace = [];

  for (let t = 0; t < seconds * 4; t++) {
    now += 250;

    // Hand over what the queue sends; LiveView registers an entry for each.
    for (const it of queue.next(now)) {
      rows.set(it.key, { ref: `r${++ref}`, key: it.key, size: it.size, bytes: 0 });
    }

    const live = [...rows.values()];
    const share = live.length ? Math.min(perStream, link / live.length) : 0;
    for (const r of live) r.bytes = Math.min(r.size, r.bytes + share * 0.25);

    const reported = live.map((r) => ({
      ref: r.ref, key: r.key, size: r.size,
      progress: Math.floor((r.bytes / r.size) * 100), done: false, error: ""
    }));
    // A finished entry is consumed by the host and drops out of the list.
    for (const r of live) if (r.bytes >= r.size) rows.delete(r.key);

    queue.observe(reported.filter((r) => r.progress < 100 || rows.has(r.key)), now);
    queue.autoTune(now);
    trace.push({ now, target: queue.tune.target, active: queue.count("uploading") });
  }
  return { now, trace };
}

test("the key is what LiveView and the server compute", () => {
  assert.strictEqual(fileKey(file("a.png", 10, 99)), "a.png|10|99");
});

test("it starts with one file alone, as a probe", () => {
  const q = new UploadQueue({ cap: 5 });
  q.add(files(10));
  assert.strictEqual(q.next(0).length, 1);
  assert.strictEqual(q.next(10).length, 0, "no room until the probe is over");
  assert.strictEqual(q.tune.phase, "probe");
});

test("a fast, parallel-friendly connection climbs to the cap and stays there", () => {
  const q = new UploadQueue({ cap: 5 });
  q.add(files(60, 8_000_000));
  // Each transfer is limited (as a chunked websocket upload is); the link is wide.
  const { trace } = simulate(q, { perStream: 1_000_000, link: 100_000_000, seconds: 60 });

  assert.strictEqual(Math.max(...trace.map((s) => s.target)), 5);
  assert.ok(trace.every((s) => s.active <= 5), "never more than the cap in flight");
  assert.strictEqual(q.tune.target, 5);
});

test("a narrow link: extra transfers stop being added once they stop helping", () => {
  const q = new UploadQueue({ cap: 5 });
  q.add(files(60, 8_000_000));
  // One transfer already fills the link, so a second adds nothing.
  simulate(q, { perStream: 10_000_000, link: 1_000_000, seconds: 60 });

  assert.ok(q.tune.target <= 2, `settled low, got ${q.tune.target}`);
  assert.strictEqual(q.tune.phase, "hold");
});

test("a cap of one is strictly one at a time", () => {
  const q = new UploadQueue({ cap: 1 });
  q.add(files(20, 2_000_000));
  const { trace } = simulate(q, { perStream: 1_000_000, link: 100_000_000, seconds: 30 });

  assert.ok(trace.every((s) => s.active <= 1));
  assert.strictEqual(q.tune.target, 1);
});

test("the cap is held between 1 and the hard limit", () => {
  assert.strictEqual(new UploadQueue({ cap: 0 }).cap, 1);
  assert.strictEqual(new UploadQueue({ cap: 999 }).cap, 20);
  assert.strictEqual(new UploadQueue({ cap: "7" }).cap, 7);
  assert.strictEqual(new UploadQueue({}).cap, 5);
});

test("every file is sent, once, and the batch finishes", () => {
  const q = new UploadQueue({ cap: 4 });
  const added = q.add(files(25, 1_000_000));
  simulate(q, { perStream: 2_000_000, link: 50_000_000, seconds: 120 });

  assert.strictEqual(q.count("done"), 25);
  assert.ok(added.every((i) => i.attempts === 1), "no file was sent twice");
  assert.strictEqual(q.busy(), false);
});

test("the next batch waits until the last one has started moving", () => {
  const q = new UploadQueue({ cap: 5 });
  const [a] = q.add(files(4));
  q.tune.target = 3;
  assert.strictEqual(q.next(0).length, 3, "the first batch goes together");
  assert.deepStrictEqual(q.next(10), [], "no room anyway");
  q.tune.target = 4;
  assert.deepStrictEqual(q.next(20), [], "but nothing more until they have started");

  q.observe(
    q.items.slice(0, 3).map((it, i) => ({ ref: `r${i}`, key: it.key, size: it.size, progress: 3, done: false, error: "" })),
    30
  );
  assert.strictEqual(q.next(40).length, 1);
});

test("a batch that never starts does not hold the line for ever", () => {
  const q = new UploadQueue({ cap: 5 });
  const [a] = q.add(files(3));
  q.tune.target = 2;
  q.next(0);
  q.observe([{ ref: "r1", key: a.key, size: a.size, progress: 0, done: false, error: "" }], 100);
  assert.deepStrictEqual(q.next(1000), []);
  // Past the wait it is judged stalled: cancelled on the server, sent again.
  const cancel = q.observe([{ ref: "r1", key: a.key, size: a.size, progress: 0, done: false, error: "" }], 7000);
  assert.deepStrictEqual(cancel, ["r1"]);
  assert.strictEqual(a.state, "queued", "it is sent again by itself, once");
  assert.ok(q.next(7100).length >= 1);
});

test("a file that stalls twice is reported as failed", () => {
  const q = new UploadQueue({ cap: 5 });
  const [a] = q.add(files(1));
  for (const at of [0, 20000]) {
    q.next(at);
    q.observe([{ ref: "r" + at, key: a.key, size: a.size, progress: 0, done: false, error: "" }], at + 100);
    q.observe([{ ref: "r" + at, key: a.key, size: a.size, progress: 0, done: false, error: "" }], at + 7000);
  }
  assert.strictEqual(a.state, "failed");
  assert.strictEqual(a.error, "stalled");
});

test("a file that moved and then stopped is a stall too", () => {
  const q = new UploadQueue({ cap: 5 });
  const [a] = q.add(files(1, 10_000_000));
  q.next(0);
  q.observe([{ ref: "r1", key: a.key, size: a.size, progress: 20, done: false, error: "" }], 1000);
  assert.deepStrictEqual(q.observe([{ ref: "r1", key: a.key, size: a.size, progress: 20, done: false, error: "" }], 15000), []);
  assert.strictEqual(a.state, "uploading", "a pause shorter than the stall limit is fine");
  assert.deepStrictEqual(
    q.observe([{ ref: "r1", key: a.key, size: a.size, progress: 20, done: false, error: "" }], 22000), ["r1"]
  );
  assert.strictEqual(a.state, "queued");
});

test("a file sent in full and waiting for the host is not stalled", () => {
  const q = new UploadQueue({ cap: 5 });
  const [a] = q.add(files(1));
  q.next(0);
  q.observe([{ ref: "r1", key: a.key, size: a.size, progress: 100, done: false, error: "" }], 500);
  assert.deepStrictEqual(
    q.observe([{ ref: "r1", key: a.key, size: a.size, progress: 100, done: false, error: "" }], 60000), []
  );
  assert.strictEqual(a.state, "uploading");
});

test("a file LiveView never registers is reported, not waited on forever", () => {
  const q = new UploadQueue({ cap: 3 });
  const [it] = q.add([file("lost.bin", 100)]);
  q.next(0);
  q.observe([], 1000);
  assert.strictEqual(it.state, "uploading");
  q.observe([], 9000);
  assert.strictEqual(it.state, "failed");
  assert.strictEqual(it.error, "not_accepted");
});

test("an entry that comes with an error fails the file and asks for the entry to be cancelled", () => {
  const q = new UploadQueue({ cap: 3 });
  const [it] = q.add([file("big.bin", 100)]);
  q.next(0);
  const cancel = q.observe(
    [{ ref: "r1", key: it.key, size: 100, progress: 0, done: false, error: "too_large" }], 100
  );
  assert.deepStrictEqual(cancel, ["r1"]);
  assert.strictEqual(it.state, "failed");
  assert.strictEqual(it.error, "too_large");
});

test("an entry the host consumed (gone from the rows) counts as done", () => {
  const q = new UploadQueue({ cap: 3 });
  const [it] = q.add([file("a.bin", 100)]);
  q.next(0);
  q.observe([{ ref: "r1", key: it.key, size: 100, progress: 40, done: false, error: "" }], 100);
  assert.strictEqual(it.bytes, 40);
  q.observe([], 200);
  assert.strictEqual(it.state, "done");
});

test("an entry LiveView put back after the file was consumed is cancelled, once", () => {
  const q = new UploadQueue({ cap: 3 });
  const [a] = q.add([file("a.bin", 100)]);
  q.next(0);
  q.observe([{ ref: "r1", key: a.key, size: 100, progress: 50, done: false, error: "" }], 100);
  // The host consumes it: the row goes, the file is done.
  q.observe([], 200);
  assert.strictEqual(a.state, "done");

  const ghost = [{ ref: "r1", key: a.key, size: 100, progress: 0, done: false, error: "" }];
  assert.deepStrictEqual(q.observe(ghost, 300), ["r1"], "the stale entry is cancelled");
  assert.deepStrictEqual(q.observe(ghost, 550), [], "not asked again every tick");
  assert.deepStrictEqual(q.observe(ghost, 2000), ["r1"], "asked again if it is still there");
  assert.deepStrictEqual(q.observe([], 4000), []);
});

test("the entry of a file that was stopped is cancelled again if it stays", () => {
  const q = new UploadQueue({ cap: 3 });
  const [a] = q.add([file("a.bin", 100)]);
  q.next(0);
  q.observe([{ ref: "r1", key: a.key, size: 100, progress: 51, done: false, error: "" }], 100);
  assert.strictEqual(q.pause(a.id), "r1");

  const stays = [{ ref: "r1", key: a.key, size: 100, progress: 51, done: false, error: "" }];
  assert.deepStrictEqual(q.observe(stays, 200), ["r1"], "the first cancel may not have taken");
  assert.deepStrictEqual(q.observe(stays, 400), []);
  assert.deepStrictEqual(q.observe(stays, 1800), ["r1"]);
  // It gives up after a few tries rather than asking for ever.
  const tries = [3500, 5200, 6900, 8600].map((at) => q.observe(stays, at).length);
  assert.ok(tries.reduce((x, y) => x + y, 0) <= 2);
  assert.deepStrictEqual(q.observe(stays, 20000), []);
});

test("a finished file's entry that is legitimately still listed as done is left alone", () => {
  const q = new UploadQueue({ cap: 3 });
  const [a] = q.add([file("a.bin", 100)]);
  q.next(0);
  q.observe([{ ref: "r1", key: a.key, size: 100, progress: 100, done: true, error: "" }], 100);
  assert.strictEqual(a.state, "done");
  const row = [{ ref: "r1", key: a.key, size: 100, progress: 100, done: true, error: "" }];
  assert.deepStrictEqual(q.observe(row, 300), []);
});

test("entries that are not this queue's are never cancelled", () => {
  const q = new UploadQueue({ cap: 3 });
  assert.deepStrictEqual(
    q.observe([{ ref: "x9", key: "other|1|1", size: 1, progress: 0, done: false, error: "" }], 0),
    []
  );
});

test("two files with the same name, size and date do not swap entries", () => {
  const q = new UploadQueue({ cap: 4 });
  const [a, b] = q.add([file("same.bin", 100, 5), file("same.bin", 100, 5)]);
  q.tune.target = 2;
  q.next(0);
  q.observe([
    { ref: "r1", key: a.key, size: 100, progress: 10, done: false, error: "" },
    { ref: "r2", key: b.key, size: 100, progress: 70, done: false, error: "" }
  ], 100);
  assert.deepStrictEqual([a.ref, b.ref], ["r1", "r2"]);
  // Then the first entry is consumed: the same one is done, not the other.
  q.observe([{ ref: "r2", key: b.key, size: 100, progress: 80, done: false, error: "" }], 200);
  assert.strictEqual(a.state, "done");
  assert.strictEqual(b.state, "uploading");
});

test("pause: a waiting file is held; one in flight is cancelled and restarts on resume", () => {
  const q = new UploadQueue({ cap: 3 });
  const [a, b] = q.add([file("a.bin", 100, 1), file("b.bin", 100, 2)]);
  q.next(0);
  q.observe([{ ref: "r1", key: a.key, size: 100, progress: 50, done: false, error: "" }], 10);

  assert.strictEqual(q.pause(b.id), null, "nothing to cancel for a waiting file");
  assert.strictEqual(b.state, "paused");
  assert.strictEqual(q.pause(a.id), "r1", "an in-flight file's entry is cancelled");
  assert.strictEqual(a.state, "paused");
  assert.strictEqual(a.bytes, 0);

  q.tune.target = 3;
  assert.deepStrictEqual(q.next(20), [], "paused files are not sent");
  q.resume(a.id);
  assert.deepStrictEqual(q.next(30).map((i) => i.name), ["a.bin"]);
  assert.strictEqual(a.attempts, 2);
});

test("prioritise puts a file at the front of the waiting line", () => {
  const q = new UploadQueue({ cap: 5 });
  const [a, b, c] = q.add(files(3));
  q.prioritize(c.id);
  assert.deepStrictEqual(q.next(0).map((i) => i.name), [c.name]);
  q.observe([{ ref: "r1", key: c.key, size: c.size, progress: 5, done: false, error: "" }], 10);
  q.tune.target = 3;
  assert.deepStrictEqual(q.next(20).map((i) => i.name), [a.name, b.name]);
});

test("prioritising a paused file puts it back in the line, first", () => {
  const q = new UploadQueue({ cap: 5 });
  const [a, b] = q.add(files(2));
  q.pause(b.id);
  q.prioritize(b.id);
  assert.strictEqual(b.state, "queued");
  assert.deepStrictEqual(q.next(0).map((i) => i.name), [b.name]);
});

test("skip leaves it listed, and restore brings it back", () => {
  const q = new UploadQueue({ cap: 5 });
  const [a] = q.add(files(1));
  q.skip(a.id);
  assert.strictEqual(a.state, "skipped");
  assert.deepStrictEqual(q.next(0), []);
  q.restore(a.id);
  assert.strictEqual(a.state, "queued");
});

test("cancel removes a waiting file and stops one in flight", () => {
  const q = new UploadQueue({ cap: 5 });
  const [a, b] = q.add(files(2));
  q.next(0);
  q.observe([{ ref: "r9", key: a.key, size: a.size, progress: 10, done: false, error: "" }], 5);
  assert.strictEqual(q.cancel(a.id), "r9");
  assert.strictEqual(q.cancel(b.id), null);
  assert.deepStrictEqual([a.state, b.state], ["cancelled", "cancelled"]);
});

test("a failed file can be retried", () => {
  const q = new UploadQueue({ cap: 5 });
  const [a] = q.add(files(1));
  q.next(0);
  q.observe([], 20000);
  assert.strictEqual(a.state, "failed");
  q.retry(a.id);
  assert.strictEqual(a.state, "queued");
  assert.strictEqual(q.next(30000).length, 1);
});

test("pause all holds the line; resume all lets it run", () => {
  const q = new UploadQueue({ cap: 5 });
  q.add(files(3));
  q.pauseAll();
  assert.deepStrictEqual(q.next(0), []);
  q.resumeAll();
  assert.strictEqual(q.next(1).length, 1);
});

test("cancel all stops everything and returns the entries to cancel", () => {
  const q = new UploadQueue({ cap: 5 });
  const [a] = q.add(files(3));
  q.next(0);
  q.observe([{ ref: "r1", key: a.key, size: a.size, progress: 1, done: false, error: "" }], 5);
  assert.deepStrictEqual(q.cancelAll(), ["r1"]);
  assert.ok(q.items.every((i) => i.state === "cancelled"));
});

test("clearing what is finished empties the list and re-arms the probe", () => {
  const q = new UploadQueue({ cap: 5 });
  const [a] = q.add(files(1));
  q.next(0);
  q.observe([{ ref: "r1", key: a.key, size: a.size, progress: 50, done: false, error: "" }], 5);
  q.observe([], 10);
  assert.strictEqual(a.state, "done");
  q.tune.target = 4;
  q.clearFinished();
  assert.strictEqual(q.items.length, 0);
  assert.strictEqual(q.tune.target, 1);
  assert.strictEqual(q.tune.phase, "probe");
});

test("stats report the number in flight, the speed and what is left", () => {
  const q = new UploadQueue({ cap: 5 });
  const [a] = q.add(files(2, 1_000_000));
  q.next(0);
  q.observe([{ ref: "r1", key: a.key, size: a.size, progress: 0, done: false, error: "" }], 0);
  q.observe([{ ref: "r1", key: a.key, size: a.size, progress: 50, done: false, error: "" }], 1000);
  const s = q.stats(1000);

  assert.strictEqual(s.active, 1);
  assert.strictEqual(s.counts.queued, 1);
  assert.ok(s.speed > 400_000 && s.speed < 600_000, `speed ${s.speed}`);
  assert.strictEqual(s.bytesLeft, 1_500_000);
  assert.ok(s.eta > 2000 && s.eta < 4000);
});

test("formatting", () => {
  assert.strictEqual(formatBytes(999), "999 B");
  assert.strictEqual(formatBytes(1_500_000), "1.5 MB");
  assert.strictEqual(formatDuration(4000), "4s");
  assert.strictEqual(formatDuration(125000), "2m 5s");
});

test("dismiss clears what is over and keeps what still waits on the user", () => {
  const q = new UploadQueue({ cap: 3 });
  const [done, failed, cancelled, skipped, queued] = q.add(files(5, 100));
  done.state = "done"; failed.state = "failed"; cancelled.state = "cancelled";
  skipped.state = "skipped"; queued.state = "queued";

  q.dismiss();
  assert.deepStrictEqual(q.items.map((i) => i.state).sort(), ["queued", "skipped"]);
});

test("dismiss on a finished batch leaves an empty, reset queue", () => {
  const q = new UploadQueue({ cap: 3 });
  const [a, b] = q.add(files(2, 100));
  a.state = "done"; b.state = "failed";
  q.tune.target = 4;

  q.dismiss();
  assert.strictEqual(q.items.length, 0);
  assert.strictEqual(q.tune.target, 1, "the next batch probes again");
});

const { panelAfter } = load();
const counts = (o) => ({ queued: 0, uploading: 0, paused: 0, skipped: 0, done: 0, failed: 0, cancelled: 0, ...o });

test("a new batch opens a minimised panel", () => {
  assert.deepStrictEqual(panelAfter(counts({ uploading: 1 }), false, true), { live: true, collapsed: false });
});

test("a batch that ends cleanly shrinks the panel to its summary", () => {
  assert.deepStrictEqual(panelAfter(counts({ done: 5 }), true, false), { live: false, collapsed: true });
});

test("a batch that ends with a failure stays open", () => {
  assert.deepStrictEqual(panelAfter(counts({ done: 4, failed: 1 }), true, true), { live: false, collapsed: false });
});

test("the user's own choice stands while nothing changes", () => {
  assert.strictEqual(panelAfter(counts({ uploading: 2 }), true, true).collapsed, true, "minimised mid-batch stays minimised");
  assert.strictEqual(panelAfter(counts({ done: 3 }), false, false).collapsed, false, "opened after the end stays open");
});

test("paused files keep the panel live", () => {
  assert.strictEqual(panelAfter(counts({ paused: 1, done: 2 }), true, false).live, true);
});

// -- What the page hears about, and what it remembers across a reload --------
const { unfinishedOf, mergeUnfinished, withoutPicked } = load();

function item(q, state, f) {
  const [it] = q.add([f]);
  it.state = state;
  return it;
}

test("each finished or failed file is announced once", () => {
  const q = new UploadQueue();
  const a = item(q, "done", file("a.bin", 10, 1));
  item(q, "failed", file("b.bin", 20, 2)).error = "stalled";

  const first = q.takeNotices();
  assert.deepStrictEqual(first.files.map((n) => [n.type, n.name]).sort(), [["done", "a.bin"], ["failed", "b.bin"]]);
  assert.strictEqual(first.files.find((n) => n.type === "failed").error, "stalled");
  assert.strictEqual(q.takeNotices().files.length, 0, "not again");
  assert.strictEqual(a.state, "done");
});

test("a retry that fails again is news again", () => {
  const q = new UploadQueue();
  const it = item(q, "failed", file("a.bin", 10));
  q.takeNotices();

  it.state = "queued"; q.takeNotices();
  it.state = "failed";
  assert.strictEqual(q.takeNotices().files.length, 1);
});

test("the batch ends once, when the last thing in flight ends", () => {
  const q = new UploadQueue();
  const a = item(q, "uploading", file("a.bin", 10, 1));
  const b = item(q, "queued", file("b.bin", 20, 2));
  assert.strictEqual(q.takeNotices().batch, null);

  a.state = "done";
  assert.strictEqual(q.takeNotices().batch, null, "b is still waiting");

  b.state = "failed";
  const end = q.takeNotices().batch;
  assert.deepStrictEqual(end, { done: 1, failed: 1, cancelled: 0, skipped: 0, total: 2, bytes: 10 });
  assert.strictEqual(q.takeNotices().batch, null, "once");
});

test("a paused file keeps the batch open", () => {
  const q = new UploadQueue();
  const a = item(q, "uploading", file("a.bin", 10));
  q.takeNotices();
  a.state = "paused";
  assert.strictEqual(q.takeNotices().batch, null);
});

test("cancelling everything ends the batch too", () => {
  const q = new UploadQueue();
  const a = item(q, "uploading", file("a.bin", 10));
  q.takeNotices();
  a.state = "cancelled";
  assert.deepStrictEqual(q.takeNotices().batch, { done: 0, failed: 0, cancelled: 1, skipped: 0, total: 1, bytes: 0 });
});

test("a second batch is announced again", () => {
  const q = new UploadQueue();
  const a = item(q, "uploading", file("a.bin", 10, 1));
  q.takeNotices(); a.state = "done"; assert.ok(q.takeNotices().batch);
  const b = item(q, "uploading", file("b.bin", 10, 2));
  q.takeNotices(); b.state = "done";
  assert.ok(q.takeNotices().batch);
});

test("what did not make it is what the page remembers", () => {
  const q = new UploadQueue();
  item(q, "done", file("done.bin", 1, 1));
  item(q, "cancelled", file("cancelled.bin", 2, 2));
  item(q, "queued", file("queued.bin", 3, 3));
  item(q, "uploading", file("sending.bin", 4, 4));
  item(q, "paused", file("paused.bin", 5, 5));
  item(q, "skipped", file("skipped.bin", 6, 6));
  item(q, "failed", file("failed.bin", 7, 7));

  assert.deepStrictEqual(unfinishedOf(q.items).map((f) => f.name).sort(), ["failed.bin", "paused.bin", "queued.bin", "sending.bin", "skipped.bin"]);
});

test("remembered files and files in hand are listed once each", () => {
  const q = new UploadQueue();
  item(q, "queued", file("a.bin", 1, 1));
  const merged = mergeUnfinished([{ key: fileKey(file("a.bin", 1, 1)), name: "a.bin", size: 1 }, { key: "x", name: "x.bin", size: 9 }], q.items);
  assert.deepStrictEqual(merged.map((f) => f.name), ["a.bin", "x.bin"]);
});

test("picking a remembered file again takes it off the list", () => {
  const remembered = [
    { key: fileKey(file("a.bin", 1, 1)), name: "a.bin", size: 1 },
    { key: fileKey(file("b.bin", 2, 2)), name: "b.bin", size: 2 }
  ];
  assert.deepStrictEqual(withoutPicked(remembered, [file("a.bin", 1, 1), file("other.bin", 5, 5)]).map((f) => f.name), ["b.bin"]);
});
