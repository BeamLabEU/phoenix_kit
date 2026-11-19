// Pins PkResizable, the hook of `<.resizable_modal>`'s box.
//
// The dialog centres its box, so a drag moves both opposite edges: the size
// changes by twice the pointer's travel. What is kept in localStorage is the
// size the person saw, not what the pointer did; a press that barely moves is
// a click; below 640px there is nothing to resize.
//
// The hook is lifted out of the public bundle and run against a stand-in DOM
// (the way viewer_pane_fit.test.cjs does it for the viewer).
//
//   node --test test/js/pk_resizable.test.cjs

const fs = require("fs");
const path = require("path");
const assert = require("node:assert");
const { test } = require("node:test");

const SOURCE = path.join(__dirname, "..", "..", "priv", "static", "assets", "phoenix_kit.js");
const src = fs.readFileSync(SOURCE, "utf8");

function liftHook() {
  const start = src.indexOf("  window.PhoenixKitHooks.PkResizable = {");
  assert.notStrictEqual(start, -1, "could not find the PkResizable hook");
  const end = src.indexOf("\n  };", start) + "\n  };".length;
  return new Function(
    "window", "document",
    "window.PhoenixKitHooks = {};" + src.slice(start, end) + "; return window.PhoenixKitHooks.PkResizable;"
  );
}

// A box of 600x400 (what the server rendered) with grips; `opts.stored` is
// what localStorage holds for its key, `opts.width` the window's width.
function page(opts) {
  const o = Object.assign({ width: 1280, height: 800, stored: null, attrs: {}, boxW: 600, boxH: 400 }, opts || {});
  const store = {};
  if (o.stored !== null) store["pk:resizable:compose"] = typeof o.stored === "string" ? o.stored : JSON.stringify(o.stored);
  const p = { store, writes: [], captured: [], released: [], listeners: {}, winListeners: {} };

  const attrs = Object.assign({ "data-size-key": "compose", "data-min-width": "320", "data-min-height": "240" }, o.attrs);
  const props = {};
  const style = {
    setProperty: (k, v) => (props[k] = v),
    removeProperty: (k) => delete props[k],
  };
  const grips = {};
  const el = {
    style,
    dataset: {},
    getAttribute: (n) => (n in attrs ? attrs[n] : null),
    contains: (n) => n === el || Object.values(grips).includes(n),
    getBoundingClientRect: () => ({ width: p.boxW, height: p.boxH }),
    addEventListener: (t, fn) => (p.listeners[t] = fn),
  };
  p.boxW = o.boxW;
  p.boxH = o.boxH;
  for (const dir of ["n", "s", "e", "w", "ne", "nw", "se", "sw"]) {
    grips[dir] = {
      getAttribute: () => dir,
      setPointerCapture: (id) => p.captured.push(id),
      releasePointerCapture: (id) => p.released.push(id),
    };
  }
  const rootStyle = { userSelect: "" };
  const window = {
    innerWidth: o.width,
    innerHeight: o.height,
    localStorage: {
      getItem: (k) => (k in store ? store[k] : null),
      setItem: (k, v) => { store[k] = v; p.writes.push(v); },
      removeItem: (k) => { delete store[k]; p.writes.push(null); },
    },
    addEventListener: (t, fn) => (p.winListeners[t] = fn),
    removeEventListener: (t) => delete p.winListeners[t],
  };
  p.window = window;
  p.el = el;
  p.props = props;
  p.root = rootStyle;
  p.hook = liftHook()(window, { documentElement: { style: rootStyle } });
  p.mount = () => {
    const cx = Object.create(p.hook);
    cx.el = el;
    p.hook.mounted.call(cx);
    p.cx = cx;
    return cx;
  };
  const target = (dir) => ({ closest: () => grips[dir] });
  p.down = (dir, x, y, extra) => p.listeners.pointerdown(Object.assign({ target: target(dir), button: 0, clientX: x, clientY: y, pointerId: 1, preventDefault() {} }, extra));
  p.move = (x, y, extra) => p.listeners.pointermove(Object.assign({ clientX: x, clientY: y, pointerId: 1, buttons: 1 }, extra));
  p.up = () => p.listeners.pointerup({ pointerId: 1 });
  p.dbl = (dir) => p.listeners.dblclick({ target: target(dir) });
  p.drag = (dir, from, to) => { p.down(dir, from[0], from[1]); p.move(to[0], to[1]); p.up(); };
  p.kept = () => (p.store["pk:resizable:compose"] ? JSON.parse(p.store["pk:resizable:compose"]) : null);
  return p;
}

