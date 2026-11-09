"use strict";

// AvatarPeek in priv/static/assets/phoenix_kit_admin.js: hovering a
// `<.user_avatar peek>` shows a larger copy beside it, fixed to the viewport.
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

const docListeners = {};
const appended = [];

global.document = {
  documentElement: stubElement(),
  head: stubElement(),
  body: Object.assign(stubElement(), {
    appendChild: (child) => {
      appended.push(child);
      child.parentNode = global.document.body;
    },
    removeChild: (child) => {
      appended.splice(appended.indexOf(child), 1);
      child.parentNode = null;
    },
  }),
  createElement: stubElement,
  createTextNode: () => ({}),
  getElementById: () => null,
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener: (type, fn) => {
    (docListeners[type] = docListeners[type] || []).push(fn);
  },
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

global.window.innerWidth = 1000;
global.window.innerHeight = 800;
global.requestAnimationFrame = (fn) => fn();

const { avatarPeekPosition } = (require("../../priv/static/assets/phoenix_kit.js"), require("../../priv/static/assets/phoenix_kit_admin.js"));

test("the preview sits beside the avatar, inside the viewport", () => {
  const viewport = { width: 1000, height: 800 };
  const right = avatarPeekPosition({ left: 100, right: 132, top: 300, height: 32 }, 176, viewport);
  assert.equal(right.left, 144, "to the right, past a gap");
  assert.equal(right.top, 300 + 16 - 96, "centred on the avatar");

  const nearEdge = avatarPeekPosition({ left: 950, right: 982, top: 5, height: 32 }, 176, viewport);
  assert.ok(nearEdge.left + 192 <= 950, "flips to the left near the right edge");
  assert.equal(nearEdge.top, 12, "never above the viewport");
});

// A wrapper and its frame, the way UserInfo renders them with `peek`.
function avatar() {
  const img = { src: "/small.jpg" };
  const clone = {
    style: {},
    removeAttribute: () => {},
    querySelector: (sel) => (sel === "img" ? img : null),
  };
  const frame = { cloneNode: () => clone };
  const el = {
    getAttribute: (name) => (name === "data-avatar-peek" ? "/medium.jpg" : null),
    querySelector: (sel) => (sel === "[data-avatar-frame]" ? frame : null),
    getBoundingClientRect: () => ({ left: 100, right: 132, top: 300, height: 32 }),
  };
  const child = { closest: (sel) => (sel === "[data-avatar-peek]" ? el : null) };
  return { el, child, clone, img };
}

const hover = (target) => docListeners.mouseover.forEach((fn) => fn({ target }));

test("hovering shows one larger copy with the larger picture; leaving removes it", () => {
  const a = avatar();
  hover(a.child);
  assert.equal(appended.length, 1, "one preview");
  const panel = appended[0];
  assert.equal(panel.style.cssText.includes("position:fixed"), true, "fixed: no table clips it");
  assert.equal(a.clone.style.width, "176px");
  assert.equal(a.img.src, "/medium.jpg", "the picture sized for the preview");

  hover(a.child);
  assert.equal(appended.length, 1, "moving within the avatar keeps the one preview");

  hover({ closest: () => null });
  assert.equal(appended.length, 0, "gone once the pointer leaves");
});

test("scrolling hides the preview", () => {
  hover(avatar().child);
  assert.equal(appended.length, 1);
  docListeners.scroll.forEach((fn) => fn({}));
  assert.equal(appended.length, 0);
});
