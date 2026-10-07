// Pins the viewer's neighbour warming.
//
// An arrow press remounts the viewer on the next file, and that file's
// small + large variants used to start downloading only then — the
// download WAS the wait between pressing → and seeing the picture. The
// modal carries the neighbours' variant URLs, and ViewerKeydown warms them,
// deduped page-wide across remounts.
//
// The warm is a favour to the NEXT press, so it has manners: it waits until
// the picture on screen has settled, runs at low fetch priority, and stays
// away on data-saver / 2G / 3G. It warms the tiny `open` variant of BOTH
// neighbours (a step paints it at once) but the `large` rung only of the side
// being stepped towards. It never fetches an original — that is a decision
// about the screen, the line and the picture's shape, made by a module
// (phoenix_kit_photos) from the `pk:viewer-neighbours` event core announces
// once settled.
//
//   node --test test/js/neighbor_prefetch.test.cjs

const fs = require("fs");
const path = require("path");
const assert = require("node:assert");
const { test } = require("node:test");

const SOURCE = path.join(__dirname, "..", "..", "priv", "static", "assets", "phoenix_kit.js");
const src = fs.readFileSync(SOURCE, "utf8");

const SETTLED_MS = 800; // SETTLE_QUIET_MS (600) plus slack
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

function loadKeydown(connection) {
  const start = src.indexOf("  window.PhoenixKitHooks.ViewerKeydown = {");
  assert.notStrictEqual(start, -1, "could not find ViewerKeydown");
  const end = src.indexOf("\n  };", start) + "\n  };".length;
  const fetched = [];
  const priorities = [];
  function FakeImage() {}
  Object.defineProperty(FakeImage.prototype, "src", {
    set(v) { fetched.push(v); priorities.push(this.fetchPriority); }, get() { return null; },
  });
  const dispatched = [];
  const win = {
    addEventListener: () => {}, removeEventListener: () => {},
    dispatchEvent: (e) => dispatched.push(e),
  };
  const listeners = {};
  const doc = {
    addEventListener: (n, fn) => { (listeners[n] = listeners[n] || []).push(fn); },
    removeEventListener: (n, fn) => { listeners[n] = (listeners[n] || []).filter((f) => f !== fn); },
  };
  const nav = { connection };
  const fn = new Function("window", "document", "Image", "CustomEvent", "navigator",
    "window.PhoenixKitHooks = window.PhoenixKitHooks || {};" +
    src.slice(start, end) + "; return window.PhoenixKitHooks.ViewerKeydown;");
  const hook = fn(win, doc, FakeImage, function C(n, o) { this.name = n; this.detail = o && o.detail; }, nav);
  return { hook, fetched, priorities, win, dispatched, doc, listeners };
}

// A modal whose canvas picture has loaded (the common case) unless told otherwise.
function mountEl(dataset, colW, img) {
  const canvas = img === undefined ? { complete: true, getAttribute: () => "/f/cur/large" } : img;
  return {
    dataset,
    querySelector: (sel) => {
      if (sel.includes("pk-annotation-actions")) return { clientWidth: colW };
      if (sel.includes("data-fresco-canvas-img")) return canvas;
      return null;
    },
  };
}

const N = (over = {}) => JSON.stringify({
  prev: { open: "/f/p/small/aa", large: "/f/p/large/ab", original: "/f/p/original/ac", aspect: "4 / 3" },
  next: { open: "/f/n/small/ba", large: "/f/n/large/bb", original: "/f/n/original/bc", aspect: "3 / 4" },
  ...over,
});

test("the picture settled, both neighbours' small and ONLY the next one's large are warmed", async () => {
  const { hook, fetched } = loadKeydown();
  hook.mounted.call({ el: mountEl({ neighbors: N() }, 1200), pushEventTo: () => {} });
  assert.deepStrictEqual(fetched, [], "not before the picture on screen has had its say");
  await wait(SETTLED_MS);
  assert.deepStrictEqual(fetched, ["/f/n/small/ba", "/f/p/small/aa", "/f/n/large/bb"],
    "small both ways (tens of KB, paints a step at once); large only ahead");
});

test("after a step back, the previous side's large is the one warmed", async () => {
  const { hook, fetched } = loadKeydown();
  const ctx = { el: mountEl({ neighbors: N() }, 1200), pushEventTo: () => {}, _direction: "prev" };
  hook.mounted.call(ctx);
  ctx._direction = "prev"; // mounted() resets it; a step sets it before the patch
  hook.updated.call(ctx);
  await wait(SETTLED_MS);
  assert.ok(fetched.includes("/f/p/large/ab"), "heading back: the previous large");
  assert.ok(!fetched.includes("/f/n/large/bb"), "…not the one behind");
});

