// The shared library loader and the admin notice (Part A of
// dev_docs/plans/2026-10-07-self-hosted-viewer-libraries.md).
//
// Reported from the field: a host with `script-src 'self'` silently lost the
// photo viewer's zoom, its sharper-version swap, annotations, the editor,
// sortable lists and the waveform — the only symptom a console.error. These
// tests drive the real loader and notice code against a fake document.
//
//   node --test test/js/library_loader.test.cjs

const fs = require("fs");
const path = require("path");
const assert = require("node:assert");
const { test } = require("node:test");

const src = fs.readFileSync(
  path.join(__dirname, "..", "..", "priv", "static", "assets", "phoenix_kit.js"), "utf8");
const start = src.indexOf("  var LIBRARY_MAX_ATTEMPTS = 2;");
const end = src.indexOf("  // ============================================================================\n  // FRESCO DAISYUI THEME INTEGRATION");
assert.ok(start !== -1 && end > start, "could not find the loader section");
const section = src.slice(start, end);

// A fresh fake page per test: scripts appended to <head> are recorded and
// can be made to load or fail; window events and CSP listeners are captured.
function page() {
  const scripts = [];
  const docListeners = {};
  const winListeners = {};
  const events = [];
  const storage = {};
  const window = {
    location: { href: "https://app.test/admin/media", origin: "https://app.test" },
    PhoenixKitHooks: {},
    addEventListener: (n, fn) => ((winListeners[n] = winListeners[n] || []).push(fn)),
    removeEventListener: (n, fn) => (winListeners[n] = (winListeners[n] || []).filter((f) => f !== fn)),
    dispatchEvent: (e) => { events.push(e); (winListeners[e.type] || []).forEach((fn) => fn(e)); }
  };
  const document = {
    createElement: () => ({
      removed: false, remove() { this.removed = true; },
      style: {}, textContent: "", children: [], appendChild(c) { this.children.push(c); }
    }),
    head: { appendChild: (s) => scripts.push(s) },
    addEventListener: (n, fn) => ((docListeners[n] = docListeners[n] || []).push(fn))
  };
  function CustomEvent(type, init) { this.type = type; this.detail = init && init.detail; }
  const sessionStorage = {
    getItem: (k) => (k in storage ? storage[k] : null),
    setItem: (k, v) => { storage[k] = String(v); }
  };
  const errors = [];
  const console = { error: (m) => errors.push(m) };
  new Function("window", "document", "CustomEvent", "sessionStorage", "console", "URL", section)(
    window, document, CustomEvent, sessionStorage, console, URL);
  const violate = (blockedURI, extra) =>
    (docListeners.securitypolicyviolation || []).forEach((fn) =>
      fn(Object.assign({ blockedURI, effectiveDirective: "script-src-elem", disposition: "enforce" }, extra)));
  return { window, scripts, events, errors, violate, storage, lib: window.PhoenixKitLibraries };
}

const URL_F = "https://cdn.jsdelivr.net/gh/alexdont/fresco@v0.13.1/priv/static/fresco.js";

test("a pre-imported library wins: nothing is fetched", async () => {
  const { lib, scripts } = page();
  await lib.load("Fresco", URL_F, { check: () => true });
  assert.strictEqual(scripts.length, 0);
});

test("simultaneous mounts share one attempt, and every waiter settles", async () => {
  const { lib, scripts } = page();
  let loaded = false;
  const check = () => loaded;
  const a = lib.load("Fresco", URL_F, { check });
  const b = lib.load("Fresco", URL_F, { check });
  assert.strictEqual(scripts.length, 1, "one script for both");
  loaded = true;
  scripts[0].onload();
  await Promise.all([a, b]);
});

test("a file that arrives but defines nothing is a failure, not a success", async () => {
  const { lib, scripts, window, events } = page();
  const p = lib.load("Fresco", URL_F, { check: () => false });
  scripts[0].onload();
  await assert.rejects(p);
  assert.strictEqual(window.__pkLibFailures.Fresco.reason, "load");
  assert.strictEqual(events[0].type, "pk:library-failed");
  assert.deepStrictEqual(events[0].detail, { name: "Fresco", url: URL_F, reason: "load", directive: null });
});

