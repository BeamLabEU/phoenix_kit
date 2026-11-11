"use strict";

// Unit tests for navTabsHidden, the pure fitting logic behind the
// NavTabsOverflow hook in priv/static/assets/phoenix_kit.js. The DOM side of
// the hook (measuring, toggling classes, the menu) needs a browser.
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
  PhoenixKitHooks: {},
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

const { navTabsHidden } = require("../../priv/static/assets/phoenix_kit.js");

test("the hook is registered", () => {
  assert.equal(typeof global.window.PhoenixKitHooks.NavTabsOverflow.mounted, "function");
  assert.equal(typeof global.window.PhoenixKitHooks.NavTabsOverflow.updated, "function");
});

test("hides nothing that fits", () => {
  assert.deepEqual(navTabsHidden([100, 100, 100], 0, 300, 0), [false, false, false]);
});

test("hides the tabs that do not fit, keeping order, from the end", () => {
  // 100 each, 250 available: two fit, the third (and later) go.
  assert.deepEqual(navTabsHidden([100, 100, 100, 100], 0, 250, 0), [false, false, true, true]);
});

test("counts the gap between tabs", () => {
  // 2 tabs + 1 gap of 20 = 220 <= 220, a third would need 340.
  assert.deepEqual(navTabsHidden([100, 100, 100], 20, 220, 0), [false, false, true]);
  assert.deepEqual(navTabsHidden([100, 100, 100], 20, 219, 0), [false, true, true]);
});

test("a late active tab pushes earlier non-active tabs out instead of itself", () => {
  // The active tab is last: room is reserved for it, so only one earlier tab stays.
  assert.deepEqual(navTabsHidden([100, 100, 100, 100], 0, 250, 3), [false, true, true, false]);
});

test("a middle active tab stays; later tabs go once one did not fit", () => {
  assert.deepEqual(navTabsHidden([100, 100, 100, 100], 0, 250, 1), [false, false, true, true]);
});

test("a tab after the first hidden one stays hidden even if it is narrow", () => {
  assert.deepEqual(navTabsHidden([100, 200, 40], 0, 200, 0), [false, true, true]);
});

test("when the active tab alone fills the strip, every other tab hides", () => {
  assert.deepEqual(navTabsHidden([100, 400, 100], 0, 300, 1), [true, false, true]);
});

test("no active tab behaves like plain truncation from the end", () => {
  assert.deepEqual(navTabsHidden([100, 100, 100], 0, 150, -1), [false, true, true]);
});

test("sub-pixel measurement noise does not hide a tab that fits", () => {
  assert.deepEqual(navTabsHidden([100.3, 100.3], 0, 200.4, 0), [false, false]);
});