test("the warm runs at low fetch priority", async () => {
  const { hook, priorities } = loadKeydown();
  hook.mounted.call({ el: mountEl({ neighbors: N() }, 1200), pushEventTo: () => {} });
  await wait(SETTLED_MS);
  assert.ok(priorities.length > 0 && priorities.every((p) => p === "low"),
    "a warm is a favour to the next press, never a competitor of this picture");
});

test("a picture still arriving holds the warm back until its load", async () => {
  const img = { complete: false, getAttribute: () => "/f/cur/large" };
  const { hook, fetched, listeners } = loadKeydown();
  hook.mounted.call({ el: mountEl({ neighbors: N() }, 1200, img), pushEventTo: () => {} });
  await wait(SETTLED_MS);
  assert.deepStrictEqual(fetched, [], "the sharper version is still on its way — wait");

  img.complete = true;
  (listeners.load || []).slice().forEach((fn) => fn({ target: img }));
  await wait(SETTLED_MS);
  assert.ok(fetched.length > 0, "…and warm once it has landed");
});

test("core never fetches an original — it announces the neighbours instead", async () => {
  const { hook, fetched, dispatched } = loadKeydown();
  hook.mounted.call({ el: mountEl({ neighbors: N() }, 2400), pushEventTo: () => {} });
  await wait(SETTLED_MS);
  assert.ok(!fetched.some((u) => u.includes("/original/")),
    "even on a wide column: whether an original is worth it is a module's call");

  const ev = dispatched.find((e) => e.name === "pk:viewer-neighbours");
  assert.ok(ev, "settled, core announces the neighbours");
  assert.deepStrictEqual(ev.detail.prev, { original: "/f/p/original/ac", aspect: "4 / 3" });
  assert.deepStrictEqual(ev.detail.next, { original: "/f/n/original/bc", aspect: "3 / 4" });
});

test("the announcement carries the viewer's box, the pixel ratio and the stepping direction", async () => {
  const { hook, win, dispatched } = loadKeydown();
  win.devicePixelRatio = 2;
  win.innerHeight = 900;
  const ctx = {
    el: mountEl({ neighbors: N() }, 1600),
    pushEventTo: () => {},
  };
  hook.mounted.call(ctx);
  ctx._direction = "prev"; // what an ArrowLeft leaves behind
  hook.updated.call(ctx);
  await wait(SETTLED_MS);

  const ev = dispatched.filter((e) => e.name === "pk:viewer-neighbours").pop();
  assert.ok(ev, "announced");
  assert.strictEqual(ev.detail.direction, "prev");
  assert.strictEqual(ev.detail.box.width, 1600, "CSS px, as the column measures");
  assert.strictEqual(ev.detail.box.height, 900, "the window's height when the column has none");
  assert.strictEqual(ev.detail.box.dpr, 2,
    "the module multiplies — Tessera picks its raster against physical pixels");
});

test("a malformed or missing neighbours attribute is harmless", async () => {
  for (const raw of [undefined, "", "not json", "null", "[]"]) {
    const { hook, fetched } = loadKeydown();
    assert.doesNotThrow(() => hook.mounted.call({
      el: mountEl({ neighbors: raw }, 1200), pushEventTo: () => {} }), String(raw));
    await wait(SETTLED_MS);
    assert.deepStrictEqual(fetched, [], String(raw));
  }
});

test("data-saver and slow lines get no warm and no announcement", async () => {
  for (const connection of [{ saveData: true }, { effectiveType: "3g" }, { effectiveType: "2g" }]) {
    const { hook, fetched, dispatched } = loadKeydown(connection);
    hook.mounted.call({ el: mountEl({ neighbors: N() }, 1200), pushEventTo: () => {} });
    await wait(SETTLED_MS);
    assert.deepStrictEqual(fetched, [], JSON.stringify(connection));
    assert.ok(!dispatched.some((e) => e.name === "pk:viewer-neighbours"), JSON.stringify(connection));
  }
  const fine = loadKeydown({ effectiveType: "4g" });
  fine.hook.mounted.call({ el: mountEl({ neighbors: N() }, 1200), pushEventTo: () => {} });
  await wait(SETTLED_MS);
  assert.ok(fine.fetched.length > 0, "4g is fine");
});

