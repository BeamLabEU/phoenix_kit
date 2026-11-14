// The upload manager's rows while the panel is shrunk. A batch that ends
// cleanly shrinks the panel to one line; the rows are then not redrawn in
// full, but each still has to carry its file's current state. A host form
// (the agent Dock's composer) refuses to send while a row says "queued" or
// "uploading", so a row frozen at the moment the panel shrank held the send
// back until the user opened the panel. The hook's render is driven here
// against a stand-in page.
//
//   node --test test/js/upload_manager_collapsed_rows.test.cjs

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

// Just enough of an element for the hook's drawing code.
class Node {
  constructor() {
    this.dataset = {};
    this.hidden = false;
    this.textContent = "";
    this.title = "";
    this.value = 0;
    this.max = 0;
    this.children = [];
    this.parent = null;
    this.parts = {};
  }
  querySelector(sel) {
    return this.parts[sel] || (this.parts[sel] = new Node());
  }
  setAttribute() {}
  get firstChild() { return this.children[0] || null; }
  get nextSibling() {
    if (!this.parent) return null;
    const at = this.parent.children.indexOf(this);
    return this.parent.children[at + 1] || null;
  }
  insertBefore(node, ref) {
    if (node.parent) node.parent.children.splice(node.parent.children.indexOf(node), 1);
    node.parent = this;
    const at = ref ? this.children.indexOf(ref) : -1;
    if (at < 0) this.children.push(node); else this.children.splice(at, 0, node);
    return node;
  }
  appendChild(node) { return this.insertBefore(node, null); }
  remove() {
    if (this.parent) this.parent.children.splice(this.parent.children.indexOf(this), 1);
    this.parent = null;
  }
  cloneNode() { return new Node(); }
}

function hook() {
  const h = Object.create(Hook);
  h.el = new Node();
  h.list = new Node();
  h.rowTemplate = { content: { firstElementChild: new Node() } };
  h.rowEls = {};
  h.labels = {};
  h.leftovers = [];
  h.collapsed = false;
  h.wasLive = false;
  h.resumable = false;
  h.queue = new UploadQueue({ cap: 1 });
  return h;
}

const states = (h) => h.list.children.map((li) => li.dataset.state);
const busy = (h) => h.list.children.some((li) => li.dataset.state === "queued" || li.dataset.state === "uploading");

test("a batch that ends cleanly shrinks the panel and its rows say done", () => {
  const h = hook();
  h.queue.add([{ name: "sheet.png", size: 1000, lastModified: 1 }]);
  const [it] = h.queue.next(1000);
  h.render(1000);
  assert.strictEqual(h.collapsed, false);
  assert.deepStrictEqual(states(h), ["uploading"]);

  h.queue.observe([{ ref: "r1", key: it.key, size: 1000, progress: 100, done: true, error: "" }], 1250);
  h.render(1250);
  assert.strictEqual(h.collapsed, true, "a clean finish shrinks the panel");
  assert.strictEqual(h.list.hidden, true);
  assert.deepStrictEqual(states(h), ["done"], "the shrunk panel's row is not left at uploading");
  assert.strictEqual(busy(h), false);
});

test("minimised mid-batch, rows still follow their files", () => {
  const h = hook();
  h.queue.add([
    { name: "a.png", size: 1000, lastModified: 1 },
    { name: "b.png", size: 1000, lastModified: 2 }
  ]);
  const [a] = h.queue.next(1000);
  h.render(1000);
  h.collapsed = true; // the user shrinks it while files are moving
  h.render(1000);
  assert.deepStrictEqual(states(h), ["uploading", "queued"]);

  h.queue.observe([{ ref: "r1", key: a.key, size: 1000, progress: 100, done: true, error: "" }], 1250);
  const [b] = h.queue.next(1250);
  h.render(1250);
  assert.strictEqual(h.collapsed, true, "minimised mid-batch stays minimised");
  assert.deepStrictEqual(states(h).sort(), ["done", "uploading"]);
  assert.strictEqual(busy(h), true, "one file is still moving");

  h.queue.observe([{ ref: "r2", key: b.key, size: 1000, progress: 100, done: true, error: "" }], 1500);
  h.render(1500);
  assert.deepStrictEqual(states(h), ["done", "done"]);
  assert.strictEqual(busy(h), false);
});

test("a file added while the panel is shrunk gets a row, a cleared one loses it", () => {
  const h = hook();
  h.collapsed = true;
  h.wasLive = true; // a batch is on and the panel was shrunk by hand
  h.queue.add([
    { name: "late.png", size: 1000, lastModified: 3 },
    { name: "kept.png", size: 1000, lastModified: 4 }
  ]);
  h.render(1000);
  assert.deepStrictEqual(states(h), ["queued", "queued"]);
  h.queue.items = h.queue.items.slice(1); // "Clear finished" / cancel drops one
  h.render(1000);
  assert.deepStrictEqual(states(h), ["queued"]);
  assert.deepStrictEqual(Object.keys(h.rowEls), [String(h.queue.items[0].id)]);
});

test("opening the panel again draws the rows in full", () => {
  const h = hook();
  h.queue.add([{ name: "sheet.png", size: 1000, lastModified: 1 }]);
  const [it] = h.queue.next(1000);
  h.render(1000);
  h.queue.observe([{ ref: "r1", key: it.key, size: 1000, progress: 100, done: true, error: "" }], 1250);
  h.render(1250);
  h.collapsed = false;
  h.render(1250);
  const li = h.list.children[0];
  assert.strictEqual(li.dataset.state, "done");
  assert.strictEqual(li.querySelector('[data-role="status"]').textContent, "st_done · 1.0 KB");
});
