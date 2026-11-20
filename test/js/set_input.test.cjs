"use strict";

// The `phoenix_kit:set_input` listener in priv/static/assets/phoenix_kit.js.
// The sign-up form's email field is `phx-debounce="blur"`: its change waits for
// the field to lose focus. Taking the "Did you mean …?" hint sets the field from
// a button, so the field is not focused and no blur would ever come; the
// listener fires one, or the corrected email (and the username made from it)
// would not be checked until the submit.
//
// Run: mix test.js

const test = require("node:test");
const assert = require("node:assert/strict");

const noop = () => {};
const listeners = {};
const elements = {};

global.document = {
  activeElement: null,
  getElementById: (id) => elements[id] || null,
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener: noop,
  removeEventListener: noop,
  readyState: "complete",
};

global.window = {
  PhoenixKitHooks: {},
  addEventListener: (name, fn) => {
    (listeners[name] = listeners[name] || []).push(fn);
  },
  removeEventListener: noop,
  matchMedia: () => ({ matches: false, addEventListener: noop, removeEventListener: noop }),
  location: { href: "http://localhost/", reload: noop },
  navigator: { userAgent: "node" },
  document: global.document,
  setTimeout,
  clearTimeout,
};

require("../../priv/static/assets/phoenix_kit.js");

function field(id, debounce) {
  const fired = [];
  const el = {
    id,
    value: "",
    getAttribute: (name) => (name === "phx-debounce" ? debounce : null),
    dispatchEvent: (event) => fired.push(event.type),
  };
  elements[id] = el;
  return { el, fired };
}

function setInput(id, value) {
  for (const fn of listeners["phx:phoenix_kit:set_input"]) fn({ detail: { id, value } });
}

test("a blur-debounced field that is not focused gets its input and a blur", () => {
  const { el, fired } = field("user_email", "blur");
  document.activeElement = null;

  setInput("user_email", "me@gmail.com");

  assert.equal(el.value, "me@gmail.com");
  assert.deepEqual(fired, ["input", "blur"]);
});

test("a focused blur-debounced field gets no blur: the person is still in it", () => {
  const { el, fired } = field("user_email", "blur");
  document.activeElement = el;

  setInput("user_email", "me@gmail.com");

  assert.deepEqual(fired, ["input"]);
});

test("a field without a blur debounce gets only its input event", () => {
  const { fired } = field("plain", null);
  document.activeElement = null;

  setInput("plain", "x");

  assert.deepEqual(fired, ["input"]);
});
