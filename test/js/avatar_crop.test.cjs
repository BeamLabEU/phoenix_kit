"use strict";

// Unit tests for `avatarCropLayout` / `clampAvatarCropFocal` in
// priv/static/assets/phoenix_kit_admin.js — the geometry behind the AvatarCrop
// hook. The same math lives server-side in PhoenixKit.Users.AvatarCrop
// (layout/1), where its own tests pin the same cases: the preview must
// render exactly what the avatar component will later render.
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
  avatarCropLayout,
  clampAvatarCropFocal,
} = (require("../../priv/static/assets/phoenix_kit.js"), require("../../priv/static/assets/phoenix_kit_admin.js"));

function near(actual, expected, message) {
  assert.ok(Math.abs(actual - expected) < 0.0001, `${message}: ${actual} vs ${expected}`);
}

test("zoom 1 centered is exactly the cover fit", () => {
  // A 3:2 landscape at zoom 1: height fills the frame, width overflows
  // symmetrically — what object-fit: cover with a centered position shows.
  const l = avatarCropLayout({ x: 0.5, y: 0.5, zoom: 1, ar: 1.5 });
  near(l.width, 150, "width");
  near(l.height, 100, "height");
  near(l.left, -25, "left");
  near(l.top, 0, "top");
});

test("portrait mirrors landscape", () => {
  const l = avatarCropLayout({ x: 0.5, y: 0.5, zoom: 1, ar: 0.5 });
  near(l.width, 100, "width");
  near(l.height, 200, "height");
  near(l.left, 0, "left");
  near(l.top, -50, "top");
});

test("zoom magnifies around the focal point", () => {
  const l = avatarCropLayout({ x: 0.5, y: 0.5, zoom: 2, ar: 1 });
  near(l.width, 200, "width");
  near(l.height, 200, "height");
  // The focal center stays at the frame center: 50 - 0.5*200 = -50.
  near(l.left, -50, "left");
  near(l.top, -50, "top");
});

test("the frame never sees past an edge", () => {
  // Focal point dragged all the way into a corner: the offsets clamp so the
  // image still covers the whole frame — no background peeking through.
  const l = avatarCropLayout({ x: 0, y: 0, zoom: 2, ar: 1 });
  near(l.left, 0, "left clamps at the leading edge");
  near(l.top, 0, "top clamps at the leading edge");

  const r = avatarCropLayout({ x: 1, y: 1, zoom: 2, ar: 1 });
  near(r.left, -100, "left clamps at the trailing edge");
  near(r.top, -100, "top clamps at the trailing edge");
});

test("focal clamping keeps the drag alive at the edges", () => {
  // A focal value that would render clamped snaps back into the reachable
  // range — otherwise dragging near an edge accumulates invisible distance
  // that must be dragged back before anything moves again.
  const c = clampAvatarCropFocal({ x: 0, y: 1, zoom: 2, ar: 1 });
  near(c.x, 0.25, "x snaps to the edge of the reachable range");
  near(c.y, 0.75, "y snaps to the edge of the reachable range");
});

test("an axis the image only just covers pins to center", () => {
  // Landscape at zoom 1: the height exactly fits the frame, so there is no
  // vertical freedom at all — y collapses to 0.5, x keeps its freedom.
  const c = clampAvatarCropFocal({ x: 0.9, y: 0.1, zoom: 1, ar: 2 });
  near(c.y, 0.5, "no vertical freedom");
  near(c.x, 0.75, "horizontal freedom is real but clamped");
});

// --- The AvatarCrop hook itself: pointer, wheel and pinch gestures -------

