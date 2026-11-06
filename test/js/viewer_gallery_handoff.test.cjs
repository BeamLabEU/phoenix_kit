"use strict";

// Unit tests for the gallery-mode hand-off in priv/static/assets/phoenix_kit_admin.js.
// In gallery mode (`ViewerGallery`) a swipe slides between pictures itself and
// `ViewerSwipe` stands down only after that viewer's gallery initializes.
// While Fresco loads, or on an older fresco.js, swiping keeps stepping the
// viewer instead of doing nothing.
//
// These drive the REAL handler `ViewerSwipe.mounted()` installs.
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
const { ViewerSwipe, ViewerGallery } = global.window.PhoenixKitAdminHooks;

// Mount ViewerSwipe over stubs; returns the pushed events and the swipe handler.
function mountSwipe({ activeGallery = false }) {
  let handler = null;
  const pane = {
    closest: () => ({ _pkGallery: activeGallery ? {} : null }),
    addEventListener: (name, fn) => {
      if (name === "fresco:swipe") handler = fn;
    },
    removeEventListener: noop,
    querySelector: () => null,
  };
  const pushed = [];
  const hook = Object.create(ViewerSwipe);
  hook.el = { parentElement: pane, dataset: { hasNext: "true", hasPrev: "true", target: "#mb" } };
  hook.pushEventTo = (target, event, payload) => pushed.push({ target, event, payload });

  hook.mounted();

  return {
    pushed,
    swipe: (direction) => handler({ detail: { direction } }),
  };
}

test("without gallery mode a swipe steps the viewer", () => {
  global.window.Fresco = undefined;
  const { pushed, swipe } = mountSwipe({});
  swipe("left");
  assert.deepEqual(pushed, [{ target: "#mb", event: "step_viewer", payload: { dir: "next" } }]);
});

test("with gallery mounted on a fresco that has it, the swipe is left to the gallery", () => {
  global.window.Fresco = { gallery: noop };
  const { pushed, swipe } = mountSwipe({ activeGallery: true });
  swipe("left");
  assert.deepEqual(pushed, []);
});

test("a gallery hook on an older fresco.js (no Fresco.gallery) does not swallow the swipe", () => {
  global.window.Fresco = {};
  const { pushed, swipe } = mountSwipe({});
  swipe("right");
  assert.deepEqual(pushed, [{ target: "#mb", event: "step_viewer", payload: { dir: "prev" } }]);
});

test("an uninitialized gallery does not swallow swipes even after Fresco loads", () => {
  global.window.Fresco = { gallery: noop };
  const { pushed, swipe } = mountSwipe({});
  swipe("left");
  assert.deepEqual(pushed, [{ target: "#mb", event: "step_viewer", payload: { dir: "next" } }]);
});

test("a gallery in another modal does not swallow this viewer's swipe", () => {
  global.window.Fresco = { gallery: noop };
  const realQuery = global.document.querySelector;
  global.document.querySelector = () => ({});
  try {
    const { pushed, swipe } = mountSwipe({});
    swipe("left");
    assert.deepEqual(pushed, [{ target: "#mb", event: "step_viewer", payload: { dir: "next" } }]);
  } finally {
    global.document.querySelector = realQuery;
  }
});

test("ViewerGallery mounts and tears down quietly without Fresco.gallery", async () => {
  global.window.Fresco = {};
  global.window.FrescoHooks = { FrescoViewer: {} };
  const hook = Object.create(ViewerGallery);
  hook.el = { id: "g", dataset: {}, parentElement: {} };
  assert.doesNotThrow(() => hook.mounted());
  await Promise.resolve();
  assert.doesNotThrow(() => hook.updated());
  assert.doesNotThrow(() => hook.destroyed());
});
