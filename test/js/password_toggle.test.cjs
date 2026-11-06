"use strict";

// Unit tests for hideRevealedPasswords in priv/static/assets/phoenix_kit.js,
// which masks `<.input password_toggle>` fields again when their form is sent.
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
  readyState: "complete",
};

const storage = {
  getItem: () => null,
  setItem: noop,
  removeItem: noop,
  key: () => null,
  length: 0,
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

const { hideRevealedPasswords } = require("../../priv/static/assets/phoenix_kit.js");

test("presses only the pressed buttons of the form", () => {
  let selector = null;
  let clicks = 0;
  const form = {
    querySelectorAll(query) {
      selector = query;
      return [{ click: () => clicks++ }, { click: () => clicks++ }];
    },
  };

  hideRevealedPasswords(form);

  assert.equal(clicks, 2);
  assert.equal(selector, '[data-pk-password-toggle][aria-pressed="true"]');
});

test("a form with nothing revealed is left alone", () => {
  assert.doesNotThrow(() => hideRevealedPasswords({ querySelectorAll: () => [] }));
});

test("a submit from something that is not a form does not throw", () => {
  assert.doesNotThrow(() => hideRevealedPasswords(null));
  assert.doesNotThrow(() => hideRevealedPasswords({}));
});