test("a failed script is retried a bounded number of times; a success clears the failure", async () => {
  const { lib, scripts, window } = page();
  let ok = false;
  const check = () => ok;

  const p1 = lib.load("Leaf", "/leaf.js", { check });
  scripts[0].onerror();
  await assert.rejects(p1);
  assert.ok(scripts[0].removed, "the dead <script> is removed so a retry starts clean");
  assert.ok(window.__pkLibFailures.Leaf);

  const p2 = lib.load("Leaf", "/leaf.js", { check });
  ok = true;
  scripts[1].onload();
  await p2;
  assert.strictEqual(window.__pkLibFailures.Leaf, undefined, "a later success clears it");

  const q = page();
  const r1 = q.lib.load("Leaf", "/leaf.js", { check: () => false });
  q.scripts[0].onerror();
  await assert.rejects(r1);
  const r2 = q.lib.load("Leaf", "/leaf.js", { check: () => false });
  q.scripts[1].onerror();
  await assert.rejects(r2);
  await assert.rejects(q.lib.load("Leaf", "/leaf.js", { check: () => false }));
  assert.strictEqual(q.scripts.length, 2, "no third attempt");
});

test("an enforced CSP violation before onerror classifies the failure, with the directive", async () => {
  const { lib, scripts, window, violate } = page();
  const p = lib.load("Fresco", URL_F, { check: () => false });
  violate(URL_F);
  scripts[0].onerror();
  await assert.rejects(p);
  assert.deepStrictEqual(
    { reason: window.__pkLibFailures.Fresco.reason, directive: window.__pkLibFailures.Fresco.directive },
    { reason: "csp", directive: "script-src-elem" });
});

test("a violation arriving after onerror refines the failure, and announces again", async () => {
  const { lib, scripts, window, violate, events } = page();
  const p = lib.load("Fresco", URL_F, { check: () => false });
  scripts[0].onerror();
  await assert.rejects(p);
  assert.strictEqual(window.__pkLibFailures.Fresco.reason, "load");
  violate("https://cdn.jsdelivr.net"); // stripped to the origin
  assert.strictEqual(window.__pkLibFailures.Fresco.reason, "csp");
  assert.strictEqual(events.length, 2);
});

test("report-only and unrelated violations are never pinned on a library", async () => {
  const { lib, scripts, window, violate } = page();
  const p = lib.load("Fresco", URL_F, { check: () => false });
  violate(URL_F, { disposition: "report" });
  violate("https://evil.test/x.js");
  violate("https://cdn.jsdelivr.net/npm/other@1/x.js"); // same origin, but a full, different URL
  scripts[0].onerror();
  await assert.rejects(p);
  assert.strictEqual(window.__pkLibFailures.Fresco.reason, "load");
});

test("a failure is announced once per library, not once per waiter", async () => {
  const { lib, scripts, events } = page();
  const ps = [1, 2, 3].map(() => lib.load("Etcher", "/etcher.js", { check: () => false }));
  scripts[0].onerror();
  await Promise.allSettled(ps);
  assert.strictEqual(events.length, 1);
});

test("a module import that fails is recorded and terminal for the page", async () => {
  const { lib, window } = page();
  await assert.rejects(lib.load("wavesurfer", "data:text/javascript,throw new Error('x')", { module: true }));
  assert.strictEqual(window.__pkLibFailures.wavesurfer.reason, "load");
  await assert.rejects(lib.load("wavesurfer", "data:text/javascript,export default 1", { module: true }),
    "not re-run after a failed evaluation");
});

test("a module import that works resolves with the module", async () => {
  const { lib } = page();
  const mod = await lib.load("wavesurfer", "data:text/javascript,export default 42", { module: true });
  assert.strictEqual(mod.default, 42);
});

test("a hook destroyed while its library loads never mounts late", async () => {
  const { lib } = page();
  let release;
  const gate = new Promise((r) => (release = r));
  let mounted = 0;
  const hook = lib.lazyHook(() => gate, () => ({ mounted() { mounted++; }, updated() {} }));
  const a = Object.create(hook); a.mounted();
  const b = Object.create(hook); b.mounted();
  a.destroyed();
  release();
  await gate; await new Promise((r) => setTimeout(r, 0));
  assert.strictEqual(mounted, 1, "only the live one");
  assert.strictEqual(typeof b.updated, "function", "and it became the real hook");
});

