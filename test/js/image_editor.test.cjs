"use strict";

// Unit tests for `imageEditorRect` / `imageEditorSwapped` in
// priv/static/assets/phoenix_kit_admin.js — the geometry behind the ImageEditor
// hook (drawing a crop or a redaction area on the editor's preview).
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

const {
  imageEditorRect,
  imageEditorSwapped,
} = (require("../../priv/static/assets/phoenix_kit.js"), require("../../priv/static/assets/phoenix_kit_admin.js"));

function near(actual, expected, message) {
  assert.ok(Math.abs(actual - expected) < 0.0001, `${message}: ${actual} vs ${expected}`);
}

function nearRect(actual, expected) {
  for (const key of ["x", "y", "w", "h"]) near(actual[key], expected[key], key);
}

test("a free rectangle spans the two points, whichever way it was dragged", () => {
  const expected = { x: 10, y: 20, w: 30, h: 40 };
  nearRect(imageEditorRect({ x: 10, y: 20 }, { x: 40, y: 60 }), expected);
  nearRect(imageEditorRect({ x: 40, y: 60 }, { x: 10, y: 20 }), expected);
  nearRect(imageEditorRect({ x: 40, y: 20 }, { x: 10, y: 60 }), expected);
});

test("a drag past the edge stops at the edge", () => {
  nearRect(imageEditorRect({ x: 80, y: 90 }, { x: 130, y: -20 }), { x: 80, y: 0, w: 20, h: 90 });
});

test("a shaped crop keeps its pixel shape in a frame that is not square", () => {
  // 1:1 in a 400x200 frame: 25% wide is 100 px, so 50% tall.
  const r = imageEditorRect({ x: 0, y: 0 }, { x: 25, y: 10 }, [1, 1], [400, 200]);
  nearRect(r, { x: 0, y: 0, w: 25, h: 50 });
  near((r.w / 100) * 400, (r.h / 100) * 200, "square in pixels");
});

test("the longer side of the drag decides the size", () => {
  // 16:9 in a 1600x900 frame (percentages are the same shape): a tall drag.
  const r = imageEditorRect({ x: 10, y: 10 }, { x: 12, y: 46 }, [16, 9], [1600, 900]);
  nearRect(r, { x: 10, y: 10, w: 36, h: 36 });
});

test("a shaped crop is shrunk, not squashed, to stay inside the frame", () => {
  const r = imageEditorRect({ x: 80, y: 50 }, { x: 100, y: 100 }, [1, 1], [100, 100]);
  nearRect(r, { x: 80, y: 50, w: 20, h: 20 });
});

test("a shaped crop dragged up and left grows from its start point", () => {
  const r = imageEditorRect({ x: 60, y: 60 }, { x: 40, y: 30 }, [1, 1], [100, 100]);
  nearRect(r, { x: 30, y: 30, w: 30, h: 30 });
});

test("a click is an empty rectangle", () => {
  const r = imageEditorRect({ x: 50, y: 50 }, { x: 50, y: 50 }, [4, 3], [400, 300]);
  near(r.w, 0, "w");
  near(r.h, 0, "h");
});

test("an image turned a quarter against its recorded size is recognised", () => {
  // Recorded 4000x3000 (the stored pixels), displayed 1536x2048 (EXIF 6).
  assert.equal(imageEditorSwapped([4000, 3000], [1536, 2048]), true);
  assert.equal(imageEditorSwapped([4000, 3000], [2048, 1536]), false);
});

test("square or nearly square images are never taken for turned ones", () => {
  assert.equal(imageEditorSwapped([1000, 1000], [1000, 1000]), false);
  assert.equal(imageEditorSwapped([1000, 1005], [1005, 1000]), false);
});

test("a shape matching neither size, or no size at all, is left alone", () => {
  assert.equal(imageEditorSwapped([4000, 3000], [1000, 1000]), false);
  assert.equal(imageEditorSwapped([4000, 3000], [0, 0]), false);
  assert.equal(imageEditorSwapped([NaN, NaN], [300, 400]), false);
});
