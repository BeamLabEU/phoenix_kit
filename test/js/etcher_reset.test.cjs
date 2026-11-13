"use strict";

// Regression test for the EtcherReset hook in
// priv/static/assets/phoenix_kit_admin.js.
//
// "Reset annotation settings" on /profile/settings clears two halves: the
// palette and ink on the user row (server-side) and Etcher's own
// how-you-work answers in localStorage (here). The hook is the only thing
// that reaches the second half, so two ways of failing matter — listening
// for the wrong event name, and writing the wrong storage key. Either one
// leaves the person half-reset with a success message on screen, which is
// exactly the state the single button exists to prevent.
//
// The key is pinned against Etcher's own source at the bottom: `_prefsKey`
// is Etcher's to rename, and a rename it does not see makes this hook a
// no-op silently.
//
// Run: mix test.js  (node --test needs the explicit file on Node 25)

const fs = require("fs");
const path = require("path");
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
    createTextNode: () => ({}),
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

// Records what the hook asks to be removed, so a test can assert the key.
const removed = [];
const storage = {
  getItem: () => null,
  setItem: noop,
  removeItem: (k) => removed.push(k),
  key: () => null,
  length: 0,
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

(require("../../priv/static/assets/phoenix_kit.js"), require("../../priv/static/assets/phoenix_kit_admin.js"));

const hook = window.PhoenixKitAdminHooks.EtcherReset;

// Stands in for LiveView's hook context: `handleEvent` records the
// subscription rather than wiring a real socket, so a test can fire the
// server's push by hand.
function mountHook() {
  const handlers = {};
  const ctx = Object.create(hook);
  ctx.el = stubElement();
  ctx.pushEvent = noop;
  ctx.handleEvent = (event, callback) => {
    handlers[event] = callback;
  };
  ctx.mounted();
  return { ctx, handlers };
}

test("the hook exists — a `phx-hook` naming one that does not is a silent no-op", () => {
  assert.equal(typeof hook, "object");
  assert.equal(typeof hook.mounted, "function");
});

test("clears Etcher's prefs on the server's push", () => {
  removed.length = 0;
  const { handlers } = mountHook();

  const handler = handlers["phoenix_kit:etcher-reset"];
  assert.equal(
    typeof handler,
    "function",
    "the hook listens for the event the settings page pushes, spelled the same way"
  );

  handler({});
  assert.deepEqual(removed, ["etcher:prefs"]);
});

test("a storage that refuses does not throw at the person clicking", () => {
  const { handlers } = mountHook();
  const original = window.localStorage;
  window.localStorage = {
    removeItem: () => {
      throw new Error("private mode");
    },
  };

  try {
    // Private browsing and a blocked store both land here. The server half
    // already happened, so there is nothing worth failing the page over.
    assert.doesNotThrow(() => handlers["phoenix_kit:etcher-reset"]({}));
  } finally {
    window.localStorage = original;
  }
});

test("etcher.js really does store its preferences under that key", () => {
  const etcher = path.join(__dirname, "..", "..", "deps", "etcher", "priv", "static", "etcher.js");
  if (!fs.existsSync(etcher)) return; // deps not fetched — nothing to pin against

  assert.ok(
    fs.readFileSync(etcher, "utf8").includes('_prefsKey: "etcher:prefs"'),
    "Etcher renamed its prefs key — the reset now clears nothing and says it worked"
  );
});
