"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

// Run the shipped media selection listeners and hook, with a small event/DOM
// harness so gestures can be exercised without LiveView or a browser driver.
function browser() {
  // The listeners and the hook live in the admin bundle (the media browser is an
  // admin hook); a public page never loads them.
  const source = fs.readFileSync(path.join(__dirname, "../../priv/static/assets/phoenix_kit_admin.js"), "utf8");
  const start = source.indexOf("  function startBoxSelect(");
  const hookAt = source.indexOf("  window.PhoenixKitAdminHooks.MediaDragDrop = {", start);
  assert.ok(start !== -1 && hookAt !== -1, "the box select code is in phoenix_kit_admin.js");
  const hookEnd = source.indexOf("\n  };\n", hookAt);
  assert.ok(hookEnd !== -1, "the end of the MediaDragDrop hook is in phoenix_kit_admin.js");
  const end = hookEnd + "\n  };\n".length;
  const listeners = {};
  const windowListeners = {};
  const calls = [];
  const overlays = new Set();
  const noop = () => {};
  const root = {
    id: "media",
    dataset: {},
    contains: () => true,
    querySelector: () => cards.find(c => c.dataset.selected === "true") || null,
  };
  const area = {
    scrollTop: 0,
    querySelectorAll: () => cards,
    getBoundingClientRect: () => ({ left: 0, top: 0, right: 300, bottom: 300 }),
  };
  const cards = ["a", "b", "c"].map((uuid, i) => ({
    dataset: { draggableFile: uuid },
    style: {},
    offsetParent: area,
    contains: () => false,
    closest: selector => selector === "[data-box-area]" ? area : null,
    getBoundingClientRect: () => ({ left: 20, right: 80, top: 20 + i * 80, bottom: 70 + i * 80 }),
  }));
  const document = {
    documentElement: { style: {} },
    body: { appendChild: el => overlays.add(el) },
    createElement: () => {
      const el = { style: {}, setAttribute: noop, remove: () => overlays.delete(el) };
      return el;
    },
    addEventListener: (name, fn) => (listeners[name] ||= []).push(fn),
  };
  const window = {
    PhoenixKitAdminHooks: {},
    getSelection: () => ({ removeAllRanges: noop }),
    addEventListener: (name, fn) => (windowListeners[name] ||= new Set()).add(fn),
    removeEventListener: (name, fn) => windowListeners[name]?.delete(fn),
  };
  vm.runInNewContext(source.slice(start, end), {
    document, window, setTimeout: noop,
    requestAnimationFrame: () => 1, cancelAnimationFrame: noop,
  });
  const hook = Object.assign(Object.create(window.PhoenixKitAdminHooks.MediaDragDrop), {
    el: root,
    pushEventTo: (_el, event, payload) => calls.push({ event, payload: JSON.parse(JSON.stringify(payload)) }),
  });
  hook.setupBoxSelect();
  function event(card, attrs) {
    return Object.assign({
      target: {
        closest: selector => selector.includes("phx-hook") ? root
          : selector === "[data-box-area]" ? area
            : selector.startsWith("[data-draggable-file]") && card ? card : null,
      },
      button: 0, pointerType: "mouse", pointerId: 1,
      clientX: 10, clientY: 10,
      preventDefault: noop, stopPropagation: noop,
    }, attrs);
  }
  return {
    cards, root, hook, calls, document, overlays,
    click: (card, attrs) => listeners.click.forEach(fn => fn(event(card, attrs))),
    down: attrs => listeners.pointerdown.forEach(fn => fn(event(null, attrs))),
    fire: (name, attrs) => [...(windowListeners[name] || [])].forEach(fn => fn(event(null, attrs))),
    listenerCount: name => windowListeners[name]?.size || 0,
  };
}

test("Shift-click extends a selection through the cards in screen order", () => {
  const b = browser();
  b.cards[0].dataset.selected = "true";
  b.root.dataset.selectionCount = "1";
  b.click(b.cards[0]);
  b.click(b.cards[2], { shiftKey: true });
  assert.deepEqual(b.calls[0].payload, { files: ["a", "b", "c"], folders: [], additive: true });
});

test("Shift-click after clearing the selection starts at the clicked card", () => {
  const b = browser();
  b.cards[0].dataset.selected = "true";
  b.root.dataset.selectionCount = "1";
  b.click(b.cards[0]);
  delete b.cards[0].dataset.selected;
  delete b.root.dataset.selectionCount;
  b.click(b.cards[2], { shiftKey: true });
  assert.deepEqual(b.calls[0].payload.files, ["c"]);
});

test("another pointer cannot draw or finish a box started by the mouse", () => {
  const b = browser();
  b.down({ pointerId: 1 });
  b.fire("pointermove", { pointerId: 2, clientX: 90, clientY: 90 });
  b.fire("pointerup", { pointerId: 2 });
  assert.equal(b.calls.length, 0);
  assert.equal(b.listenerCount("pointerup"), 1, "the original gesture remains active");
  b.fire("pointermove", { pointerId: 1, clientX: 90, clientY: 90 });
  b.fire("pointerup", { pointerId: 1 });
  assert.deepEqual(b.calls[0].payload.files, ["a"]);
  assert.equal(b.listenerCount("pointerup"), 0);
});

test("destroying the browser cancels an active box and restores text selection", () => {
  const b = browser();
  b.document.documentElement.style.userSelect = "text";
  b.down();
  b.fire("pointermove", { clientX: 90, clientY: 90 });
  assert.equal(b.document.documentElement.style.userSelect, "none");
  assert.equal(b.overlays.size, 1);
  b.hook.destroyed();
  assert.equal(b.overlays.size, 0);
  assert.equal(b.document.documentElement.style.userSelect, "text");
  assert.equal(b.listenerCount("pointermove"), 0);
  assert.equal(b.listenerCount("pointerup"), 0);
  assert.equal(b.calls.length, 0, "navigation does not commit the unfinished box");
});
