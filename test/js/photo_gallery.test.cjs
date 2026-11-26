"use strict";

// Unit tests for the photo gallery section of priv/static/assets/phoenix_kit.js
// — the client half of `<.photo_gallery>`: where a swipe settles, when a drag
// down closes, zoom and pan geometry, keys; and the delegated open/close
// against a small fake DOM.
//
// Run: mix test.js  (node --test needs the explicit file on Node 25)
const test = require("node:test");
const assert = require("node:assert/strict");

const noop = () => {};
const docListeners = {};
const winListeners = {};

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

const byId = {};
global.document = {
  documentElement: stubElement(),
  head: stubElement(),
  body: stubElement(),
  createElement: stubElement,
  createTextNode: () => ({}),
  getElementById: (id) => byId[id] || null,
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener: (type, fn) => { (docListeners[type] = docListeners[type] || []).push(fn); },
  removeEventListener: noop,
  cookie: "",
};

const storage = { getItem: () => null, setItem: noop, removeItem: noop };

global.window = {
  addEventListener: (type, fn, opts) => {
    (winListeners[type] = winListeners[type] || []).push(fn);
    if (opts && opts.signal) opts.signal.addEventListener("abort", () => global.window.removeEventListener(type, fn));
  },
  removeEventListener: (type, fn) => { winListeners[type] = (winListeners[type] || []).filter((f) => f !== fn); },
  matchMedia: () => ({ matches: false, addEventListener: noop, removeEventListener: noop }),
  localStorage: storage,
  sessionStorage: storage,
  location: { href: "http://localhost/", reload: noop },
  navigator: { userAgent: "node" },
  document: global.document,
  innerWidth: 1000,
  innerHeight: 800,
  setTimeout,
  clearTimeout,
};

global.localStorage = storage;

// The lightbox watches the page while open; tests trigger it by hand.
const observers = [];
global.MutationObserver = class {
  constructor(cb) { this.cb = cb; this.on = false; observers.push(this); }
  observe() { this.on = true; }
  disconnect() { this.on = false; }
};
function mutate() { observers.filter((o) => o.on).forEach((o) => o.cb([])); }
global.sessionStorage = storage;

const g = require("../../priv/static/assets/phoenix_kit.js").photoGallery;

test("clamp keeps an index inside the photos", () => {
  assert.equal(g.clamp(-1, 5), 0);
  assert.equal(g.clamp(7, 5), 4);
  assert.equal(g.clamp("2", 5), 2);
  assert.equal(g.clamp(3, 0), 0);
});

test("a drag picks its axis only past the slop", () => {
  assert.equal(g.axis(3, 2), null);
  assert.equal(g.axis(20, 5), "x");
  assert.equal(g.axis(-4, 30), "y");
});

test("a swipe settles on a neighbour when far or flicked, else springs back", () => {
  // 1000px wide: a quarter is 250px
  assert.equal(g.swipeTarget(2, 5, -300, 0, 1000), 3, "far to the left: next");
  assert.equal(g.swipeTarget(2, 5, 300, 0, 1000), 1, "far to the right: previous");
  assert.equal(g.swipeTarget(2, 5, -100, -0.05, 1000), 2, "short and slow: stay");
  assert.equal(g.swipeTarget(2, 5, -60, -0.8, 1000), 3, "short but flicked: next");
  assert.equal(g.swipeTarget(2, 5, -60, 0.8, 1000), 2, "a flick against the drag does not count");
  assert.equal(g.swipeTarget(4, 5, -600, -2, 1000), 4, "never past the last");
  assert.equal(g.swipeTarget(0, 5, 600, 2, 1000), 0, "never before the first");
});

test("the strip gives way only a little past either end", () => {
  assert.equal(g.rubber(100, 0, 3), 35);
  assert.equal(g.rubber(-100, 2, 3), -35);
  assert.equal(g.rubber(100, 1, 3), 100);
});

test("dragging down closes when far enough or flicked; never upwards", () => {
  assert.equal(g.dismiss(200, 0, 800), true);
  assert.equal(g.dismiss(80, 0.1, 800), false);
  assert.equal(g.dismiss(80, 0.9, 800), true);
  assert.equal(g.dismiss(-300, 2, 800), false);
  assert.ok(g.dismissOpacity(0, 800) === 1);
  assert.ok(g.dismissOpacity(240, 800) < 1);
  assert.ok(g.dismissOpacity(5000, 800) >= 0.15);
});

