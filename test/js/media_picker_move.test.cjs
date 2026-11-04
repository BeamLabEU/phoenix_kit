"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

// The drag half of the media browser's `allow_move` picker, run against the
// shipped hook with a small DOM stand-in: a picked card drags the whole pick
// (the server holds it) as the batch event, a card that is not picked drags
// alone, and the drop on the folder the card is in asks for nothing.
function browser({ pickMode, cardAttrs, rootData }) {
  const source = fs.readFileSync(path.join(__dirname, "../../priv/static/assets/phoenix_kit.js"), "utf8");
  const start = source.indexOf("  function startBoxSelect(");
  const end = source.indexOf("\n  // MAINTENANCE COUNTDOWN HOOK", start);
  const calls = [];
  const noop = () => {};

  function element(dataset, extra) {
    const listeners = {};
    const classes = new Set();
    return Object.assign({
      dataset,
      style: {},
      attrs: {},
      listeners,
      classes,
      classList: { add: c => classes.add(c), remove: c => classes.delete(c) },
      setAttribute(name, value) { this.attrs[name] = value; },
      hasAttribute(name) { return Object.hasOwn(this.attrs, name); },
      addEventListener(name, fn) { (listeners[name] ||= []).push(fn); },
      removeEventListener: noop,
    }, extra);
  }

  // The folder being shown: the zone every card sits in.
  const current = element({ dropFolder: "current" });
  const inCurrent = { closest: selector => (selector === "[data-drop-folder]" ? current : null) };
  const cards = ["a", "b", "c"].map((uuid, i) => {
    const attrs = cardAttrs[i];
    const card = element({ draggableFile: uuid, ...(attrs.dataset || {}) }, { parentElement: inCurrent });
    Object.assign(card.attrs, attrs.attrs || {});
    card.querySelector = () => null;
    return card;
  });
  // The grid of the folder shown is a zone with no background (`data-drop-no-bg`);
  // the folder's node in the tree is a target of its own with the same name.
  current.dataset.dropNoBg = "";
  const node = element({ dropFolder: "current" });
  const kitchen = element({ dropFolder: "kitchen" });
  const top = element({ dropFolder: "root" });
  const targets = { current, node, kitchen, top };

  const root = element(Object.assign(pickMode ? { pickMode } : {}, rootData || {}));
  root.id = "media";
  root.querySelectorAll = selector => {
    if (selector.includes("[data-draggable-file]")) return cards;
    if (selector === "[data-pick-order]") return cards.filter(c => c.hasAttribute("data-pick-order"));
    return [];
  };

  const document = {
    documentElement: { style: {} },
    addEventListener: noop,
    querySelectorAll: selector => {
      if (selector === "[data-drop-folder]") return Object.values(targets);
      if (selector === '[data-selected="true"]') return cards.filter(c => c.dataset.selected === "true");
      return [];
    },
  };
  const window = {
    PhoenixKitHooks: {},
    addEventListener: noop,
    removeEventListener: noop,
  };
  vm.runInNewContext(source.slice(start, end), {
    document, window, setTimeout: noop, requestAnimationFrame: () => 1, cancelAnimationFrame: noop,
  });
  const hook = Object.assign(Object.create(window.PhoenixKitHooks.MediaDragDrop), {
    el: root,
    pushEventTo: (_el, event, payload) => calls.push({ event, payload: JSON.parse(JSON.stringify(payload)) }),
  });
  hook.setupDragDrop();

  function transfer() {
    const store = {};
    return {
      store,
      get types() { return Object.keys(store); },
      setData: (type, value) => { store[type] = value; },
      getData: type => store[type] || "",
    };
  }
  function fire(el, name, dataTransfer) {
    (el.listeners[name] || []).forEach(fn => fn({
      dataTransfer, preventDefault: noop, stopPropagation: noop,
    }));
  }
  // Pick the card up and let it go over `target`.
  function drag(card, target) {
    const dt = transfer();
    fire(card, "dragstart", dt);
    fire(targets[target], "dragover", dt);
    fire(targets[target], "drop", dt);
    fire(card, "dragend", dt);
    return dt;
  }
  return { hook, cards, calls, drag, root, targets };
}

