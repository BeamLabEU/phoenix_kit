// Pins PkFitHeight: an overlay's max-height is the room left between its top
// and the bottom of its nearest scrolling ancestor (or the viewport).
//
// The hook is lifted out of the public bundle and run against a stand-in DOM
// with a fake ResizeObserver and a manual requestAnimationFrame, the way
// viewer_pane_fit.test.cjs does for the viewer.
//
//   node --test test/js/pk_fit_height.test.cjs

const fs = require("fs");
const path = require("path");
const assert = require("node:assert");
const { test } = require("node:test");

const SOURCE = path.join(__dirname, "..", "..", "priv", "static", "assets", "phoenix_kit.js");
const src = fs.readFileSync(SOURCE, "utf8");

function liftHook() {
  const start = src.indexOf("  window.PhoenixKitHooks.PkFitHeight = {");
  assert.notStrictEqual(start, -1, "could not find the PkFitHeight hook");
  const end = src.indexOf("\n  };", start) + "\n  };".length;
  return new Function(
    "window", "document",
    "window.PhoenixKitHooks = {};" + src.slice(start, end) + "; return window.PhoenixKitHooks.PkFitHeight;"
  );
}

// A page: `scroller` (bottom at `scrollerBottom`) holds the overlay, whose top
// is at `top`. Pass `scroller: false` for an overlay with no scrolling ancestor.
function page(o) {
  o = Object.assign(
    { top: 100, scrollerBottom: 500, viewport: 800, scroller: true, attrs: {}, cssCap: "none", hidden: false, ancestorOverflow: "auto" },
    o || {}
  );
  const p = { o, listeners: [], frames: [], observers: [], cancelled: [], layouts: 0 };

  const body = { tag: "body" };
  const outer = { tag: "outer", parentElement: body };
  const scroller = { tag: "scroller", parentElement: outer, getBoundingClientRect: () => ({ bottom: p.o.scrollerBottom }) };
  const inner = { tag: "inner", parentElement: o.scroller ? scroller : outer };
  const style = { maxHeight: "" };
  const el = {
    tag: "el",
    style,
    parentElement: inner,
    getAttribute: (n) => (n in p.o.attrs ? p.o.attrs[n] : null),
    getClientRects: () => (p.o.hidden ? [] : [{}]),
    getBoundingClientRect: () => ({ top: p.o.hidden ? 0 : p.o.top }),
    nodeType: 1,
    // Like the real one: only a Node will do.
    contains: (n) => {
      if (!n || typeof n.nodeType !== "number") throw new TypeError("parameter 1 is not of type 'Node'");
      return n === el || n === p.child;
    },
  };
  p.el = el;
  p.child = { tag: "child", nodeType: 1 };
  p.scroller = scroller;

  const window = {
    innerHeight: o.viewport,
    addEventListener: (type, fn, opts) => p.listeners.push({ type, fn, opts }),
    removeEventListener: (type, fn, opts) => {
      const i = p.listeners.findIndex((l) => l.type === type && l.fn === fn && !!(l.opts && l.opts.capture) === !!(opts && opts.capture));
      if (i >= 0) p.listeners.splice(i, 1);
    },
    requestAnimationFrame: (fn) => { p.frames.push(fn); return p.frames.length; },
    cancelAnimationFrame: (id) => { p.cancelled.push(id); p.frames[id - 1] = null; },
    getComputedStyle: (n) => {
      if (n === el) return { maxHeight: style.maxHeight || p.o.cssCap };
      if (n === scroller) return { overflowY: p.o.ancestorOverflow };
      return { overflowY: "visible" };
    },
    ResizeObserver: function(cb) {
      this.cb = cb; this.targets = []; this.disconnected = false;
      this.observe = (t) => this.targets.push(t);
      this.disconnect = () => { this.disconnected = true; };
      p.observers.push(this);
    },
  };
  p.window = window;
  p.hook = liftHook()(window, { body });
  p.mount = () => {
    const cx = Object.create(p.hook);
    cx.el = el;
    p.hook.mounted.call(cx);
    p.cx = cx;
    return cx;
  };
  p.flush = () => { const f = p.frames.splice(0); f.forEach((fn) => fn && fn()); };
  p.fire = (type, event) => p.listeners.filter((l) => l.type === type).forEach((l) => l.fn(event));
  p.max = () => style.maxHeight;
  return p;
}

