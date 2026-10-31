"use strict";

// Tests for PkHashHighlight in priv/static/assets/phoenix_kit_admin.js — the hook that
// lights the element the URL fragment names, so that a link followed in the app
// (history.pushState, which does not update CSS :target) looks like one loaded
// directly.
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

const { hashTargetId } = (require("../../priv/static/assets/phoenix_kit.js"), require("../../priv/static/assets/phoenix_kit_admin.js"));
const hook = global.window.PhoenixKitAdminHooks.PkHashHighlight;

function fakeElement(id) {
  const attrs = {};
  return {
    id,
    attrs,
    setAttribute: (name, value) => { attrs[name] = value; },
    removeAttribute: (name) => { delete attrs[name]; },
  };
}

// A page root holding `cards`; `outside` is an element with an id that is not inside it.
function mount(cards, hash, outside) {
  const root = {
    contains: (el) => cards.includes(el),
    querySelectorAll: (selector) => (selector === "[data-highlight]" ? cards.filter((c) => "data-highlight" in c.attrs) : []),
  };
  const all = cards.concat(outside ? [outside] : []);
  global.document.getElementById = (id) => all.find((el) => el.id === id) || null;
  global.window.location.hash = hash;

  const instance = Object.create(hook);
  instance.el = root;
  return instance;
}

test("the fragment names an id, decoded", () => {
  assert.equal(hashTargetId("#approval-1"), "approval-1");
  assert.equal(hashTargetId("#a%20b"), "a b");
});

test("no fragment, an empty one or a broken escape names nothing", () => {
  assert.equal(hashTargetId(""), null);
  assert.equal(hashTargetId("#"), null);
  assert.equal(hashTargetId("#%E0%A4%A"), null);
  assert.equal(hashTargetId(undefined), null);
});

test("the card the fragment names is lit when the page mounts", () => {
  const a = fakeElement("approval-a");
  const b = fakeElement("approval-b");
  const page = mount([a, b], "#approval-b");

  page.mounted();

  assert.ok("data-highlight" in b.attrs);
  assert.ok(!("data-highlight" in a.attrs));
});

test("the light moves when the fragment changes, and goes when there is none", () => {
  const a = fakeElement("approval-a");
  const b = fakeElement("approval-b");
  const page = mount([a, b], "#approval-a");
  page.mounted();

  global.window.location.hash = "#approval-b";
  page.updated();
  assert.ok(!("data-highlight" in a.attrs));
  assert.ok("data-highlight" in b.attrs);

  global.window.location.hash = "";
  page.updated();
  assert.ok(!("data-highlight" in b.attrs));
});

test("an element outside the page is never lit", () => {
  const a = fakeElement("approval-a");
  const stray = fakeElement("elsewhere");
  const page = mount([a], "#elsewhere", stray);

  page.mounted();

  assert.ok(!("data-highlight" in stray.attrs));
});

test("a fragment that matches nothing lights nothing", () => {
  const a = fakeElement("approval-a");
  const page = mount([a], "#approval-gone");

  page.mounted();

  assert.ok(!("data-highlight" in a.attrs));
});

// Records what the hook registers on the window, restores the stubs after `fn`.
function withWindowListeners(fn) {
  const added = [];
  const removed = [];
  const { addEventListener, removeEventListener } = global.window;
  global.window.addEventListener = (type, handler) => added.push({ type, handler });
  global.window.removeEventListener = (type, handler) => removed.push({ type, handler });
  try {
    fn(added, removed);
  } finally {
    global.window.addEventListener = addEventListener;
    global.window.removeEventListener = removeEventListener;
  }
}

test("a fragment link followed inside the page lights its card on hashchange", () => {
  const a = fakeElement("approval-a");
  const b = fakeElement("approval-b");
  const page = mount([a, b], "#approval-a");

  withWindowListeners((added) => {
    page.mounted();

    assert.deepEqual(added.map((l) => l.type), ["hashchange"]);

    global.window.location.hash = "#approval-b";
    added[0].handler();

    assert.ok(!("data-highlight" in a.attrs));
    assert.ok("data-highlight" in b.attrs);
  });
});

test("the hashchange listener is removed when the page goes away", () => {
  const a = fakeElement("approval-a");
  const page = mount([a], "#approval-a");

  withWindowListeners((added, removed) => {
    page.mounted();
    page.destroyed();

    assert.equal(removed.length, 1);
    assert.equal(removed[0].type, "hashchange");
    assert.equal(removed[0].handler, added[0].handler);
  });
});
