// Pins the correction that sizes the viewer's picture pane.
//
// Stacked (a portrait popup, or the details page on a portrait screen) the
// pane holds the picture's own ratio instead of a share of the popup's
// height, so the popup ends up as tall as the picture plus the panel rather
// than 90vh of mostly empty canvas.
//
// The server renders that ratio from the file's width and height, which is
// what makes the first paint right. It is not the last word on what gets
// painted: the viewer opens on a burned copy where one exists, and a burn
// takes in ink drawn past the picture's edges, so it is a different shape.
// And Fresco turns the picture by transforming its stage — no class, no
// patch, nothing for `updated()` to notice.
//
// So the hook measures the bitmap on screen and watches the stage.
//
//   node --test test/js/viewer_pane_fit.test.cjs

const fs = require("fs");
const path = require("path");
const assert = require("node:assert");
const { test } = require("node:test");

const SOURCE = path.join(__dirname, "..", "..", "priv", "static", "assets", "phoenix_kit_admin.js");
const src = fs.readFileSync(SOURCE, "utf8");

// Lift the hook out of the bundle and run it against a stand-in DOM.
function loadHook(getComputedStyle) {
  const start = src.indexOf("  window.PhoenixKitAdminHooks.ViewerPaneFit = {");
  assert.notStrictEqual(start, -1, "could not find the ViewerPaneFit hook");
  const end = src.indexOf("\n  };", start) + "\n  };".length;

  const observers = [];
  function FakeObserver(cb) {
    this.cb = cb;
    this.targets = [];
    this.disconnected = false;
    observers.push(this);
  }
  FakeObserver.prototype.observe = function(el, opts) { this.targets.push({ el, opts }); };
  FakeObserver.prototype.disconnect = function() { this.disconnected = true; };

  const fn = new Function(
    "window", "getComputedStyle", "MutationObserver",
    "window.PhoenixKitAdminHooks = window.PhoenixKitAdminHooks || {};" +
      src.slice(start, end) + "; return window.PhoenixKitAdminHooks.ViewerPaneFit;"
  );
  const hook = fn({}, getComputedStyle, FakeObserver);
  return { hook, observers };
}

// `transform` is what Fresco writes on the stage: rotation and zoom in one
// matrix, plus a translation for the pan.
function fakeDom(natural, transform, opts) {
  const style = {
    _v: {},
    setProperty: (k, v) => (style._v[k] = v),
    removeProperty: (k) => delete style._v[k],
  };
  const stage = { className: "fresco-stage", _transform: transform };
  const img = {
    naturalWidth: natural[0],
    naturalHeight: natural[1],
    className: (opts && opts.imgClass) || "",
    complete: !(opts && opts.pending),
    listeners: {},
    closest: (sel) => (sel === ".fresco-stage" ? stage : null),
    addEventListener: (n, fn) => (img.listeners[n] = fn),
    removeEventListener: (n) => delete img.listeners[n],
  };
  const pane = { style, querySelector: () => img };
  const el = { querySelector: (sel) => (sel === "[data-viewer-pane]" ? pane : null) };
  return { el, pane, img, stage, aspect: () => style._v["--pk-pane-aspect"] };
}

const cs = (dom) => (el) => ({ transform: el === dom.stage ? dom.stage._transform : "none" });

// LiveView calls the callbacks with the hook as `this`, carrying `el`.
function mount(hook, dom) {
  const cx = Object.create(hook);
  cx.el = dom.el;
  hook.mounted.call(cx);
  return cx;
}

// ── the shape on screen ───────────────────────────────────────────────────

test("sizes the pane to the bitmap the browser actually decoded", () => {
  // Not to the file's recorded dimensions: the viewer opens on the burned
  // copy where there is one, and a burn is a different shape from the
  // picture it was drawn over.
  const dom = fakeDom([1920, 888], "matrix(1, 0, 0, 1, 0, 0)");
  const { hook } = loadHook(cs(dom));
  mount(hook, dom);

  assert.strictEqual(dom.aspect(), "1920 / 888");
});

test("swaps the axes when Fresco has the picture on its side", () => {
  // A quarter turn is a transform on the stage, not a class on the picture:
  // matrix(0, 1, -1, 0, …). Left unswapped the pane keeps a landscape shape
  // and a turned picture is fitted into a 216px slot where it could have the
  // full width of the popup.
  const dom = fakeDom([1920, 888], "matrix(0, 1, -1, 0, 100, 200)");
  const { hook } = loadHook(cs(dom));
  mount(hook, dom);

  assert.strictEqual(dom.aspect(), "888 / 1920");
});