const PICKED = { attrs: { "data-pick-order": "1" } };
const NOT_PICKED = {};

test("a picked card in a picker drags the whole pick: one batch event", () => {
  const b = browser({ pickMode: "multiple", cardAttrs: [PICKED, NOT_PICKED, PICKED] });
  const dt = b.drag(b.cards[0], "kitchen");
  assert.ok(dt.types.includes("application/x-pk-batch"));
  assert.deepEqual(b.calls, [{ event: "move_picked_to_folder", payload: { "folder-uuid": "kitchen" } }]);
});

test("a card that is not picked drags alone", () => {
  const b = browser({ pickMode: "multiple", cardAttrs: [PICKED, NOT_PICKED, PICKED] });
  const dt = b.drag(b.cards[1], "kitchen");
  assert.ok(!dt.types.includes("application/x-pk-batch"));
  assert.deepEqual(b.calls, [{ event: "move_file_to_folder", payload: { file_uuid: "b", folder_uuid: "kitchen" } }]);
});

test("the top level is named by an empty folder", () => {
  const b = browser({ pickMode: "single", cardAttrs: [PICKED, NOT_PICKED, NOT_PICKED] });
  b.drag(b.cards[0], "top");
  assert.deepEqual(b.calls, [{ event: "move_picked_to_folder", payload: { "folder-uuid": "" } }]);
});

test("a drop on the folder the picked cards are in asks for nothing", () => {
  const b = browser({ pickMode: "multiple", cardAttrs: [PICKED, NOT_PICKED, PICKED] });
  b.drag(b.cards[0], "current");
  b.drag(b.cards[1], "current");
  b.drag(b.cards[0], "node");
  b.drag(b.cards[1], "node");
  assert.deepEqual(b.calls, []);
});

test("the picked cards show as carried while the pick is dragged", () => {
  const b = browser({ pickMode: "multiple", cardAttrs: [PICKED, NOT_PICKED, PICKED] });
  const dt = { store: {}, get types() { return Object.keys(this.store); }, setData(t, v) { this.store[t] = v; }, getData() { return ""; } };
  b.cards[0].listeners.dragstart.forEach(fn => fn({ dataTransfer: dt }));
  assert.ok(b.cards[0].classes.has("opacity-50") && b.cards[2].classes.has("opacity-50"));
  assert.ok(!b.cards[1].classes.has("opacity-50"));
  b.cards[0].listeners.dragend.forEach(fn => fn({ dataTransfer: dt }));
  assert.equal(b.cards[0].classes.size + b.cards[2].classes.size, 0);
});

test("a picker's card has no long press, which would eat the click that picks", () => {
  const b = browser({ pickMode: "multiple", cardAttrs: [PICKED, NOT_PICKED, NOT_PICKED] });
  b.hook.setupLongPress();
  assert.equal(b.cards[0].listeners.pointerdown, undefined);
  assert.equal(b.cards[0].listeners.click, undefined);
});

test("outside a picker the selection still drags as a batch, a card outside it alone", () => {
  const selected = { dataset: { selected: "true" } };
  const b = browser({ cardAttrs: [selected, {}, selected] });
  b.drag(b.cards[0], "kitchen");
  b.drag(b.cards[1], "kitchen");
  assert.deepEqual(b.calls.map(c => c.event), ["move_selected_to_folder", "move_file_to_folder"]);
});

test("outside a picker a picked-looking card is no batch", () => {
  const b = browser({ cardAttrs: [PICKED, {}, {}] });
  b.drag(b.cards[0], "kitchen");
  assert.deepEqual(b.calls.map(c => c.event), ["move_file_to_folder"]);
});

