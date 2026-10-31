"use strict";

// Unit tests for `treePickerEnter` in priv/static/assets/phoenix_kit_admin.js — the
// predicate behind TreePickerSearch's Enter (search at once, never submit the
// surrounding form, and leave an input method's composing Enter alone) — and
// for the hook itself: the picker often sits inside a host form, so what is
// typed in its search box must never reach that form's phx-change or submit.
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

const { treePickerEnter } = (require("../../priv/static/assets/phoenix_kit.js"), require("../../priv/static/assets/phoenix_kit_admin.js"));

test("Enter searches at once", () => {
  assert.equal(treePickerEnter({ key: "Enter" }), true);
});

test("an input method's composing Enter is left to confirm the composition", () => {
  assert.equal(treePickerEnter({ key: "Enter", isComposing: true }), false);
});

test("other keys are typing, not a search", () => {
  assert.equal(treePickerEnter({ key: "a" }), false);
  assert.equal(treePickerEnter(null), false);
});

// ── The hook: what it does with each event ──

const hookDef = global.window.PhoenixKitAdminHooks.TreePickerSearch;

// The hook on a fake input: records its listeners and what it pushes.
function mountHook(value = "oak") {
  const listeners = {};
  const pushed = [];

  const hook = Object.assign(Object.create(hookDef), {
    el: {
      value,
      addEventListener: (type, fn) => (listeners[type] = fn),
      removeEventListener: noop,
    },
    pushEventTo: (_el, event, payload) => pushed.push([event, payload]),
  });

  hook.mounted();
  return { hook, listeners, pushed };
}

function event(attrs = {}) {
  const e = { stopped: false, prevented: false, isComposing: false };
  e.stopPropagation = () => (e.stopped = true);
  e.preventDefault = () => (e.prevented = true);
  return Object.assign(e, attrs);
}

test("typing never reaches a surrounding form", () => {
  const { hook, listeners } = mountHook();
  const input = event();
  listeners.input(input);
  assert.equal(input.stopped, true);

  const change = event();
  listeners.change(change);
  assert.equal(change.stopped, true);
  hook.destroyed();
});

test("Enter searches at once and submits nothing", () => {
  const { listeners, pushed } = mountHook("oak");
  const enter = event({ key: "Enter" });
  listeners.keydown(enter);

  assert.equal(enter.prevented, true);
  assert.equal(enter.stopped, true);
  assert.deepEqual(pushed, [["search", { value: "oak" }]]);
});

test("Enter while an input method composes is left to the composition", () => {
  const { listeners, pushed } = mountHook();
  const enter = event({ key: "Enter", isComposing: true });
  listeners.keydown(enter);

  assert.equal(enter.prevented, false);
  assert.equal(enter.stopped, false);
  assert.deepEqual(pushed, []);
});

test("other keys are not touched", () => {
  const { listeners, pushed } = mountHook();
  const key = event({ key: "a" });
  listeners.keydown(key);

  assert.equal(key.prevented, false);
  assert.equal(key.stopped, false);
  assert.deepEqual(pushed, []);
});
