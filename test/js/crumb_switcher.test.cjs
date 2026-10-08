"use strict";

// CrumbSwitcher hook in priv/static/assets/phoenix_kit.js: a picked row
// closes the panel once the patch it triggered has landed (Media, 2026-10-08:
// the panel stayed open over the newly selected library).
//
// The hook's real mounted()/updated() run over stub elements.
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

const panel = stubElement();

global.document = {
  documentElement: stubElement(),
  head: stubElement(),
  body: stubElement(),
  createElement: stubElement,
  createTextNode: () => ({}),
  getElementById: (id) => (id === "pk-title-switcher" ? panel : null),
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener: noop,
  removeEventListener: noop,
  readyState: "complete",
};

const storage = { getItem: () => null, setItem: noop, removeItem: noop, key: () => null, length: 0 };

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
  getComputedStyle: () => ({ display: "block" }),
  setTimeout,
  clearTimeout,
};
global.MutationObserver = class { observe() {} disconnect() {} };
global.localStorage = storage;
global.sessionStorage = storage;

require("../../priv/static/assets/phoenix_kit.js");
const Hook = global.window.PhoenixKitHooks.CrumbSwitcher;

function mount() {
  const hidden = [];
  let onClick;
  const el = Object.assign(stubElement(), {
    dataset: { panel: "pk-title-switcher" },
    addEventListener: (type, fn) => { if (type === "click") onClick = fn; },
  });
  const hook = Object.assign(Object.create(Hook), {
    el,
    js: () => ({ hide: (target) => hidden.push(target) }),
  });
  hook.mounted();
  const click = (onRow) =>
    onClick({ target: { closest: (sel) => (onRow && sel.includes("[data-filter-text] a") ? {} : null) } });
  return { hook, hidden, click };
}

test("a picked row closes the panel when the patch lands", () => {
  const { hook, hidden, click } = mount();
  click(true);
  hook.updated();
  assert.deepEqual(hidden, [panel]);
  hook.destroyed();
});

test("it closes once, not on every later update", () => {
  const { hook, hidden, click } = mount();
  click(true);
  hook.updated();
  hook.updated();
  assert.equal(hidden.length, 1);
  hook.destroyed();
});

test("an update with no pick leaves the panel alone", () => {
  const { hook, hidden, click } = mount();
  click(false); // a click in the search box, not on a row
  hook.updated();
  assert.equal(hidden.length, 0);
  hook.destroyed();
});