test("a drag changes the size by twice the pointer's travel: both opposite edges move", () => {
  const p = page();
  p.mount();
  p.drag("e", [900, 300], [950, 300]);
  assert.strictEqual(p.props.width, "700px"); // 600 + 2 * 50
  assert.strictEqual(p.props["max-width"], "none");
  assert.strictEqual(p.props.height, undefined, "an east drag leaves the height alone");
});

test("each edge and corner moves its own axes in the right direction", () => {
  const cases = [
    ["w", [100, 0], [80, 0], 640, undefined],  // the west edge going out widens
    ["s", [0, 600], [0, 630], undefined, 460],
    ["n", [0, 100], [0, 70], undefined, 460],  // the north edge going up makes it taller
    ["se", [900, 600], [910, 620], 620, 440],
    ["nw", [100, 100], [90, 80], 620, 440],
  ];
  for (const [dir, a, b, w, h] of cases) {
    const p = page();
    p.mount();
    p.drag(dir, a, b);
    assert.strictEqual(p.props.width, w === undefined ? undefined : w + "px", dir + " width");
    assert.strictEqual(p.props.height, h === undefined ? undefined : h + "px", dir + " height");
  }
});

test("never smaller than the minimum, never larger than the viewport less the margin", () => {
  const small = page();
  small.mount();
  small.drag("e", [900, 300], [100, 300]);
  assert.strictEqual(small.props.width, "320px");

  const big = page({ width: 1280 });
  big.mount();
  big.drag("e", [900, 300], [1270, 300]);
  assert.strictEqual(big.props.width, "1248px"); // 1280 - 2 * 16

  const tall = page({ height: 800 });
  tall.mount();
  tall.drag("s", [0, 400], [0, 790]);
  assert.strictEqual(tall.props.height, "768px");
});

test("keeps in localStorage the size that was shown, not what the pointer did", () => {
  const small = page();
  small.mount();
  small.drag("e", [900, 300], [100, 300]); // the pointer says -> 600 - 1600 < 0
  assert.deepStrictEqual(small.kept(), { w: 320 });

  const big = page();
  big.mount();
  big.drag("e", [900, 300], [1270, 300]); // the pointer says 1340
  assert.deepStrictEqual(big.kept(), { w: 1248 });
});

test("reads a kept size when it is put on the page, and applies it clamped to this window", () => {
  const p = page({ stored: { w: 800, h: 500 } });
  p.mount();
  assert.strictEqual(p.props.width, "800px");
  assert.strictEqual(p.props.height, "500px");
  assert.strictEqual(p.props["max-height"], "none");
  assert.strictEqual(p.el.dataset.pkResized, "true");

  const narrow = page({ stored: { w: 1200 }, width: 900 });
  narrow.mount();
  assert.strictEqual(narrow.props.width, "868px", "a smaller window shrinks the box");
  assert.deepStrictEqual(narrow.kept(), { w: 1200 }, "…without forgetting the kept size");
});

test("a kept size that is not a size is ignored", () => {
  for (const stored of ["{not json", "null", "5", JSON.stringify({ w: "wide" })]) {
    const p = page({ stored });
    p.mount();
    assert.deepStrictEqual(p.props, {}, String(stored));
  }
});

test("a double click on a grip forgets the size and gives the box back to the server", () => {
  const p = page({ stored: { w: 800, h: 500 } });
  p.mount();
  p.dbl("e");
  assert.strictEqual(p.kept(), null);
  assert.deepStrictEqual(p.props, {}, "the hook's inline size is gone");
  assert.strictEqual(p.el.dataset.pkResized, undefined);
});

test("a press that barely moves is a click: nothing is fixed, nothing is kept", () => {
  const p = page();
  p.mount();
  p.drag("e", [900, 300], [902, 301]);
  assert.deepStrictEqual(p.props, {});
  assert.strictEqual(p.kept(), null);
  assert.strictEqual(p.root.userSelect, "", "text selection is back");
  assert.deepStrictEqual(p.writes, []);

  // Past the threshold the size follows the whole travel, not what is left of it.
  p.down("e", 900, 300);
  p.move(903, 300);
  assert.deepStrictEqual(p.props, {});
  p.move(910, 300);
  assert.strictEqual(p.props.width, "620px");
  p.up();
});

test("the page's text selection is off during a drag and back after it", () => {
  const p = page();
  p.mount();
  p.down("e", 900, 300);
  assert.strictEqual(p.root.userSelect, "none");
  assert.deepStrictEqual(p.captured, [1]);
  p.move(950, 300);
  p.up();
  assert.strictEqual(p.root.userSelect, "");
  assert.deepStrictEqual(p.released, [1]);
});

