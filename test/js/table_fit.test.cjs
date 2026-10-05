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


const {
  fitEvictionOrder,
  fitHideCss,
  fitColumns,
  fitEscapeId,
  fitSignature,
} = require("../../priv/static/assets/phoenix_kit.js");

const col = (index, priority, head = index) => ({ index, head, priority });
const order = (cols) => fitEvictionOrder(cols).map((c) => c.index);

test("the highest priority number goes first, 1 last", () => {
  const cols = [col(1, NaN), col(2, NaN), col(3, 1), col(4, 3), col(5, 2), col(6, NaN)];
  assert.deepEqual(order(cols), [4, 5, 3]);
});

test("a column with no priority is never dropped", () => {
  assert.deepEqual(order([col(1, NaN), col(2, NaN)]), []);
});

test("equal priorities go from the right", () => {
  assert.deepEqual(order([col(2, 2), col(3, 2), col(4, 2)]), [4, 3, 2]);
});

test("the order does not mutate its input", () => {
  const cols = [col(1, 1), col(2, 5)];
  fitEvictionOrder(cols);
  assert.deepEqual(cols.map((c) => c.index), [1, 2]);
});

test("nothing hidden is an empty stylesheet", () => {
  assert.equal(fitHideCss("t-fit", []), "");
});

test("hides whole columns by position, on screen only, sparing colspan cells", () => {
  const css = fitHideCss("t-fit", [col(4, 2), col(2, 3)]);
  assert.match(css, /^@media screen \{/);
  assert.ok(css.includes("#t-fit > table > :not(thead) > tr > :nth-child(4):not([colspan])"));
  assert.ok(css.includes("#t-fit > table > :not(thead) > tr > :nth-child(2):not([colspan])"));
  assert.ok(css.includes("display: none"));
});

test("says how many columns are dropped, on the last header cell", () => {
  const css = fitHideCss("t-fit", [col(4, 2), col(2, 3)]);
  assert.ok(css.includes('#t-fit > table > thead > tr > :last-child::before { content: "+2"'));
});

test("after a spanning header, the header cell and its body cells sit at different positions", () => {
  // [A][B colspan=2][C priority 2][D]: C is the 3rd header cell and the 4th
  // body cell. Hiding nth-child(4) in the header would take D instead.
  const cols = fitColumns([
    { colSpan: 1, priority: undefined },
    { colSpan: 2, priority: "5" },
    { colSpan: 1, priority: "2" },
    { colSpan: 1, priority: undefined },
  ]);
  assert.deepEqual(cols.map((c) => [c.index, c.head]), [[1, 1], [2, 2], [4, 3], [5, 4]]);
  assert.ok(Number.isNaN(cols[1].priority)); // the spanning header never goes

  const dropped = fitEvictionOrder(cols);
  assert.deepEqual(dropped.map((c) => c.index), [4]);

  const css = fitHideCss("t-fit", dropped);
  assert.ok(css.includes("> thead > tr > :nth-child(3)"));
  assert.ok(!css.includes("> thead > tr > :nth-child(4)"));
  assert.ok(css.includes("> :not(thead) > tr > :nth-child(4):not([colspan])"));
});

test("an id that is not a CSS identifier is escaped in the selector", () => {
  assert.equal(fitEscapeId("users-table-fit"), "users-table-fit");
  assert.notEqual(fitEscapeId("01a0-fit"), "01a0-fit");
  assert.ok(!fitHideCss("a.b:c-fit", [col(2, 1)]).includes("#a.b:c-fit"));
  assert.ok(fitHideCss("a.b:c-fit", [col(2, 1)]).includes("#a\\.b\\:c-fit"));
});

test("the signature changes when a column is added, removed or re-prioritised", () => {
  const base = [{ colSpan: 1 }, { colSpan: 1, priority: "2" }, { colSpan: 1, priority: "1" }];
  const sig = fitSignature(base);
  assert.equal(sig, fitSignature(base.map((h) => ({ ...h }))));
  assert.notEqual(sig, fitSignature(base.slice(0, 2)));
  assert.notEqual(sig, fitSignature([{ colSpan: 1 }, ...base]));
  assert.notEqual(sig, fitSignature([base[0], base[2], base[1]]));
});
