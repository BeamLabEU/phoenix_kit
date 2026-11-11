"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

// Two MediaDragDrop hooks on one page — two notes panels, a panel beside a media
// browser. Their drop targets are looked up across the whole document, so both
// hooks wire the same elements. A drag must be answered by the hook it started
// in, and only by that one.
function page() {
  const source = fs.readFileSync(path.join(__dirname, "../../priv/static/assets/phoenix_kit.js"), "utf8");
  const start = source.indexOf("  function startBoxSelect(");
  const end = source.indexOf("\n  // MAINTENANCE COUNTDOWN HOOK", start);
  const calls = [];
  const noop = () => {};

  function element(dataset, extra) {
    const listeners = {};
    return Object.assign({
      dataset,
      style: {},
      attrs: {},
      listeners,
      classList: { add: noop, remove: noop },
      setAttribute(name, value) { this.attrs[name] = value; },
      hasAttribute(name) { return Object.hasOwn(this.attrs, name); },
      removeAttribute(name) { delete this.attrs[name]; },
      addEventListener(name, fn) { (listeners[name] ||= []).push(fn); },
      removeEventListener(name, fn) {
        listeners[name] = (listeners[name] || []).filter(f => f !== fn);
      },
    }, extra);
  }

  const nowhere = { closest: () => null };
  const folders = { a: element({ dropFolder: "folder-a" }), b: element({ dropFolder: "folder-b" }) };
  const trash = element({ dropTrash: "true" });

  const document = {
    documentElement: { style: {} },
    addEventListener: noop,
    querySelectorAll: selector => {
      const found = [];
      if (selector.includes("[data-drop-folder]")) found.push(...Object.values(folders));
      if (selector.includes("[data-drop-trash]")) found.push(trash);
      return found;
    },
  };
  const window = { PhoenixKitHooks: {}, addEventListener: noop, removeEventListener: noop };
  vm.runInNewContext(source.slice(start, end), {
    document, window, setTimeout: noop, requestAnimationFrame: () => 1, cancelAnimationFrame: noop,
  });

  function hook(name, dataset) {
    const card = element(dataset || { draggableFile: `note-${name}` }, { parentElement: nowhere });
    card.querySelector = () => null;
    const root = element({});
    root.id = name;
    // Answers from the card's dataset as it is now, the way a patched DOM would.
    root.querySelectorAll = selector => {
      if (selector.includes("[data-draggable-file]")) return card.dataset.draggableFile ? [card] : [];
      if (selector.includes("[data-draggable-folder]")) return card.dataset.draggableFolder ? [card] : [];
      return [];
    };
    const h = Object.assign(Object.create(window.PhoenixKitHooks.MediaDragDrop), {
      el: root,
      pushEventTo: (el, event, payload) => calls.push({ hook: el.id, event, payload: JSON.parse(JSON.stringify(payload)) }),
    });
    h.setupDragDrop();
    return { hook: h, card };
  }

  function transfer() {
    const store = {};
    return {
      get types() { return Object.keys(store); },
      setData: (type, value) => { store[type] = value; },
      getData: type => store[type] || "",
    };
  }
  function fire(el, name, dataTransfer) {
    (el.listeners[name] || []).forEach(fn => fn({ dataTransfer, preventDefault: noop, stopPropagation: noop }));
  }
  function drag(card, target) {
    const dt = transfer();
    fire(card, "dragstart", dt);
    fire(target, "dragover", dt);
    fire(target, "drop", dt);
    fire(card, "dragend", dt);
  }
  return { hook, folders, trash, calls, drag };
}

test("a drag started in the first of two hooks still moves", () => {
  const p = page();
  const first = p.hook("first");
  p.hook("second");
  p.drag(first.card, p.folders.b);
  assert.deepEqual(p.calls, [
    { hook: "first", event: "move_file_to_folder", payload: { file_uuid: "note-first", folder_uuid: "folder-b" } },
  ]);
});

test("each drag is answered by its own hook, once", () => {
  const p = page();
  const first = p.hook("first");
  const second = p.hook("second");
  p.drag(second.card, p.folders.a);
  p.drag(first.card, p.folders.a);
  assert.deepEqual(p.calls.map(c => [c.hook, c.payload.file_uuid]), [
    ["second", "note-second"],
    ["first", "note-first"],
  ]);
});

test("a drop on the trash trashes through the hook the drag started in, only", () => {
  const p = page();
  const first = p.hook("first");
  p.hook("second");
  p.drag(first.card, p.trash);
  assert.deepEqual(p.calls, [{ hook: "first", event: "trash_file", payload: { file_uuid: "note-first" } }]);
});

test("re-running setup (a LiveView update) does not stack handlers", () => {
  const p = page();
  const first = p.hook("first");
  first.hook.setupDragDrop();
  first.hook.setupDragDrop();
  p.drag(first.card, p.folders.b);
  assert.equal(p.calls.length, 1);
});

test("a destroyed hook leaves nothing behind on the shared targets", () => {
  const p = page();
  const first = p.hook("first");
  const before = (p.folders.a.listeners.drop || []).length;
  p.hook("second");
  first.hook.destroyed();
  assert.equal((p.folders.a.listeners.drop || []).length, before);
  assert.equal((p.trash.listeners.drop || []).length, 1);
});

// LiveView patches rows in place: the row that showed a folder shows a file
// after a navigation, unless the rows carry ids.
test("a row that held a folder and now holds a file drags as the file", () => {
  const p = page();
  const { hook, card } = p.hook("first", { draggableFolder: "folder-x" });
  delete card.dataset.draggableFolder;
  card.dataset.draggableFile = "note-y";
  hook.setupDragDrop(); // LiveView's `updated`
  p.drag(card, p.folders.b);
  assert.deepEqual(p.calls, [
    { hook: "first", event: "move_file_to_folder", payload: { file_uuid: "note-y", folder_uuid: "folder-b" } },
  ]);
});

test("a row that is no longer draggable keeps no drag listener", () => {
  const p = page();
  const { hook, card } = p.hook("first");
  assert.equal(card.attrs.draggable, "true");
  delete card.dataset.draggableFile;
  hook.setupDragDrop();
  assert.deepEqual(card.listeners.dragstart || [], []);
  assert.ok(!card.hasAttribute("draggable"));
});
