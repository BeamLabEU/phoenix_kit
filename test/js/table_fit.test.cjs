"use strict";

// Unit tests for the pure helpers behind the TableFit
// hook in priv/static/assets/phoenix_kit.js. Same global stubbing as
// push_to_owner.test.cjs — the bundle is browser code.
//
// Run: mix test.js

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
  addEventListener: noop,
  removeEventListener: noop,
  matchMedia: () => ({ matches: false, addEventListener: noop, addListener: noop }),
  location: { href: "http://localhost/", origin: "http://localhost" },
  localStorage: { getItem: () => null, setItem: noop, removeItem: noop },
  document: global.document,
};
// Node >= 21 defines a global `navigator` as a getter-only accessor
// property, so a plain assignment throws; redefine it instead.
Object.defineProperty(global, "navigator", {
  value: { userAgent: "node" },
  configurable: true,
  writable: true,
});
global.localStorage = global.window.localStorage;
global.MutationObserver = class { observe() {} disconnect() {} };
global.IntersectionObserver = class { observe() {} disconnect() {} };


const { fitEvictionOrder, fitHideCss, fitColumns, fitEscapeId } = require("../../priv/static/assets/phoenix_kit.js");

test("the highest priority number goes first, 1 last", () => {
  const cols = [
    { index: 1, priority: NaN }, // checkbox
    { index: 2, priority: NaN }, // lead
    { index: 3, priority: 1 },
    { index: 4, priority: 3 },
    { index: 5, priority: 2 },
    { index: 6, priority: NaN }, // actions
  ];
  assert.deepEqual(fitEvictionOrder(cols), [4, 5, 3]);
});

test("a column with no priority is never dropped", () => {
  assert.deepEqual(fitEvictionOrder([{ index: 1, priority: NaN }, { index: 2, priority: NaN }]), []);
});

test("equal priorities go from the right", () => {
  const cols = [
    { index: 2, priority: 2 },
    { index: 3, priority: 2 },
    { index: 4, priority: 2 },
  ];
  assert.deepEqual(fitEvictionOrder(cols), [4, 3, 2]);
});

test("the order does not mutate its input", () => {
  const cols = [{ index: 1, priority: 1 }, { index: 2, priority: 5 }];
  fitEvictionOrder(cols);
  assert.deepEqual(cols.map((c) => c.index), [1, 2]);
});

test("nothing hidden is an empty stylesheet", () => {
  assert.equal(fitHideCss("t-fit", []), "");
});

test("hides whole columns by position, on screen only, sparing colspan cells", () => {
  const css = fitHideCss("t-fit", [4, 2]);
  assert.match(css, /^@media screen \{/);
  assert.ok(css.includes("#t-fit > table > * > tr > :nth-child(4):not([colspan])"));
  assert.ok(css.includes("#t-fit > table > * > tr > :nth-child(2):not([colspan])"));
  assert.ok(css.includes("display: none"));
});

test("columns take their body position; a spanning header shifts the rest and never goes", () => {
  const cols = fitColumns([
    { colSpan: 1, priority: undefined },
    { colSpan: 2, priority: "5" },
    { colSpan: 1, priority: "2" },
  ]);
  assert.deepEqual(cols.map((c) => c.index), [1, 2, 4]);
  assert.ok(Number.isNaN(cols[0].priority));
  assert.ok(Number.isNaN(cols[1].priority));
  assert.equal(cols[2].priority, 2);
  assert.deepEqual(fitEvictionOrder(cols), [4]);
});

test("an id that is not a CSS identifier is escaped in the selector", () => {
  assert.equal(fitEscapeId("users-table-fit"), "users-table-fit");
  assert.notEqual(fitEscapeId("01a0-fit"), "01a0-fit");
  assert.ok(!fitHideCss("a.b:c-fit", [2]).includes("#a.b:c-fit"));
  assert.ok(fitHideCss("a.b:c-fit", [2]).includes("#a\\.b\\:c-fit"));
});