test("the room under the overlay up to the bottom of the scrolling ancestor, less the margin", () => {
  const p = page({ top: 100, scrollerBottom: 500 });
  p.mount();
  assert.strictEqual(p.max(), "392px"); // 500 - 100 - 8
});

test("finds the nearest ancestor that scrolls, skipping the ones that do not", () => {
  const p = page();
  const cx = p.mount();
  assert.strictEqual(cx._boundary, p.scroller);
  assert.ok(p.observers[0].targets.includes(p.scroller), "the ancestor is observed");
});

test("overflow: scroll counts, overflow: hidden does not", () => {
  const scroll = page({ ancestorOverflow: "scroll" });
  assert.strictEqual(scroll.mount()._boundary, scroll.scroller);
  const hidden = page({ ancestorOverflow: "hidden" });
  assert.strictEqual(hidden.mount()._boundary, null);
});

test("falls back to the viewport with no scrolling ancestor", () => {
  const p = page({ scroller: false, top: 200, viewport: 800 });
  p.mount();
  assert.strictEqual(p.max(), "592px"); // 800 - 200 - 8
});

test("a scroller that reaches below the viewport is cut at the viewport", () => {
  const p = page({ top: 100, scrollerBottom: 2000, viewport: 700 });
  p.mount();
  assert.strictEqual(p.max(), "592px");
});

test("takes the defaults (margin 8, minimum 160) for missing and non-numeric attributes", () => {
  const p = page({ top: 100, scrollerBottom: 500, attrs: { "data-fit-margin": "lots", "data-fit-min": "" } });
  p.mount();
  assert.strictEqual(p.max(), "392px");

  const low = page({ top: 450, scrollerBottom: 500, attrs: { "data-fit-margin": "x", "data-fit-min": "y" } });
  low.mount();
  assert.strictEqual(low.max(), "160px");
});

test("reads data-fit-margin and data-fit-min", () => {
  const p = page({ top: 100, scrollerBottom: 500, attrs: { "data-fit-margin": "20" } });
  p.mount();
  assert.strictEqual(p.max(), "380px");

  const q = page({ top: 450, scrollerBottom: 500, attrs: { "data-fit-min": "40" } });
  q.mount();
  assert.strictEqual(q.max(), "42px"); // 500 - 450 - 8, above the minimum of 40
});

test("never goes below the minimum, which may overflow the area (documented)", () => {
  const p = page({ top: 450, scrollerBottom: 500 });
  p.mount();
  assert.strictEqual(p.max(), "160px"); // 42px of room, 160px by default
  const strict = page({ top: 450, scrollerBottom: 500, attrs: { "data-fit-min": "0" } });
  strict.mount();
  assert.strictEqual(strict.max(), "42px");
});

test("keeps the element's own max-height when that is smaller, and does not feed on its own value", () => {
  const p = page({ top: 100, scrollerBottom: 600, cssCap: "240px" });
  p.mount();
  assert.strictEqual(p.max(), "240px");
  // The cap is read with our inline value cleared: measuring again after the
  // room shrank must not read our 240 back as the element's own ceiling.
  p.o.scrollerBottom = 200;
  p.cx._measure();
  assert.strictEqual(p.max(), "160px"); // 92 of room, the minimum wins, under the 240 cap
  p.o.scrollerBottom = 700;
  p.cx._measure();
  assert.strictEqual(p.max(), "240px");
});

test("a ceiling that is not in pixels (none, a percentage) is not a cap", () => {
  const p = page({ top: 100, scrollerBottom: 600, cssCap: "50%" });
  p.mount();
  assert.strictEqual(p.max(), "492px");
});

