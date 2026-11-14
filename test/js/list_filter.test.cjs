"use strict";

// Unit tests for `listFilterMatches` in priv/static/assets/phoenix_kit_admin.js —
// the matching behind the ListFilter hook, which filters the breadcrumb
// switcher's list (PhoenixKitWeb.Components.Core.CrumbSwitcher) as you type.
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
  cookie: "",
};

const storage = { getItem: () => null, setItem: noop, removeItem: noop };

global.window = {
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

const { listFilterMatches } = (require("../../priv/static/assets/phoenix_kit.js"), require("../../priv/static/assets/phoenix_kit_admin.js"));

test("an empty or blank query matches everything", () => {
  assert.equal(listFilterMatches("Kitchen Furniture", ""), true);
  assert.equal(listFilterMatches("Kitchen Furniture", "   "), true);
  assert.equal(listFilterMatches("Kitchen Furniture", null), true);
});

test("matches anywhere in the label, ignoring case", () => {
  assert.equal(listFilterMatches("ACME Kitchen Furniture", "kitchen"), true);
  assert.equal(listFilterMatches("ACME Kitchen Furniture", "FURN"), true);
  assert.equal(listFilterMatches("ACME Kitchen Furniture", "bath"), false);
});

test("ignores accents both ways, so Estonian names are findable on any keyboard", () => {
  assert.equal(listFilterMatches("Käsitöö", "kasitoo"), true);
  assert.equal(listFilterMatches("Kasitoo", "käsitöö"), true);
  assert.equal(listFilterMatches("Õlid ja määrded", "oli"), true);
});

test("a missing label never throws and matches only the empty query", () => {
  assert.equal(listFilterMatches(undefined, ""), true);
  assert.equal(listFilterMatches(undefined, "a"), false);
});
