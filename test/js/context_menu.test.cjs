"use strict";

// Unit tests for the pure positioning logic behind the ContextMenu hook in
// priv/static/assets/phoenix_kit_admin.js. The bundle is browser code (IIFEs that
// assign onto `window`), so stub the globals it touches at load time; the
// DOM-using hook methods themselves are not invoked here.
//
// Run: mix test.js  (node --test needs the explicit file on Node 25)

const test = require("node:test");
const assert = require("node:assert/strict");

const noop = () => {};

function stubElement() {
  return {
    style: {},
    dataset: {},
    classList: { add: noop, remove: noop, toggle: noop, contains: () => false },
    setAttribute: noop,
    getAttribute: () => null,
    removeAttribute: noop,
    appendChild: noop,
    remove: noop,
    addEventListener: noop,
    removeEventListener: noop,
    querySelector: () => null,
    querySelectorAll: () => [],
  };
}

const storage = {
  getItem: () => null,
  setItem: noop,
  removeItem: noop,
  key: () => null,
  length: 0,
};

global.document = {
  documentElement: stubElement(),
  head: stubElement(),
  body: stubElement(),
  createElement: stubElement,
  createTextNode: () => ({}),
  getElementById: () => null,
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener: noop,
  removeEventListener: noop,
  readyState: "complete",
};

global.window = {
  PhoenixKitAdminHooks: {},
  addEventListener: noop,
  removeEventListener: noop,
  matchMedia: () => ({ matches: false, addEventListener: noop, removeEventListener: noop }),
  localStorage: storage,
  sessionStorage: storage,
  location: { href: "http://localhost/", reload: noop },
  navigator: { userAgent: "node" },
  document: global.document,
  setTimeout,
  clearTimeout,
};

global.localStorage = storage;
global.sessionStorage = storage;

const { contextMenuPosition } = (require("../../priv/static/assets/phoenix_kit.js"), require("../../priv/static/assets/phoenix_kit_admin.js"));

// A roomy viewport and a menu that fits in it several times over, so each test
// below isolates one edge.
const VW = 1000;
const VH = 800;
const W = 200;
const H = 300;

test("opens down-right of the pointer when there is room", () => {
  const pos = contextMenuPosition(100, 100, W, H, VW, VH);
  assert.deepEqual(pos, { left: 100, top: 100 });
});

test("flips to the left of the pointer rather than overflowing the right edge", () => {
  // 900 + 200 = 1100 > 1000, so the menu hangs off the right — it opens to the
  // LEFT of the pointer instead of being nudged, which is what a native menu
  // does and what keeps the pointer on a corner of the menu.
  const pos = contextMenuPosition(900, 100, W, H, VW, VH);
  assert.equal(pos.left, 700);
  assert.equal(pos.top, 100);
});

test("flips above the pointer rather than overflowing the bottom edge", () => {
  const pos = contextMenuPosition(100, 700, W, H, VW, VH);
  assert.equal(pos.left, 100);
  assert.equal(pos.top, 400);
});

test("flips on both axes for a click in the bottom-right corner", () => {
  const pos = contextMenuPosition(950, 780, W, H, VW, VH);
  assert.deepEqual(pos, { left: 750, top: 480 });
});

test("clamps a pointer inside the 8px margin out to it", () => {
  // No flip here — 4 + 200 fits — so what is clamped is the initial
  // position: a pointer 4px from the edge would put the menu under it.
  const pos = contextMenuPosition(4, 4, W, H, VW, VH);
  assert.equal(pos.left, 8);
  assert.equal(pos.top, 8);
});

test("a menu wider than the viewport flips, then clamps to the pad", () => {
  // 100 + 900 overflows, so it flips to 100 - 900 = -800 — off the other
  // edge — and the clamp pulls it back to the 8px pad. This is the
  // horizontal flip-then-clamp branch; the vertical twin is covered below.
  const pos = contextMenuPosition(100, 100, 900, H, VW, VH);
  assert.equal(pos.left, 8);
  assert.equal(pos.top, 100);
});

test("a menu taller than the viewport pins to the top rather than escaping it", () => {
  // Both branches overflow, so the clamp decides: top of the viewport plus the
  // pad. The menu scrolls or overflows visibly — it is never placed at a
  // negative offset where its first items are unreachable.
  const pos = contextMenuPosition(500, 400, W, 2000, VW, VH);
  assert.equal(pos.top, 8);
});

test("positions are independent of viewport size only through the edges", () => {
  // Same pointer, narrower viewport: the menu that fit before now flips.
  assert.equal(contextMenuPosition(700, 100, W, H, VW, VH).left, 700);
  assert.equal(contextMenuPosition(700, 100, W, H, 850, VH).left, 500);
});