test("a drag that loses pointer capture ends there and keeps what is on screen", () => {
  const p = page();
  p.mount();
  p.down("e", 900, 300);
  p.move(950, 300);
  p.listeners.lostpointercapture({ pointerId: 1 });
  assert.strictEqual(p.root.userSelect, "");
  assert.deepStrictEqual(p.kept(), { w: 700 });
  p.move(1000, 300); // a later move is nobody's drag
  assert.strictEqual(p.props.width, "700px");
});

test("a move with no button down ends a drag that never got its pointerup", () => {
  const p = page();
  p.mount();
  p.down("e", 900, 300);
  p.move(950, 300);
  p.move(1000, 300, { buttons: 0 });
  assert.strictEqual(p.root.userSelect, "");
  assert.deepStrictEqual(p.kept(), { w: 700 });
  assert.strictEqual(p.props.width, "700px");
});

test("pointercancel ends it too, and a second pointer's events are not the drag's", () => {
  const p = page();
  p.mount();
  p.down("e", 900, 300);
  p.listeners.pointermove({ clientX: 990, clientY: 300, pointerId: 2, buttons: 1 });
  assert.deepStrictEqual(p.props, {});
  p.listeners.pointercancel({ pointerId: 1 });
  assert.strictEqual(p.root.userSelect, "");
});

test("only a primary press on a grip starts a drag", () => {
  const p = page();
  p.mount();
  p.down("e", 900, 300, { button: 2 });
  assert.strictEqual(p.root.userSelect, "");
  p.listeners.pointerdown({ target: { closest: () => null }, button: 0, clientX: 1, clientY: 1, pointerId: 1, preventDefault() {} });
  assert.strictEqual(p.root.userSelect, "");
});

test("below 640px there is nothing to resize and no kept size is applied", () => {
  const p = page({ width: 390, stored: { w: 800, h: 500 } });
  p.mount();
  assert.deepStrictEqual(p.props, {}, "the phone sheet keeps its own classes");
  p.down("e", 300, 300);
  assert.strictEqual(p.root.userSelect, "", "no drag starts");
  assert.deepStrictEqual(p.kept(), { w: 800, h: 500 }, "the kept size is not lost");
});

test("narrowing the window below 640px lets go of the inline size, widening brings it back", () => {
  const p = page({ stored: { w: 800, h: 500 } });
  p.mount();
  assert.strictEqual(p.props.width, "800px");

  p.window.innerWidth = 500;
  p.winListeners.resize();
  assert.deepStrictEqual(p.props, {});

  p.window.innerWidth = 1280;
  p.winListeners.resize();
  assert.strictEqual(p.props.width, "800px");
  assert.strictEqual(p.props.height, "500px");
});

test("a patch strips the inline size and updated() puts it back", () => {
  const p = page({ stored: { w: 800, h: 500 } });
  const cx = p.mount();
  for (const k of Object.keys(p.props)) delete p.props[k]; // morphdom, from the server's style
  p.hook.updated.call(cx);
  assert.strictEqual(p.props.width, "800px");
  assert.strictEqual(p.props.height, "500px");
});

test("a patch with nothing kept leaves the server's style alone", () => {
  const p = page();
  const cx = p.mount();
  p.props["--pk-resizable-h"] = "70vh"; // what the server renders
  p.hook.updated.call(cx);
  assert.deepStrictEqual(p.props, { "--pk-resizable-h": "70vh" });

  // And letting go of a kept size removes only the hook's own properties.
  p.drag("s", [0, 400], [0, 440]);
  assert.strictEqual(p.props.height, "480px");
  p.dbl("s");
  assert.deepStrictEqual(p.props, { "--pk-resizable-h": "70vh" });
});

test("works when localStorage throws, and without a size key", () => {
  const p = page();
  p.window.localStorage.getItem = () => { throw new Error("denied"); };
  p.window.localStorage.setItem = () => { throw new Error("denied"); };
  p.mount();
  p.drag("e", [900, 300], [950, 300]);
  assert.strictEqual(p.props.width, "700px");

  const none = page({ attrs: { "data-size-key": "" } });
  none.mount();
  none.drag("e", [900, 300], [950, 300]);
  assert.deepStrictEqual(none.writes, []);
});

test("destroyed() takes away the window listener and the selection lock", () => {
  const p = page();
  const cx = p.mount();
  p.down("e", 900, 300);
  assert.ok(p.winListeners.resize);
  p.hook.destroyed.call(cx);
  assert.strictEqual(p.winListeners.resize, undefined);
  assert.strictEqual(p.root.userSelect, "");
});