test("zoom keeps the point under the pointer still", () => {
  const z = g.zoomAt({ scale: 1, x: 0, y: 0 }, 2, 100, 50, 4);
  assert.deepEqual(z, { scale: 2, x: -100, y: -50 });
  // the content point under (100, 50) was 100, 50; at scale 2 it sits at x + 2*100 = 100
  assert.equal(z.x + 2 * 100, 100);
  assert.deepEqual(g.zoomAt(z, 0.5, 0, 0, 4), { scale: 1, x: 0, y: 0 }, "never below 1");
  assert.equal(g.zoomAt({ scale: 1, x: 0, y: 0 }, 10, 0, 0, 3).scale, 3, "never past max");
});

test("a zoomed photo cannot be panned off screen", () => {
  // 800×600 photo at 2× in a 1000×800 box: 600px spare across, 400px down
  const z = g.clampPan({ scale: 2, x: 900, y: -900 }, 800, 600, 1000, 800);
  assert.deepEqual(z, { scale: 2, x: 300, y: -200 });
  const small = g.clampPan({ scale: 1.1, x: 50, y: 50 }, 400, 300, 1000, 800);
  assert.deepEqual(small, { scale: 1.1, x: 0, y: 0 }, "smaller than the box: centred");
});

test("wheel and double tap zoom", () => {
  assert.ok(g.wheelScale(1, -100, 0) > 1, "wheel up zooms in");
  assert.ok(g.wheelScale(2, 100, 0) < 2, "wheel down zooms out");
  assert.ok(g.wheelScale(1, -3, 1) > g.wheelScale(1, -3, 0), "line mode steps further than pixels");
  assert.equal(g.doubleTapScale(1, 4), 2.5);
  assert.equal(g.doubleTapScale(1, 2), 2);
  assert.equal(g.doubleTapScale(2.5, 4), 1, "a second double tap zooms back out");
});

test("keys, with arrows swapped on a right-to-left page", () => {
  assert.equal(g.keyAction("ArrowLeft", false), "prev");
  assert.equal(g.keyAction("ArrowRight", false), "next");
  assert.equal(g.keyAction("ArrowLeft", true), "next");
  assert.equal(g.keyAction("Home"), "first");
  assert.equal(g.keyAction("End"), "last");
  assert.equal(g.keyAction("+"), "zoomIn");
  assert.equal(g.keyAction("-"), "zoomOut");
  assert.equal(g.keyAction("0"), "reset");
  assert.equal(g.keyAction("a"), null);
  assert.equal(g.keyAction("Escape"), null, "Esc is the dialog's own cancel");
});

test("neighbours and the counter", () => {
  assert.deepEqual(g.neighbours(0, 3), [0, 1]);
  assert.deepEqual(g.neighbours(1, 3), [0, 1, 2]);
  assert.deepEqual(g.neighbours(0, 1), [0]);
  assert.equal(g.format("{n} / {count}", 2, 9), "2 / 9");
  assert.equal(g.format("Foto {n} de {count}", 1, 3), "Foto 1 de 3");
});

// ── The delegated open, against a fake DOM ──────────────────────────────

function el(attrs, extra) {
  const a = Object.assign({}, attrs);
  const e = {
    attrs: a, style: {}, hidden: false, textContent: "", listeners: {},
    setAttribute(k, v) { a[k] = String(v); },
    getAttribute(k) { return k in a ? a[k] : null; },
    removeAttribute(k) { delete a[k]; },
    hasAttribute(k) { return k in a; },
    addEventListener(t, fn, opts) {
      (this.listeners[t] = this.listeners[t] || []).push(fn);
      if (opts && opts.signal) opts.signal.addEventListener("abort", () => this.removeEventListener(t, fn));
    },
    removeEventListener(t, fn) { this.listeners[t] = (this.listeners[t] || []).filter((f) => f !== fn); },
    querySelector: () => null,
    querySelectorAll: () => [],
    closest: () => null,
    focus() { focused = e; },
    getBoundingClientRect: () => ({ left: 100, top: 100, width: 800, height: 600 }),
  };
  return Object.assign(e, extra || {});
}

