"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const assets = path.join(__dirname, "../../priv/static/assets");
const publicSource = fs.readFileSync(path.join(assets, "phoenix_kit.js"), "utf8");
const source = fs.readFileSync(path.join(assets, "phoenix_kit_admin.js"), "utf8");
const lazy = publicSource.slice(publicSource.indexOf("  function lazyHook("), publicSource.indexOf("  var pkLoaders = {}"));
const gallery = source.slice(source.indexOf("  var GALLERY_SETTLE_MS"), source.indexOf("  // ViewerHiresLoading —"));

// Drive the actual hook with a delayed library and a controllable clock.
// Fresco owns the animation; these tests cover PhoenixKit's server hand-off.
function page({ delayed = false } = {}) {
  let ready;
  const load = delayed ? new Promise((resolve) => { ready = resolve; }) : Promise.resolve();
  const timers = new Map();
  const frames = [];
  const pushed = [];
  let serial = 0;
  const attrs = new Map();
  const root = {
    getAttribute: (key) => attrs.get(key),
    setAttribute: (key, value) => attrs.set(key, value),
    removeAttribute: (key) => attrs.delete(key)
  };
  const modal = { querySelector: () => null, contains: () => false };
  const el = { id: "gallery", dataset: { current: "first", gallery: '{"items":[{"key":"first"}],"index":0}' }, parentElement: modal };
  let options;
  const engine = {
    key: "first", shown: true, busy: false, hidden: 0, released: 0, destroyed: 0, loaded: [],
    setItems(items, index) { this.loaded.push({ items, index }); },
    currentKey() { return this.key; },
    isShown() { return this.shown; },
    isBusy() { return this.busy; },
    hide() { this.shown = false; this.hidden++; options.onHide(); },
    release() { this.released++; return false; },
    destroy() { this.destroyed++; }
  };
  const window = {
    PhoenixKitAdminHooks: {}, devicePixelRatio: 1,
    addEventListener() {}, removeEventListener() {},
    Fresco: { gallery(opts) { options = opts; return engine; }, viewerFor: () => null }
  };
  const document = {
    documentElement: root,
    getElementById: () => ({}),
    addEventListener() {}, removeEventListener() {}
  };
  const setTimer = (repeat) => (fn) => { const id = ++serial; timers.set(id, { fn, repeat }); return id; };
  const clearTimer = (id) => timers.delete(id);
  new Function("window", "document", "pkLoaders", "setTimeout", "clearTimeout", "setInterval", "clearInterval", "requestAnimationFrame", lazy + gallery)(
    window, document, { fresco: () => load }, setTimer(false), clearTimer, setTimer(true), clearTimer, (fn) => frames.push(fn));
  const hook = Object.assign(Object.create(window.PhoenixKitAdminHooks.ViewerGallery), {
    el, pushEventTo: (_el, event, payload) => pushed.push({ event, payload })
  });
  return {
    hook, el, modal, engine, timers, frames, pushed,
    ready: () => ready(),
    change(item) { engine.key = item.key; options.onChange(0, item); },
    tick() {
      [...timers.entries()].forEach(([id, { fn, repeat }]) => {
        if (!timers.has(id)) return;
        if (!repeat) timers.delete(id);
        fn();
      });
    }
  };
}

test("a cold mount waits for Fresco, then reads the latest LiveView attributes", async () => {
  const p = page({ delayed: true });
  p.hook.mounted();
  assert.equal(p.modal._pkGallery, undefined);
  p.el.dataset.gallery = '{"items":[{"key":"second"}],"index":0}';
  p.ready();
  await Promise.resolve();
  assert.equal(p.modal._pkGallery, p.engine);
  assert.deepEqual(p.engine.loaded, [{ items: [{ key: "second" }], index: 0 }]);
  p.hook.destroyed();
  assert.equal(p.modal._pkGallery, undefined);
  assert.equal(p.engine.destroyed, 1);
});

test("closing while Fresco loads never mounts a gallery late", async () => {
  const p = page({ delayed: true });
  p.hook.mounted();
  p.hook.destroyed();
  p.ready();
  await Promise.resolve();
  assert.equal(p.modal._pkGallery, undefined);
  assert.deepEqual(p.engine.loaded, []);
});

test("a settled slide names its file, but never during another gesture", async () => {
  const p = page();
  p.hook.mounted();
  await Promise.resolve();
  p.change({ key: "second", kind: "image" });
  p.engine.busy = true;
  p.tick();
  assert.deepEqual(p.pushed, []);
  p.engine.busy = false;
  p.tick();
  assert.deepEqual(p.pushed, [{ event: "gallery_go", payload: { uuid: "second" } }]);
  p.hook.destroyed();
  assert.equal(p.timers.size, 0);
});

for (const kind of ["video", "pdf", "file"]) {
  test(`a ${kind} hands over as soon as LiveView opens it`, async () => {
    const p = page();
    p.hook.mounted();
    await Promise.resolve();
    p.change({ key: "second", kind });
    p.tick();
    assert.equal(p.engine.hidden, 0, "wait for the server");
    p.el.dataset.current = "second";
    p.tick();
    assert.equal(p.engine.hidden, 1, "do not wait eight seconds for a nonexistent canvas");
    p.hook.destroyed();
  });
}

for (const stale of ["closed", "another slide"]) {
  test(`an image paint callback does nothing after ${stale}`, async () => {
    const p = page();
    p.hook.mounted();
    await Promise.resolve();
    const img = {
      complete: true, naturalWidth: 1000,
      getBoundingClientRect: () => ({ left: 0, top: 0, width: 100, height: 100 })
    };
    const canvas = { id: "canvas-second", querySelector: () => img, querySelectorAll: () => [img] };
    p.modal.querySelector = () => canvas;
    p.change({ key: "second", kind: "image", width: 1000 });
    p.tick();
    assert.equal(p.frames.length, 1);
    if (stale === "closed") p.hook.destroyed();
    else p.engine.key = "third";
    p.frames.shift()();
    assert.equal(p.engine.released, 0);
    if (stale !== "closed") p.hook.destroyed();
    assert.equal(p.timers.size, 0, "no stale watcher is restarted");
  });
}