test("each URL warms once per page, across remounts", async () => {
  const { hook, fetched } = loadKeydown();
  const el = mountEl({ neighbors: JSON.stringify({ next: { open: "/f/x/small/aa" } }) }, 1200);
  hook.mounted.call({ el, pushEventTo: () => {} });
  await wait(SETTLED_MS);
  // the next file's mount lists the same URL as ITS neighbour
  hook.mounted.call({ el, pushEventTo: () => {} });
  await wait(SETTLED_MS);
  assert.deepStrictEqual(fetched, ["/f/x/small/aa"],
    "the shared page-wide map survives the remount an arrow causes");
});

test("no neighbours, no fetches, no crash", async () => {
  const { hook, fetched } = loadKeydown();
  assert.doesNotThrow(() => hook.mounted.call({
    el: { dataset: {}, querySelector: () => null }, pushEventTo: () => {} }));
  await wait(50);
  assert.deepStrictEqual(fetched, []);
});

test("closing the viewer cancels a warm that has not run yet", async () => {
  const { hook, fetched } = loadKeydown();
  const ctx = { el: mountEl({ neighbors: N() }, 1200), pushEventTo: () => {} };
  hook.mounted.call(ctx);
  hook.destroyed.call(ctx);
  await wait(SETTLED_MS);
  assert.deepStrictEqual(fetched, [], "nobody is looking any more — nothing to warm for");
});

test("the modal advertises its neighbours", () => {
  const heex = fs.readFileSync(
    path.join(__dirname, "..", "..", "lib", "phoenix_kit_web", "components",
              "media_browser.html.heex"), "utf8");
  assert.ok(heex.includes("data-neighbors={neighbors_json}"),
    "ViewerKeydown reads the neighbours off its own element, as one structured attribute");
  assert.ok(/Enum\.at\(siblings, viewer_idx - 1\)/.test(heex) &&
            /Enum\.at\(siblings, viewer_idx \+ 1\)/.test(heex),
    "…built from the same siblings list the arrows step through");
  assert.ok(!heex.includes("data-neighbor-prefetch") && !heex.includes("data-neighbor-original"),
    "the old per-kind attributes are gone — one attribute, per side");
  for (const a of ["data-step-prev-src=", "data-step-next-src=",
                   "data-step-prev-rot=", "data-step-next-rot="]) {
    assert.ok(heex.includes(a),
      `the modal advertises ${a} for the step stand-in`);
  }
  assert.ok(heex.includes("viewer_open_url("),
    "the step stand-in is the variant the viewer opens on, not always small");

  const ex = fs.readFileSync(
    path.join(__dirname, "..", "..", "lib", "phoenix_kit_web", "components",
              "media_browser.ex"), "utf8");
  assert.ok(/defp neighbor_warm_data\(%\{file_type: "image"\}/.test(ex) &&
            /defp neighbor_warm_data\(_\), do: nil/.test(ex),
    "videos and pdfs are not image-warmable and are skipped");
  for (const key of ['"open"', '"large"', '"original"', '"aspect"']) {
    assert.ok(ex.includes(key), `each side advertises ${key}`);
  }
  assert.ok(/max\(Map\.get\(n, :width\) \|\| 0, Map\.get\(n, :height\) \|\| 0\) > 4096 and/.test(ex),
    "an over-4K file WITH tiles never raster-loads its original — excluded");
});

test("a step re-announces the viewer and re-warms — the modal is patched, not remounted", async () => {
  // A step keeps this hook's element (stable id) and only swaps the canvas
  // child, so mounted() fires once per OPEN. Before updated() existed, a
  // step's stand-in waited on a pk:viewer-open that never came (the 8s
  // fallback WAS the "blurry for much much longer"), and every neighbour
  // after the first step went unwarmed.
  const { hook, fetched, dispatched } = loadKeydown();
  const ctx = {
    el: mountEl({ neighbors: JSON.stringify({ next: { open: "/f/p/small/aa", large: "/f/p/large/ab" } }) }, 1200),
    pushEventTo: () => {},
  };
  hook.mounted.call(ctx);
  await wait(SETTLED_MS);
  fetched.length = 0;
  dispatched.length = 0;

  // The patch rewrote the dataset with the NEW neighbours.
  ctx.el.dataset.neighbors = JSON.stringify({ next: { open: "/f/q/small/qq", large: "/f/q/large/ql" } });
  hook.updated.call(ctx);

  const open = dispatched.find((e) => e.name === "pk:viewer-open");
  assert.ok(open, "the stand-in's hand-off rides pk:viewer-open — a step must re-fire it");
  assert.strictEqual(open.detail.el, ctx.el,
    "…with the modal element, so the hold can find the new image");
  await wait(SETTLED_MS);
  assert.deepStrictEqual(fetched, ["/f/q/small/qq", "/f/q/large/ql"],
    "and the NEXT press's neighbours warm now, not never");
});
