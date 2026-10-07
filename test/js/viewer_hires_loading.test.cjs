// ViewerHiresLoading: "Loading full quality…" while the media viewer's
// sharper picture is still arriving — reported from the field as "on slow
// internet it stays on the really low res image for a really long time" with
// nothing saying anything was still coming.
//
// Drives the real hook against a fake pane and canvas <img>: a src that has
// not loaded yet shows the pill (after a short delay, so a quick load never
// flashes it), the load or an error hides it, and a canvas remount — a new
// <img> — is followed.
//
//   node --test test/js/viewer_hires_loading.test.cjs

const fs = require("fs");
const path = require("path");
const assert = require("node:assert");
const { test } = require("node:test");

const src = fs.readFileSync(
  path.join(__dirname, "..", "..", "priv", "static", "assets", "phoenix_kit.js"), "utf8");

const start = src.indexOf("  var HIRES_SHOW_DELAY_MS");
const end = src.indexOf("// UploadResume — keep picked files until the server has them");
assert.ok(start !== -1 && end > start, "could not find the ViewerHiresLoading section");

function load() {
  const window = { PhoenixKitHooks: {} };
  let observerCb = null;
  function MutationObserver(cb) { observerCb = cb; }
  MutationObserver.prototype.observe = function() {};
  MutationObserver.prototype.disconnect = function() {};
  new Function("window", "MutationObserver", src.slice(start, end))(window, MutationObserver);
  return { hook: window.PhoenixKitHooks.ViewerHiresLoading, mutate: () => observerCb() };
}

function fakeImg(srcAttr, complete) {
  const listeners = {};
  return {
    complete,
    getAttribute: (k) => (k === "src" ? srcAttr : null),
    addEventListener: (n, fn) => { (listeners[n] = listeners[n] || []).push(fn); },
    removeEventListener: (n, fn) => { listeners[n] = (listeners[n] || []).filter((f) => f !== fn); },
    fire(n) { (listeners[n] || []).slice().forEach((fn) => fn()); },
    listenerCount: (n) => (listeners[n] || []).length
  };
}

function mount(img) {
  const { hook, mutate } = load();
  const pane = { current: img, querySelector: () => pane.current };
  const el = { parentElement: pane, dataset: { state: "idle" }, attrs: {},
    setAttribute(k, v) { this.attrs[k] = v; } };
  const h = Object.assign(Object.create(hook), { el });
  h.mounted();
  return { h, el, pane, mutate };
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

test("a picture that is already sharp shows nothing", async () => {
  const { el, h } = mount(fakeImg("/f/small.jpg", true));
  await wait(400);
  assert.strictEqual(el.dataset.state, "idle");
  h.destroyed();
});

test("a sharper picture on its way shows the pill, and its load hides it", async () => {
  const img = fakeImg("/f/large.jpg", false);
  const { el, h } = mount(img);

  assert.strictEqual(el.dataset.state, "idle", "not straight away — a quick load must not flash");
  await wait(400);
  assert.strictEqual(el.dataset.state, "loading");
  assert.strictEqual(el.attrs["aria-hidden"], "false", "announced while it shows");

  img.complete = true;
  img.fire("load");
  assert.strictEqual(el.dataset.state, "idle", "gone the moment the sharp picture lands");
  assert.strictEqual(el.attrs["aria-hidden"], "true");
  h.destroyed();
});

test("a load that finishes inside the delay never shows the pill", async () => {
  const img = fakeImg("/f/medium.jpg", false);
  const { el, h } = mount(img);
  await wait(50);
  img.complete = true;
  img.fire("load");
  await wait(400);
  assert.strictEqual(el.dataset.state, "idle");
  h.destroyed();
});

test("an error hides it too — the pill never spins forever", async () => {
  const img = fakeImg("/f/large.jpg", false);
  const { el, h } = mount(img);
  await wait(400);
  img.complete = true; // a failed <img> reports complete
  img.fire("error");
  assert.strictEqual(el.dataset.state, "idle");
  h.destroyed();
});

test("Tessera's swap — the same <img>, a new src — is followed", async () => {
  const img = fakeImg("/f/small.jpg", true);
  const { el, h, mutate } = mount(img);
  img.complete = false; // the src just changed to a bigger rung
  mutate();
  await wait(400);
  assert.strictEqual(el.dataset.state, "loading");
  h.destroyed();
});

test("a canvas remount brings a new <img>, which is watched instead of the old one", async () => {
  const old = fakeImg("/f/small.jpg", true);
  const { el, h, pane, mutate } = mount(old);
  const fresh = fakeImg("/f/burned.jpg", false);
  pane.current = fresh;
  mutate();

  assert.strictEqual(old.listenerCount("load"), 0, "the old image is let go");
  await wait(400);
  assert.strictEqual(el.dataset.state, "loading");
  fresh.complete = true;
  fresh.fire("load");
  assert.strictEqual(el.dataset.state, "idle");
  h.destroyed();
  assert.strictEqual(fresh.listenerCount("load"), 0, "and destroyed() lets go of the current one");
});