test("measures again after a patch strips the inline style", () => {
  const p = page();
  const cx = p.mount();
  p.el.style.maxHeight = ""; // what morphdom does
  p.o.scrollerBottom = 400;
  p.hook.updated.call(cx);
  assert.strictEqual(p.max(), "292px");
});

test("measures on resize, on the ancestor's size and on scroll — in the next frame, not inside the callback", () => {
  const p = page();
  p.mount();
  p.o.scrollerBottom = 300;
  p.fire("resize");
  assert.strictEqual(p.max(), "392px", "nothing is written synchronously");
  assert.strictEqual(p.frames.length, 1);
  p.flush();
  assert.strictEqual(p.max(), "192px");

  p.o.scrollerBottom = 350;
  p.observers[0].cb();
  p.observers[0].cb();
  assert.strictEqual(p.frames.length, 1, "bursts are one frame");
  p.flush();
  assert.strictEqual(p.max(), "242px");

  p.o.top = 50;
  p.fire("scroll", { target: p.scroller });
  p.flush();
  assert.strictEqual(p.max(), "292px");
});

test("listens for scroll in the capture phase, and ignores the element's own scrolling", () => {
  const p = page();
  p.mount();
  const l = p.listeners.find((x) => x.type === "scroll");
  assert.ok(l && l.opts && l.opts.capture === true);

  p.fire("scroll", { target: p.el });
  p.fire("scroll", { target: p.child });
  assert.strictEqual(p.frames.length, 0);
  p.fire("scroll", { target: { nodeType: 1 } });
  assert.strictEqual(p.frames.length, 1);
});

test("a scroll whose target is the window or the document is the page's scroll, not an error", () => {
  const p = page();
  p.mount();
  p.o.scrollerBottom = 300;
  // window.dispatchEvent(new Event("scroll")): the target is the window.
  p.fire("scroll", { target: p.window });
  assert.strictEqual(p.frames.length, 1);
  p.flush();
  assert.strictEqual(p.max(), "192px");
  // A document scroll (nodeType 9).
  p.fire("scroll", { target: { nodeType: 9 } });
  assert.strictEqual(p.frames.length, 1);
  // An event with no target at all.
  p.flush();
  p.fire("scroll", {});
  assert.strictEqual(p.frames.length, 1);
});

test("reads the geometry before it clears the inline value, so it lays the page out once", () => {
  const p = page();
  p.mount();
  const order = [];
  const rect = p.el.getBoundingClientRect;
  p.el.getBoundingClientRect = () => { order.push("top"); return rect(); };
  const set = Object.getOwnPropertyDescriptor(p.el, "style");
  let value = p.el.style.maxHeight;
  Object.defineProperty(p.el.style, "maxHeight", {
    get: () => value,
    set: (v) => { order.push(v === "" ? "clear" : "set"); value = v; },
    configurable: true,
  });
  assert.ok(set);
  p.cx._measure();
  assert.deepStrictEqual(order, ["top", "clear", "set"]);
});

test("an overlay mounted hidden is not measured, then is when it appears", () => {
  const p = page({ hidden: true });
  p.mount();
  assert.strictEqual(p.max(), "", "no box, no top to measure from");
  const el = p.observers[0];
  assert.ok(el.targets.includes(p.el), "the element itself is observed");

  p.o.hidden = false;
  el.cb(); // the 0 -> visible size change
  p.flush();
  assert.strictEqual(p.max(), "392px");
});

test("takes everything down on destroyed(): listeners, observer and a pending frame", () => {
  const p = page();
  const cx = p.mount();
  assert.ok(p.listeners.length >= 2);
  p.fire("resize");
  assert.strictEqual(p.frames.length, 1);

  p.hook.destroyed.call(cx);
  assert.deepStrictEqual(p.listeners, []);
  assert.ok(p.observers[0].disconnected);
  assert.strictEqual(p.cancelled.length, 1);
  p.flush();
  assert.strictEqual(p.max(), "392px", "the cancelled frame wrote nothing");
});

test("works without ResizeObserver", () => {
  const p = page();
  p.window.ResizeObserver = undefined;
  p.mount();
  assert.strictEqual(p.max(), "392px");
});