let focused = null;

function fakeGallery(count) {
  const imgs = [], slides = [], captions = [], actions = [];
  for (let i = 0; i < count; i++) {
    const img = el({ "data-pk-gallery-img": "", loading: "lazy" });
    imgs.push(img);
    const slide = el({ "data-pk-gallery-slide": String(i), "aria-label": `Photo ${i + 1} of ${count}` },
      { querySelector: (s) => (s === "img" || s === "[data-pk-gallery-img]" ? img : null) });
    if (i) { slide.attrs["aria-hidden"] = "true"; slide.attrs.inert = ""; }
    slides.push(slide);
    captions.push(el({ "data-pk-gallery-caption": String(i) }));
    actions.push(el({ "data-pk-gallery-actions": String(i) }));
  }
  const track = el({});
  const viewport = el({}, { clientWidth: 1000, clientHeight: 800, setPointerCapture: noop });
  const backdrop = el({});
  const counter = el({ "data-template": "{n} / {count}" });
  const live = el({});
  const close = el({ "data-pk-gallery-close": "" });
  const stage = el({}, {
    querySelector(s) {
      return ({
        "[data-pk-gallery-viewport]": viewport, "[data-pk-gallery-track]": track,
        "[data-pk-gallery-backdrop]": backdrop, "[data-pk-gallery-counter]": counter,
        "[data-pk-gallery-live]": live, "[data-pk-gallery-close]": close,
      })[s] || null;
    },
    querySelectorAll(s) {
      if (s === "[data-pk-gallery-slide]") return slides;
      return captions.concat(actions);
    },
  });
  const dialog = el({}, {
    open: false,
    showModal() { this.open = true; },
    close() { this.open = false; (this.listeners.close || []).forEach((f) => f({})); },
    querySelector: (s) => (s === "[data-pk-gallery-stage]" ? stage : null),
  });
  const root = el({ id: "trip", "data-pk-gallery-root": "", "data-pk-gallery-max-zoom": "4" }, {
    querySelector: (s) => (s === "[data-pk-gallery-dialog]" ? dialog : null),
  });
  root.closest = (s) => (s === "[data-pk-gallery-root]" ? root : null);
  byId.trip = root;
  return { root, dialog, stage, viewport, track, slides, imgs, captions, actions, counter, live, close };
}

function clickOn(target) {
  const ev = { target, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; } };
  (docListeners.click || []).forEach((f) => f(ev));
  return ev;
}

test("a thumbnail opens the lightbox on its photo and Esc's close returns focus", () => {
  const f = fakeGallery(3);
  const thumb = el({ "data-pk-gallery-open": "1" });
  thumb.closest = (s) => (s === "[data-pk-gallery-open]" ? thumb : s === "[data-pk-gallery-root]" ? f.root : null);
  const ev = clickOn(thumb);
  assert.equal(ev.defaultPrevented, true);
  assert.equal(f.dialog.open, true);
  assert.equal(f.track.style.transform, "translate3d(-1000px,0,0)");
  assert.equal(f.slides[1].hasAttribute("inert"), false);
  assert.equal(f.slides[0].getAttribute("aria-hidden"), "true");
  assert.equal(f.captions[1].hidden, false);
  assert.equal(f.captions[0].hidden, true);
  assert.equal(f.actions[2].hidden, true);
  assert.equal(f.counter.textContent, "2 / 3");
  assert.equal(f.live.textContent, "Photo 2 of 3");
  assert.deepEqual(f.imgs.map((i) => i.getAttribute("loading")), ["eager", "eager", "eager"]);
  assert.equal(focused, f.close, "focus goes into the lightbox");

  // Keyboard: → steps on, End jumps to the last photo.
  const key = (k) => (f.dialog.listeners.keydown || []).forEach((fn) =>
    fn({ key: k, target: f.dialog, preventDefault: noop }));
  key("ArrowRight");
  assert.equal(f.stage.getAttribute("data-index"), "2");
  key("Home");
  assert.equal(f.stage.getAttribute("data-index"), "0");

  f.dialog.close();
  assert.equal(focused, thumb, "focus goes back to the thumbnail");
  assert.deepEqual(f.dialog.listeners.keydown || [], [], "listeners go with the lightbox");
});