test("reads the turn through the zoom", () => {
  // Rotation and scale share the matrix (a = s·cosθ, b = s·sinθ), so the
  // comparison has to be between them rather than against 1 — otherwise a
  // zoomed picture reads as turned, or a turned one as upright.
  const zoomed = fakeDom([1600, 900], "matrix(0, 3.5, -3.5, 0, 0, 0)");
  const h1 = loadHook(cs(zoomed));
  mount(h1.hook, zoomed);
  assert.strictEqual(zoomed.aspect(), "900 / 1600", "turned and zoomed in");

  const flat = fakeDom([1600, 900], "matrix(0.25, 0, 0, 0.25, 0, 0)");
  const h2 = loadHook(cs(flat));
  mount(h2.hook, flat);
  assert.strictEqual(flat.aspect(), "1600 / 900", "upright and zoomed out");
});

test("a half turn leaves the shape alone", () => {
  const dom = fakeDom([1920, 888], "matrix(-1, 0, 0, -1, 10, 20)");
  const { hook } = loadHook(cs(dom));
  mount(hook, dom);

  assert.strictEqual(dom.aspect(), "1920 / 888");
});

test("still honours a rotation carried as a class", () => {
  // The stand-in copies the card's `rotate-90`, and a stage may not be there
  // at all for a picture Fresco has not taken over.
  const dom = fakeDom([1920, 888], "none", { imgClass: "w-full rotate-90" });
  const { hook } = loadHook(cs(dom));
  mount(hook, dom);

  assert.strictEqual(dom.aspect(), "888 / 1920");
});

// ── when it runs ──────────────────────────────────────────────────────────

test("waits for a bitmap that has not decoded yet", () => {
  // Mounting is not the same moment as being decoded, and a frame with no
  // size to give would otherwise be written down as one.
  const dom = fakeDom([0, 0], "matrix(1, 0, 0, 1, 0, 0)", { pending: true });
  const { hook } = loadHook(cs(dom));
  mount(hook, dom);

  assert.strictEqual(dom.aspect(), undefined, "nothing written for a 0×0 frame");
  assert.ok(dom.img.listeners.load, "…and it is listening for the decode");

  dom.img.naturalWidth = 4000;
  dom.img.naturalHeight = 3000;
  dom.img.listeners.load();
  assert.strictEqual(dom.aspect(), "4000 / 3000", "written when the bitmap arrives");
});

test("watches the stage, because rotating patches nothing", () => {
  // Fresco turns the picture itself. No class changes, no LiveView patch,
  // so `updated()` never fires — without the observer the pane keeps the
  // shape it had when the viewer opened.
  const dom = fakeDom([1920, 888], "matrix(1, 0, 0, 1, 0, 0)");
  const { hook, observers } = loadHook(cs(dom));
  mount(hook, dom);
  assert.strictEqual(dom.aspect(), "1920 / 888");

  assert.strictEqual(observers.length, 1, "one observer");
  assert.strictEqual(observers[0].targets[0].el, dom.stage, "…on the stage");
  assert.deepStrictEqual(observers[0].targets[0].opts.attributeFilter, ["style", "class"]);

  dom.stage._transform = "matrix(0, 1, -1, 0, 0, 0)";
  observers[0].cb();
  assert.strictEqual(dom.aspect(), "888 / 1920", "the turn reaches the pane");
});

test("writes only when the shape changes", () => {
  // The observer fires on every frame of a pan, and each write is a style
  // recalculation on an element the whole popup is sized from.
  const dom = fakeDom([1920, 888], "matrix(1, 0, 0, 1, 0, 0)");
  const { hook, observers } = loadHook(cs(dom));
  let writes = 0;
  const inner = dom.pane.style.setProperty;
  dom.pane.style.setProperty = (k, v) => { writes++; inner(k, v); };

  mount(hook, dom);
  assert.strictEqual(writes, 1);

  // …a pan: the translation moves, the shape does not.
  dom.stage._transform = "matrix(1, 0, 0, 1, 40, 80)";
  observers[0].cb();
  observers[0].cb();
  assert.strictEqual(writes, 1, "nothing rewritten for a pan");

  dom.stage._transform = "matrix(0, 1, -1, 0, 40, 80)";
  observers[0].cb();
  assert.strictEqual(writes, 2, "…and exactly one write for a real turn");
});

test("lets go of the picture and the stage when the viewer closes", () => {
  const dom = fakeDom([1920, 888], "matrix(1, 0, 0, 1, 0, 0)");
  const { hook, observers } = loadHook(cs(dom));
  const cx = mount(hook, dom);
  hook.destroyed.call(cx);

  assert.strictEqual(dom.img.listeners.load, undefined, "the load listener is gone");
  assert.strictEqual(observers[0].disconnected, true, "and the observer is disconnected");
});

test("does nothing at all where there is no pane", () => {
  // A board (no file) renders the same root, and the hook rides on it.
  const { hook } = loadHook(() => ({ transform: "none" }));
  assert.doesNotThrow(() => mount(hook, { el: { querySelector: () => null } }));
});
