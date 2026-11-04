// What the upload manager does with files the UploadResume hook hands back
// after a lost transfer: a file it still holds is not queued a second time,
// and the page's upload ref — new each time the page mounts again — is read
// off its element, not remembered from the first mount.
//
//   node --test test/js/upload_manager_resume_feed.test.cjs

const fs = require("fs");
const path = require("path");
const assert = require("node:assert");
const { test } = require("node:test");

const SOURCE = path.join(
  __dirname, "..", "..", "priv", "static", "assets", "phoenix_kit_upload_manager.js"
);

function load() {
  const window = { PhoenixKitHooks: {} };
  new Function("window", "document", fs.readFileSync(SOURCE, "utf8"))(window, {});
  return { Hook: window.PhoenixKitHooks.UploadManager, UploadQueue: window.PhoenixKitUploadManager.UploadQueue };
}

const { Hook, UploadQueue } = load();
const file = (name, size = 10, lastModified = 1) => ({ name, size, lastModified });

function manager({ ref = "ref-2" } = {}) {
  const ctx = Object.create(Hook);
  ctx.el = { dataset: { uploadRef: ref } };
  ctx.uploadRef = "ref-1"; // what mounted() read, before the page mounted again
  ctx.queue = new UploadQueue({ cap: 2, resumable: true });
  ctx.leftovers = [];
  ctx.synced = 0;
  ctx.sync = () => { ctx.synced++; };
  return ctx;
}

function pick(ctx, files, flags = {}) {
  const input = {
    tagName: "INPUT", type: "file", files, value: "x",
    getAttribute: (n) => (n === "data-phx-upload-ref" ? "ref-2" : null)
  };
  const ev = Object.assign({ target: input, stopped: false, stopImmediatePropagation() { this.stopped = true; } }, flags);
  ctx._onPick(ev);
  return { input, ev };
}

test("the upload ref is read off the element, so a re-mounted page is still recognised", () => {
  const ctx = manager();
  assert.strictEqual(ctx._ref(), "ref-2");
  const { ev } = pick(ctx, [file("a.png")]);
  assert.ok(ev.stopped, "the input of the new mount is still the manager's");
  assert.strictEqual(ctx.queue.items.length, 1);
});

test("a resumed file the queue still holds is not queued twice; the others are", () => {
  const ctx = manager();
  pick(ctx, [file("held.png"), file("paused.png")]);
  ctx.queue.pause(ctx.queue.items[1].id);

  const { ev, input } = pick(ctx, [file("held.png"), file("paused.png"), file("lost.png")], { __pkUploadResume: true });
  assert.ok(ev.stopped);
  assert.strictEqual(input.value, "", "the input is cleared as for any pick");
  assert.deepStrictEqual(ctx.queue.items.map((i) => i.name), ["held.png", "paused.png", "lost.png"]);
});

test("a resumed file the queue has finished with is queued again", () => {
  const ctx = manager();
  pick(ctx, [file("done.png")]);
  ctx.queue.items[0].state = "done";

  pick(ctx, [file("done.png")], { __pkUploadResume: true });
  assert.strictEqual(ctx.queue.items.length, 2);
  assert.strictEqual(ctx.queue.items[1].state, "queued");
});

test("a file the person picks again is queued as it always was, resume flag or not", () => {
  const ctx = manager();
  pick(ctx, [file("a.png")]);
  pick(ctx, [file("a.png")]);
  assert.strictEqual(ctx.queue.items.length, 2);
});

test("a resume that brings nothing new is swallowed whole", () => {
  const ctx = manager();
  pick(ctx, [file("a.png")]);
  const before = ctx.synced;
  const { ev } = pick(ctx, [file("a.png")], { __pkUploadResume: true });
  assert.ok(ev.stopped, "it must not reach LiveView's own handler either");
  assert.strictEqual(ctx.queue.items.length, 1);
  assert.strictEqual(ctx.synced, before);
});

test("holds/1: waiting, sending, paused and skipped files are held; finished and cancelled are not", () => {
  const q = new UploadQueue({ cap: 2 });
  q.add([file("a"), file("b"), file("c"), file("d")]);
  const [a, b, c, d] = q.items;
  a.state = "uploading"; b.state = "paused"; c.state = "skipped"; d.state = "done";
  assert.ok(q.holds(a.key) && q.holds(b.key) && q.holds(c.key));
  assert.ok(!q.holds(d.key));
  d.state = "cancelled";
  assert.ok(!q.holds(d.key));
  assert.ok(!q.holds("nothing|1|1"));
});

// A file the person cancels is not a leftover: the page tells UploadResume
// (a bubbling `pk-upload:cancelled`) to let go of its stashed copy.
function click(ctx, act, id) {
  const li = id == null ? null : { dataset: { item: String(id) } };
  const btn = { dataset: { act }, closest: (sel) => (sel === "[data-item]" ? li : null) };
  ctx.el.contains = () => true;
  ctx.pushEvent = () => {};
  ctx.render = () => {};
  const ev = { target: { closest: () => btn }, preventDefault() {} };
  ctx._onClick(ev);
}

test("cancelling one file announces its key", () => {
  const ctx = manager();
  const emitted = [];
  ctx._emit = (name, detail) => emitted.push({ name, detail });
  pick(ctx, [file("a.png"), file("b.png")]);

  click(ctx, "cancel", ctx.queue.items[0].id);
  assert.deepStrictEqual(emitted, [{ name: "cancelled", detail: { keys: [ctx.queue.items[0].key] } }]);
});

test("cancel all announces every file it stops, and none it leaves", () => {
  const ctx = manager();
  const emitted = [];
  ctx._emit = (name, detail) => emitted.push({ name, detail });
  pick(ctx, [file("a.png"), file("b.png"), file("c.png")]);
  ctx.queue.items[2].state = "done";

  click(ctx, "cancel-all");
  assert.strictEqual(emitted.length, 1);
  assert.deepStrictEqual(emitted[0].detail.keys.sort(), [ctx.queue.items[0].key, ctx.queue.items[1].key].sort());
});