test("a server push opens a gallery by id", () => {
  const f = fakeGallery(2);
  (winListeners["phx:pk:photo-gallery-open"] || []).forEach((fn) => fn({ detail: { id: "trip", index: 1 } }));
  assert.equal(f.dialog.open, true);
  assert.equal(f.stage.getAttribute("data-index"), "1");
  f.dialog.close();
});

test("a lightbox removed while open (navigation, patch) lets go of the window", () => {
  const f = fakeGallery(2);
  const before = (winListeners.resize || []).length;
  (winListeners["phx:pk:photo-gallery-open"] || []).forEach((fn) => fn({ detail: { id: "trip", index: 0 } }));
  assert.equal(f.dialog.open, true);
  assert.equal(winListeners.resize.length, before + 1);
  assert.equal(observers.filter((o) => o.on).length, 1);

  // Still in the page: a mutation changes nothing.
  mutate();
  assert.equal(winListeners.resize.length, before + 1);

  // LiveView takes it out of the page; no `close` event fires.
  f.dialog.isConnected = false;
  mutate();
  assert.equal(winListeners.resize.length, before, "the resize listener is gone");
  assert.equal(observers.filter((o) => o.on).length, 0, "the observer is gone");
  assert.deepEqual(f.dialog.listeners.keydown || [], []);
});

test("a resize after removal tears down too, without an observer", () => {
  const saved = global.MutationObserver;
  global.MutationObserver = undefined;
  try {
    const f = fakeGallery(2);
    const before = (winListeners.resize || []).length;
    (winListeners["phx:pk:photo-gallery-open"] || []).forEach((fn) => fn({ detail: { id: "trip", index: 1 } }));
    f.dialog.isConnected = false;
    winListeners.resize.slice().forEach((fn) => fn({}));
    assert.equal(winListeners.resize.length, before);
  } finally {
    global.MutationObserver = saved;
  }
});

test("a resize keeps a zoomed photo on screen", () => {
  const f = fakeGallery(1);
  (winListeners["phx:pk:photo-gallery-open"] || []).forEach((fn) => fn({ detail: { id: "trip", index: 0 } }));
  // A 1,000px-wide fitted photo, zoomed 4× and panned to its limit.
  let fitted = 1000;
  f.imgs[0].getBoundingClientRect = () => {
    const z = (f.imgs[0].style.transform || "").match(/translate3d\((-?[\d.]+)px,(-?[\d.]+)px,0\) scale\(([\d.]+)\)/);
    const s = z ? +z[3] : 1, x = z ? +z[1] : 0;
    return { left: x - (fitted * s - f.viewport.clientWidth) / 2, top: 0, width: fitted * s, height: 600 * s };
  };
  const key = (k) => (f.dialog.listeners.keydown || []).forEach((fn) => fn({ key: k, target: f.dialog, preventDefault: noop }));
  key("+"); key("+"); key("+"); key("+");
  const max0 = (1000 * 4 - 1000) / 2;
  // Pan as far right as it goes.
  const viewportFire = (t, e) => (f.viewport.listeners[t] || []).forEach((fn) => fn(e));
  viewportFire("pointerdown", { pointerId: 1, clientX: 0, clientY: 0, target: f.imgs[0] });
  viewportFire("pointermove", { pointerId: 1, clientX: 5000, clientY: 0, preventDefault: noop });
  viewportFire("pointerup", { pointerId: 1, clientX: 5000, clientY: 0 });
  assert.match(f.imgs[0].style.transform, new RegExp("translate3d\\(" + max0 + "px"));

  // The window shrinks to 320px; the photo now fits at 320px.
  f.viewport.clientWidth = 320;
  fitted = 320;
  winListeners.resize.slice().forEach((fn) => fn({}));
  const x = +f.imgs[0].style.transform.match(/translate3d\((-?[\d.]+)px/)[1];
  assert.equal(x, (320 * 4 - 320) / 2, "panned back inside the new bounds");
  f.dialog.close();
});