// A 200×200 frame at the viewport origin, holding a square image.
function mountCrop(crop) {
  const listeners = {};
  const frame = {
    style: {},
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 200, height: 200 }),
    addEventListener: (type, fn) => { listeners[type] = fn; },
    removeEventListener: noop,
    setPointerCapture: noop,
    hasPointerCapture: () => false,
    releasePointerCapture: noop,
  };
  const img = { style: {}, complete: false, naturalWidth: 0, addEventListener: noop };
  const el = {
    dataset: { crop: JSON.stringify(crop) },
    closest: () => null,
    querySelector: (sel) =>
      sel === "[data-crop-frame]" ? frame : sel === "[data-crop-img]" ? img : null,
  };
  const pushes = [];
  const hook = Object.assign(Object.create(window.PhoenixKitAdminHooks.AvatarCrop), {
    el,
    pushEventTo: (_el, event, payload) => pushes.push({ event, payload }),
  });
  hook.mounted();
  const fire = (type, e) =>
    listeners[type](Object.assign({ preventDefault: noop, pointerType: "mouse", button: 0 }, e));
  return { hook, fire, pushes };
}

test("a drag keeps panning after its first move", () => {
  // The regression: pointermove replaced the drag state with the pointer
  // position alone, so from the second move on the focal point was NaN
  // and the picture froze.
  const { hook, fire, pushes } = mountCrop({ x: 0.5, y: 0.5, zoom: 2, ar: 1 });
  fire("pointerdown", { pointerId: 1, clientX: 100, clientY: 100 });
  const xs = [];
  for (const cx of [90, 80, 70]) {
    fire("pointermove", { pointerId: 1, clientX: cx, clientY: 100 });
    assert.ok(Number.isFinite(hook.crop.x), "focal x stays a number");
    xs.push(hook.crop.x);
  }
  // Image 400px wide in a 200px frame: 10px left = 1/40 of the image right.
  near(xs[0], 0.525, "first move");
  near(xs[1], 0.55, "second move still pans");
  near(xs[2], 0.575, "third move still pans");
  fire("pointerup", { pointerId: 1 });
  assert.equal(pushes.length, 1, "one push when the gesture ends");
  near(pushes[0].payload.x, 0.575, "the pushed crop is the dragged one");
});

test("the wheel zooms toward the point under the cursor", () => {
  const { hook, fire } = mountCrop({ x: 0.5, y: 0.5, zoom: 2, ar: 1 });
  // Image point under the cursor at (150, 50) before the zoom.
  const at = (l) => ({ u: (75 - l.left) / l.width, v: (25 - l.top) / l.height });
  const before = at(avatarCropLayout(hook.crop));
  fire("wheel", { clientX: 150, clientY: 50, deltaY: -100, deltaMode: 0 });
  assert.ok(hook.crop.zoom > 2, "wheel up zooms in");
  const after = at(avatarCropLayout(hook.crop));
  near(after.u, before.u, "same image column under the cursor");
  near(after.v, before.v, "same image row under the cursor");
  clearTimeout(hook._wheelTimer);
});

test("two pointers pinch to zoom; lifting one carries on panning", () => {
  const { hook, fire } = mountCrop({ x: 0.5, y: 0.5, zoom: 2, ar: 1 });
  const touch = { pointerType: "touch" };
  fire("pointerdown", { ...touch, pointerId: 1, clientX: 80, clientY: 100 });
  fire("pointerdown", { ...touch, pointerId: 2, clientX: 120, clientY: 100 });
  // Fingers twice as far apart about the same midpoint: zoom doubles.
  fire("pointermove", { ...touch, pointerId: 1, clientX: 60, clientY: 100 });
  fire("pointermove", { ...touch, pointerId: 2, clientX: 140, clientY: 100 });
  near(hook.crop.zoom, 4, "pinch out doubles the zoom");
  near(hook.crop.x, 0.5, "zoom about the centre keeps the focal point");

  fire("pointerup", { ...touch, pointerId: 2 });
  const x = hook.crop.x;
  fire("pointermove", { ...touch, pointerId: 1, clientX: 40, clientY: 100 });
  assert.ok(Number.isFinite(hook.crop.x) && hook.crop.x > x, "the remaining finger pans");
});