test("Tessera and Etcher wait for Fresco", () => {
  for (const name of ["Tessera", "Etcher"]) {
    const re = new RegExp(`return pkLoaders\\.fresco\\(\\)\\.then\\(function\\(\\) \\{\\s*return loadLibrary\\("${name}"`);
    assert.match(src, re, `${name} is chained through Fresco's successful load`);
  }
  assert.doesNotMatch(src, /Failed to load [A-Za-z ]+ from CDN"\);/,
    "no hand-copied loader is left behind");
});

// ── the notice ─────────────────────────────────────────────────────────────

function noticeEl() {
  const nodes = { "[data-notice-title]": { textContent: "" }, "[data-notice-audience]": { textContent: "" },
    "[data-notice-list]": { children: [], set textContent(v) { this.children = []; },
      appendChild(c) { this.children.push(c); } },
    "[data-notice-dismiss]": { listeners: {}, addEventListener(n, fn) { this.listeners[n] = fn; } } };
  return {
    hidden: true,
    dataset: { title: "Some features could not load", audience: "Only administrators see this message.",
      cspOther: "Blocked (%{directive}), which does not allow %{origin}.", cspSelf: "Blocked here (%{directive}).",
      load: "Could not be loaded or run." },
    querySelector: (sel) => nodes[sel],
    nodes
  };
}

function withDom(_p, fn) { return fn(); }

test("the notice stays hidden with nothing failed, and shows recorded failures by name and cause", async () => {
  const p = page();
  const el = noticeEl();
  withDom(p, () => {
    const h = Object.assign(Object.create(p.window.PhoenixKitHooks.LibraryLoadNotice), { el });
    h.mounted();
    assert.strictEqual(el.hidden, true);

    p.window.__pkLibFailures.Fresco = { url: URL_F, reason: "csp", directive: "script-src-elem" };
    p.window.dispatchEvent({ type: "pk:library-failed" });
    assert.strictEqual(el.hidden, false);
    const [li] = el.nodes["[data-notice-list]"].children;
    assert.strictEqual(li.children[0].textContent, "Fresco: ");
    assert.strictEqual(li.children[1].textContent,
      "Blocked (script-src-elem), which does not allow https://cdn.jsdelivr.net. ");
    assert.strictEqual(li.children[2].textContent, URL_F);
    h.destroyed();
  });
});

test("a same-origin CSP block gets the asset-serving advice, a plain failure the uncertain one", () => {
  const p = page();
  const el = noticeEl();
  withDom(p, () => {
    p.window.__pkLibFailures.Leaf = { url: "https://app.test/assets/vendor/lib/leaf.js", reason: "csp", directive: "script-src" };
    p.window.__pkLibFailures.Tessera = { url: "/t.js", reason: "load", directive: null };
    const h = Object.assign(Object.create(p.window.PhoenixKitHooks.LibraryLoadNotice), { el });
    h.mounted();
    const texts = el.nodes["[data-notice-list]"].children.map((li) => li.children[1].textContent);
    assert.deepStrictEqual(texts, ["Blocked here (script-src). ", "Could not be loaded or run. "]);
  });
});

test("dismissal lasts the session for what was shown — a later, different failure still shows", () => {
  const p = page();
  const el = noticeEl();
  withDom(p, () => {
    p.window.__pkLibFailures.Fresco = { url: URL_F, reason: "load" };
    const h = Object.assign(Object.create(p.window.PhoenixKitHooks.LibraryLoadNotice), { el });
    h.mounted();
    el.nodes["[data-notice-dismiss]"].listeners.click();
    assert.strictEqual(el.hidden, true);

    p.window.dispatchEvent({ type: "pk:library-failed" });
    assert.strictEqual(el.hidden, true, "the dismissed Fresco failure stays dismissed");

    p.window.__pkLibFailures.Leaf = { url: "/leaf.js", reason: "load" };
    p.window.dispatchEvent({ type: "pk:library-failed" });
    assert.strictEqual(el.hidden, false);
    assert.deepStrictEqual(el.nodes["[data-notice-list]"].children.map((li) => li.children[0].textContent),
      ["Leaf: "]);
  });
});