test("outside a picker a long press still selects", () => {
  const b = browser({ cardAttrs: [{}, {}, {}] });
  b.hook.setupLongPress();
  assert.ok(b.cards[0].listeners.pointerdown.length > 0);
});

test("a pick with files off screen is gathered by a drop on the node of the folder shown", () => {
  const b = browser({ pickMode: "multiple", cardAttrs: [PICKED, NOT_PICKED, PICKED], rootData: { pickCount: "5" } });
  b.drag(b.cards[0], "node");
  assert.deepEqual(b.calls, [{ event: "move_picked_to_folder", payload: { "folder-uuid": "current" } }]);
});

test("…but not by a card let go over the grid", () => {
  const b = browser({ pickMode: "multiple", cardAttrs: [PICKED, NOT_PICKED, PICKED], rootData: { pickCount: "5" } });
  b.drag(b.cards[0], "current");
  assert.deepEqual(b.calls, []);
});

test("a pick that is all on screen still ignores the folder shown", () => {
  const b = browser({ pickMode: "multiple", cardAttrs: [PICKED, NOT_PICKED, PICKED], rootData: { pickCount: "2" } });
  b.drag(b.cards[0], "node");
  assert.deepEqual(b.calls, []);
});

test("in a picker the grid takes no move: a card must be dropped on a folder", () => {
  const b = browser({ pickMode: "multiple", cardAttrs: [PICKED, NOT_PICKED, PICKED], rootData: { pickCount: "2" } });
  const fromElsewhere = { dataset: { originFolder: "kitchen" } };
  const c = browser({ pickMode: "multiple", cardAttrs: [fromElsewhere, {}, {}] });
  c.drag(c.cards[0], "current");
  b.drag(b.cards[1], "current");
  assert.deepEqual(c.calls.concat(b.calls), []);
});

test("listing the subfolders, a card's folder is the one it names, not the grid's", () => {
  const fromKitchen = { dataset: { originFolder: "kitchen" } };
  const fromCurrent = { dataset: { originFolder: "current" } };
  const b = browser({ pickMode: "multiple", cardAttrs: [fromKitchen, fromCurrent, {}] });
  b.drag(b.cards[0], "node");
  b.drag(b.cards[1], "node");
  b.drag(b.cards[0], "kitchen");
  assert.deepEqual(b.calls, [
    { event: "move_file_to_folder", payload: { file_uuid: "a", folder_uuid: "current" } }
  ]);
});

test("a picked batch from several folders may go to any node", () => {
  const picked = (folder) => ({ attrs: { "data-pick-order": "1" }, dataset: { originFolder: folder } });
  const b = browser({ pickMode: "multiple", cardAttrs: [picked("kitchen"), picked("current"), {}], rootData: { pickCount: "2" } });
  b.drag(b.cards[0], "node");
  assert.deepEqual(b.calls.map(c => c.payload["folder-uuid"]), ["current"]);
});

test("text or a link dropped on a folder is not taken for a card", () => {
  const b = browser({ pickMode: "multiple", cardAttrs: [PICKED, NOT_PICKED, NOT_PICKED] });
  const dt = { types: ["text/plain"], getData: () => "https://example.com/x", dropEffect: "" };
  let prevented = false;
  const ev = { dataTransfer: dt, preventDefault: () => { prevented = true; }, stopPropagation: () => {} };
  b.targets.kitchen.listeners.dragover.forEach(fn => fn(ev));
  assert.equal(prevented, false, "not accepted as a drop");
  b.targets.kitchen.listeners.drop.forEach(fn => fn(ev));
  assert.deepEqual(b.calls, []);
});

test("outside a picker the grid still takes a card that came from another folder", () => {
  const fromKitchen = { dataset: { originFolder: "kitchen" } };
  const b = browser({ cardAttrs: [fromKitchen, {}, {}] });
  b.drag(b.cards[0], "current");
  assert.deepEqual(b.calls, [{ event: "move_file_to_folder", payload: { file_uuid: "a", folder_uuid: "current" } }]);
});
