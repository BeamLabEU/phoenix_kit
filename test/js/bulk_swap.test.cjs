"use strict";

// Unit tests for BulkSelectScope's `data-bulk-swap` in
// priv/static/assets/phoenix_kit_admin.js — the toolbar a scope REPLACES while it
// holds a selection.
//
// Revealing the action bar without hiding anything pushes every row down, so
// the next click lands on the wrong checkbox (boss via Max, 2026-09-20;
// measured at 52px on the catalogue's category list, more than one row).
//
// The subtle part is a page with SEVERAL scopes over one toolbar: it must
// stay hidden while ANY of them has a selection, so clearing one list does
// not restore a toolbar the other list's bar is still standing in for.
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

// A tiny document the hook can query: scopes by [data-bulk-swap], and one
// toolbar reachable by its selector.
const registry = { scopes: [], targets: {} };

global.document = {
  documentElement: stubElement(),
  head: stubElement(),
  body: stubElement(),
  createElement: stubElement,
  createTextNode: () => ({}),
  getElementById: () => null,
  querySelector: (selector) => {
    if (selector === "BAD[") throw new SyntaxError("bad selector");
    return registry.targets[selector] || null;
  },
  querySelectorAll: (selector) =>
    selector === "[data-bulk-swap]" ? registry.scopes : [],
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

const { anyScopeClaims } = (require("../../priv/static/assets/phoenix_kit.js"), require("../../priv/static/assets/phoenix_kit_admin.js"));
const BulkSelectScope = global.window.PhoenixKitAdminHooks.BulkSelectScope;

// A scope element. `count` is the hook's live selection count, published on
// the element; `checkedRows` is what the DOM happens to show, which can lag
// behind after a server patch re-renders every checkbox unchecked.
function scope(selector, count, checkedRows) {
  const rows = Array.from({ length: 3 }, (_v, i) => ({ checked: i < (checkedRows ?? count) }));
  return {
    dataset: { bulkSwap: selector },
    _pkBulkCount: count,
    querySelectorAll: (sel) => (sel === '[data-bulk-role="row"]' ? rows : []),
  };
}

function setup(scopes, selector = "#toolbar") {
  const target = { style: {} };
  registry.scopes = scopes;
  registry.targets = { [selector]: target };
  return target;
}

function sync(el, count) {
  BulkSelectScope._syncSwap.call({ el }, count);
}

test("a selection hides the toolbar it replaces", () => {
  const only = scope("#toolbar", 1);
  const toolbar = setup([only]);

  sync(only, 1);
  assert.equal(toolbar.style.display, "none");
});

test("clearing the selection restores the toolbar", () => {
  const only = scope("#toolbar", 0);
  const toolbar = setup([only]);

  sync(only, 0);
  assert.equal(toolbar.style.display, "");
});

test("a second scope's selection keeps the shared toolbar hidden", () => {
  const categories = scope("#toolbar", 0);
  const items = scope("#toolbar", 2);
  const toolbar = setup([categories, items]);

  sync(categories, 0);
  assert.equal(
    toolbar.style.display,
    "none",
    "restoring here would put the toolbar back under the other list's bar"
  );
});

// The reason this reads counts and not checkboxes: after a server patch every
// checkbox renders UNCHECKED until that scope's own updated() restores it.
test("a sibling whose checkboxes have not been restored yet still counts", () => {
  const categories = scope("#toolbar", 0);
  const items = scope("#toolbar", 3, 0); // holds 3, DOM shows none checked
  const toolbar = setup([categories, items]);

  sync(categories, 0);
  assert.equal(
    toolbar.style.display,
    "none",
    "reading the DOM here would un-hide the toolbar and make the rows jump"
  );
});

test("the toolbar returns only once every scope is clear", () => {
  const categories = scope("#toolbar", 0);
  const items = scope("#toolbar", 0);
  const toolbar = setup([categories, items]);

  sync(categories, 0);
  assert.equal(toolbar.style.display, "");
});

test("a scope naming a different toolbar does not hold this one hidden", () => {
  const mine = scope("#toolbar", 0);
  const other = scope("#other-toolbar", 3);
  const toolbar = setup([mine, other]);

  sync(mine, 0);
  assert.equal(toolbar.style.display, "");
});

test("syncing publishes this scope's own count before asking the others", () => {
  const only = scope("#toolbar", 0);
  const toolbar = setup([only]);

  sync(only, 4);
  assert.equal(only._pkBulkCount, 4);
  assert.equal(toolbar.style.display, "none");
});

// A list can be patched away mid-selection. Its count goes with it, and the
// toolbar it was standing in for has to come back.
test("a destroyed scope releases the toolbar", () => {
  const going = scope("#toolbar", 2);
  const toolbar = setup([going]);
  sync(going, 2);
  assert.equal(toolbar.style.display, "none");

  registry.scopes = [];
  BulkSelectScope.destroyed.call({ el: going });
  assert.equal(going._pkBulkCount, 0);
  assert.equal(toolbar.style.display, "");
});

test("a destroyed scope leaves the toolbar hidden when another still claims it", () => {
  const going = scope("#toolbar", 1);
  const staying = scope("#toolbar", 2);
  const toolbar = setup([going, staying]);
  sync(going, 1);

  registry.scopes = [staying];
  BulkSelectScope.destroyed.call({ el: going });
  assert.equal(toolbar.style.display, "none");
});

test("a scope with no swap target does nothing at all", () => {
  const toolbar = setup([]);
  sync({ dataset: {} }, 2);
  assert.deepEqual(toolbar.style, {}, "an untouched toolbar keeps its own display");
});

test("a missing target is survivable", () => {
  registry.scopes = [];
  registry.targets = {};
  assert.doesNotThrow(() => sync({ dataset: { bulkSwap: "#gone" } }, 1));
});

test("a malformed selector never takes the page down", () => {
  registry.scopes = [];
  registry.targets = {};
  assert.doesNotThrow(() => sync({ dataset: { bulkSwap: "BAD[" } }, 1));
  assert.doesNotThrow(() => BulkSelectScope.destroyed.call({ el: { dataset: { bulkSwap: "BAD[" } } }));
});

test("anyScopeClaims ignores a scope that never published a count", () => {
  registry.scopes = [{ dataset: { bulkSwap: "#toolbar" } }];
  assert.equal(anyScopeClaims("#toolbar"), false);
});
