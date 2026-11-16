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
const start = src.indexOf("  var PK_SCRIPT_SRC = ");
const end = src.indexOf("  // ============================================================================\n  // FRESCO DAISYUI THEME INTEGRATION");
assert.ok(start !== -1 && end > start, "could not find the loader section");
const section = src.slice(start, end);

// A fresh fake page per test: scripts appended to <head> are recorded and
// can be made to load or fail; window events and CSP listeners are captured.
function page(opts) {
  opts = opts || {};
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
    currentScript: opts.scriptSrc ? { src: opts.scriptSrc } : null,
    scripts: opts.docScripts,
    addEventListener: (n, fn) => ((docListeners[n] = docListeners[n] || []).push(fn))
  };
  if (opts.fetch) window.fetch = opts.fetch;
  function CustomEvent(type, init) { this.type = type; this.detail = init && init.detail; }
  const sessionStorage = {
    getItem: (k) => (k in storage ? storage[k] : null),
    setItem: (k, v) => { storage[k] = String(v); }
  };
  const errors = [];
  const console = { error: (m) => errors.push(m) };
  if (opts.facts) window.PHOENIX_KIT_LIBS = opts.facts;
  if (opts.libBase) window.PHOENIX_KIT_LIB_BASE = opts.libBase;
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

test("CSP keywords (inline, eval, empty) never pin a same-origin library failure on a csp", async () => {
  const { lib, scripts, window, violate } = page();
  const p = lib.load("Fresco", "https://app.test/assets/lib/fresco.js", { check: () => false });
  violate("inline");
  violate("eval");
  violate("");
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
    const re = new RegExp(`return pkLoaders\\.fresco\\(\\)\\.then\\(function\\(\\) \\{[\\s\\S]{0,120}?loadVendored\\("${name}"`);
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

// ── Part B1: the host's own copies ──────────────────────────────────────────

const FACTS = {
  fresco: { file: "fresco-0.13.1-3f9a1c00.js", cdn: null },
  sortable: { file: "sortable-1.15.0-8a9889ae.js", cdn: null }
};

test("library files resolve next to the bundle, by the names the install facts give", () => {
  const p = page({ scriptSrc: "https://app.test/assets/vendor/phoenix_kit-1a2b3c.js?vsn=d", facts: FACTS });
  assert.deepStrictEqual(p.lib.urls("fresco"),
    { local: "https://app.test/assets/vendor/lib/fresco-0.13.1-3f9a1c00.js?vsn=d", cdn: null },
    "dirname of the bundle's own URL (digested name and query stripped) + lib/");
});

test("an explicit base wins, for hosts that bundle core into their own app.js", () => {
  const p = page({ scriptSrc: "https://app.test/assets/app.js", facts: FACTS, libBase: "https://cdn.app.test/pk" });
  assert.strictEqual(p.lib.urls("fresco").local, "https://cdn.app.test/pk/fresco-0.13.1-3f9a1c00.js?vsn=d");
});

test("a root-relative library base resolves to an absolute URL for scripts and import()", () => {
  const p = page({ facts: FACTS, libBase: "/assets/vendor/lib" });
  assert.strictEqual(p.lib.urls("fresco").local,
    "https://app.test/assets/vendor/lib/fresco-0.13.1-3f9a1c00.js?vsn=d");
});

test("a page-relative library base resolves against the page, including for import()", () => {
  const p = page({ facts: FACTS, libBase: "../libraries/" });
  assert.strictEqual(p.lib.urls("fresco").local,
    "https://app.test/libraries/fresco-0.13.1-3f9a1c00.js?vsn=d");
});

test("the facts are read when a library is needed — they load after the bundle", () => {
  const p = page({ scriptSrc: "https://app.test/assets/vendor/phoenix_kit.js" });
  assert.strictEqual(p.lib.urls("fresco"), null);
  p.window.PHOENIX_KIT_LIBS = FACTS;
  assert.ok(p.lib.urls("fresco"));
});

test("with no facts nothing is fetched or guessed, and the failure says why", async () => {
  const p = page({ scriptSrc: "https://app.test/assets/vendor/phoenix_kit.js" });
  await assert.rejects(p.lib.loadVendored("Fresco", "fresco", { check: () => false }));
  assert.strictEqual(p.scripts.length, 0, "no request at all");
  assert.strictEqual(p.window.__pkLibFailures.Fresco.reason, "facts");
});

// ── an outdated copy of the facts ──────────────────────────────────────────
//
// The facts file has a stable address wherever assets are not digested, so a
// browser may run a cached copy from before an update while the bundle asks for
// a library that copy does not name. The build is fine; recompiling will not
// help. Before saying "no facts", the loader asks the server for its current
// copy, past the cache, once.

const FACTS_SRC = "https://app.test/assets/vendor/phoenix_kit_modules.js";
const factsFile = (libs) =>
  "/* Auto-generated by PhoenixKit — do not edit manually. */\n" +
  "window.PHOENIX_KIT_PREFIX=\"/\";\n" +
  "window.PHOENIX_KIT_LIBS=" + JSON.stringify(libs) + ";\n\n;(function(){ /* bundles */ })();\n";

function fetchStub(respond) {
  const calls = [];
  const fn = (url, init) => { calls.push({ url, init }); return respond(url); };
  fn.calls = calls;
  return fn;
}
const okText = (text) => Promise.resolve({ ok: true, text: () => Promise.resolve(text) });
const settle = () => new Promise((r) => setImmediate(r));

test("a library the page's facts lack but the server's current copy names is reported as an outdated copy", async () => {
  const fetch = fetchStub(() => okText(factsFile({ admin: { file: "admin-3.6.1-0a1b2c3d.js", cdn: null } })));
  const p = page({ facts: { fresco: FACTS.fresco }, docScripts: [{ src: "" }, { src: FACTS_SRC }], fetch });
  const err = await p.lib.loadVendored("PhoenixKit admin", "admin", { check: () => false }).catch((e) => e);
  assert.ok(err.pkNoFacts, "the caller is answered at once, as before");
  assert.strictEqual(p.window.__pkLibFailures["PhoenixKit admin"].reason, "facts",
    "reported at once, so a fetch that never answers cannot swallow the report");
  await settle();
  assert.deepStrictEqual(fetch.calls, [{ url: FACTS_SRC, init: { cache: "reload", credentials: "same-origin" } }]);
  assert.deepStrictEqual(p.events.map((e) => e.detail), [
    { name: "PhoenixKit admin", url: "lib/admin", reason: "facts", directive: null },
    { name: "PhoenixKit admin", url: FACTS_SRC, reason: "stale", directive: null }
  ]);
  assert.match(p.errors[1], /outdated copy[\s\S]*Reload the page/);
  assert.strictEqual(p.scripts.length, 0, "no library request");

  // The admin stubs ask again every few seconds: the stale report stands, with no new fetch or announcement.
  await assert.rejects(p.lib.loadVendored("PhoenixKit admin", "admin", { check: () => false }));
  await settle();
  assert.strictEqual(p.window.__pkLibFailures["PhoenixKit admin"].reason, "stale");
  assert.strictEqual(fetch.calls.length, 1);
  assert.strictEqual(p.events.length, 2);
});

test("a cached copy from before the facts named libraries is reported as an outdated copy too", async () => {
  // Facts files written before 2026-10 set PHOENIX_KIT_PREFIX and PHOENIX_KIT_CONSENT_AVAILABLE only.
  const fetch = fetchStub(() => okText(factsFile(FACTS)));
  const p = page({ docScripts: [{ src: FACTS_SRC }], fetch });
  p.window.PHOENIX_KIT_CONSENT_AVAILABLE = false;
  await assert.rejects(p.lib.loadVendored("Fresco", "fresco", { check: () => false }));
  await settle();
  assert.strictEqual(fetch.calls.length, 1);
  assert.deepStrictEqual(p.window.__pkLibFailures.Fresco, { url: FACTS_SRC, reason: "stale", directive: null });
});

test("a server copy the host minified (keys unquoted, one line) is still read", async () => {
  const minified = fs.readFileSync(
    path.join(__dirname, "..", "fixtures", "phoenix_kit_modules.esbuild.min.js"), "utf8");
  for (const [key, expected] of [["admin", "stale"], ["fresco", "stale"], ["nosuchlib", "facts"]]) {
    const fetch = fetchStub(() => okText(minified));
    const p = page({ facts: { sortable: FACTS.sortable }, docScripts: [{ src: FACTS_SRC }], fetch });
    await assert.rejects(p.lib.loadVendored("Lib", key, { check: () => false }));
    await settle();
    assert.strictEqual(p.window.__pkLibFailures.Lib.reason, expected, key);
  }
});

test("a prefix from the globals component alone is no sign the facts file ran", async () => {
  const fetch = fetchStub(() => okText(factsFile(FACTS)));
  const p = page({ docScripts: [{ src: FACTS_SRC }], fetch });
  p.window.PHOENIX_KIT_PREFIX = "/";
  await assert.rejects(p.lib.loadVendored("Fresco", "fresco", { check: () => false }));
  await settle();
  assert.strictEqual(fetch.calls.length, 0);
  assert.strictEqual(p.window.__pkLibFailures.Fresco.reason, "facts");
});

test("a digested facts file cannot be outdated: nothing is fetched", async () => {
  const digested = "https://app.test/assets/vendor/phoenix_kit_modules-0123456789abcdef0123456789abcdef.js?vsn=d";
  const fetch = fetchStub(() => okText(factsFile(FACTS)));
  const p = page({ facts: {}, docScripts: [{ src: digested }], fetch });
  await assert.rejects(p.lib.loadVendored("Fresco", "fresco", { check: () => false }));
  await settle();
  assert.strictEqual(fetch.calls.length, 0);
  assert.strictEqual(p.window.__pkLibFailures.Fresco.reason, "facts");
});

test("when the server's copy lacks the file too, or cannot be read, it stays a missing-facts failure", async () => {
  const cases = [
    () => okText(factsFile({ sortable: FACTS.sortable })),
    () => okText("/* no facts here */"),
    () => okText("window.PHOENIX_KIT_LIBS={not json};"),
    () => Promise.resolve({ ok: false, text: () => Promise.resolve("") }),
    () => Promise.reject(new TypeError("Failed to fetch"))
  ];
  for (const respond of cases) {
    const fetch = fetchStub(respond);
    const p = page({ facts: { sortable: FACTS.sortable }, docScripts: [{ src: FACTS_SRC }], fetch });
    await assert.rejects(p.lib.loadVendored("Fresco", "fresco", { check: () => false }));
    await settle();
    assert.strictEqual(fetch.calls.length, 1);
    assert.deepStrictEqual(p.window.__pkLibFailures.Fresco, { url: "lib/fresco", reason: "facts", directive: null });
    assert.strictEqual(p.events.length, 1);
  }
});

test("nothing is fetched without a facts tag, without fetch, or when the page ran no facts at all", async () => {
  const setups = [
    { facts: {}, docScripts: [{ src: "https://app.test/assets/js/app.js" }] },
    { facts: {}, docScripts: [{ src: FACTS_SRC }], noFetch: true },
    // the tag is there but its script never ran (blocked, failed): no copy to call outdated
    { docScripts: [{ src: FACTS_SRC }] }
  ];
  for (const setup of setups) {
    const fetch = fetchStub(() => okText(factsFile(FACTS)));
    const p = page(Object.assign({ fetch: setup.noFetch ? undefined : fetch }, setup));
    await assert.rejects(p.lib.loadVendored("Fresco", "fresco", { check: () => false }));
    assert.strictEqual(p.window.__pkLibFailures.Fresco.reason, "facts");
    await settle();
    assert.strictEqual(fetch.calls.length, 0);
    assert.strictEqual(p.window.__pkLibFailures.Fresco.reason, "facts");
  }
});

test("facts that name the file but leave no library base are not called outdated", async () => {
  const fetch = fetchStub(() => okText(factsFile(FACTS)));
  const p = page({ facts: FACTS, docScripts: [{ src: FACTS_SRC }], fetch }); // no script src, no base
  await assert.rejects(p.lib.loadVendored("Fresco", "fresco", { check: () => false }));
  await settle();
  assert.strictEqual(fetch.calls.length, 0);
  assert.strictEqual(p.window.__pkLibFailures.Fresco.reason, "facts");
});

test("a failure cleared while the fetch was out is not brought back", async () => {
  let answer;
  const fetch = fetchStub(() => new Promise((r) => { answer = r; }));
  const p = page({ facts: {}, docScripts: [{ src: FACTS_SRC }], fetch });
  await assert.rejects(p.lib.loadVendored("Fresco", "fresco", { check: () => false }));
  delete p.window.__pkLibFailures.Fresco; // what a later successful load does
  answer({ ok: true, text: () => Promise.resolve(factsFile(FACTS)) });
  await settle();
  assert.strictEqual(p.window.__pkLibFailures.Fresco, undefined);
  assert.strictEqual(p.events.length, 1);
});

test("several libraries missing from the facts share one re-fetch", async () => {
  const fetch = fetchStub(() => okText(factsFile(FACTS)));
  const p = page({ facts: {}, docScripts: [{ src: FACTS_SRC }], fetch });
  await Promise.all([
    assert.rejects(p.lib.loadVendored("Fresco", "fresco", { check: () => false })),
    assert.rejects(p.lib.loadVendored("SortableJS", "sortable", { check: () => false }))
  ]);
  await settle();
  assert.strictEqual(fetch.calls.length, 1);
  assert.deepStrictEqual(Object.keys(p.window.__pkLibFailures).sort(), ["Fresco", "SortableJS"]);
  assert.deepStrictEqual(Object.values(p.window.__pkLibFailures).map((f) => f.reason), ["stale", "stale"]);
});

test("the notice tells an outdated copy apart from missing facts", () => {
  const p = page();
  const el = noticeEl();
  el.dataset.facts = "No install facts.";
  el.dataset.stale = "Outdated copy; reload.";
  p.window.__pkLibFailures.Fresco = { url: "lib/fresco", reason: "facts", directive: null };
  p.window.__pkLibFailures["PhoenixKit admin"] = { url: FACTS_SRC, reason: "stale", directive: null };
  const h = Object.assign(Object.create(p.window.PhoenixKitHooks.LibraryLoadNotice), { el });
  h.mounted();
  const texts = el.nodes["[data-notice-list]"].children.map((li) => li.children[1].textContent);
  assert.deepStrictEqual(texts, ["No install facts. ", "Outdated copy; reload. "]);
});

test("a pre-imported library needs no facts", async () => {
  const p = page({});
  await p.lib.loadVendored("Fresco", "fresco", { check: () => true });
  assert.strictEqual(p.window.__pkLibFailures.Fresco, undefined);
});

test("the vendored file is the only request by default — no CDN after a local failure", async () => {
  const p = page({ scriptSrc: "https://app.test/assets/vendor/phoenix_kit.js", facts: FACTS });
  const pr = p.lib.loadVendored("Fresco", "fresco", { check: () => false });
  p.scripts[0].onerror();
  await assert.rejects(pr);
  assert.deepStrictEqual(p.scripts.map((s) => s.src), ["https://app.test/assets/vendor/lib/fresco-0.13.1-3f9a1c00.js?vsn=d"]);
});

test("an opted-in CDN is tried once after the local copy fails, and a rescue leaves no alert", async () => {
  const facts = { fresco: { file: "fresco-0.13.1-3f9a1c00.js",
    cdn: "https://cdn.jsdelivr.net/gh/alexdont/fresco@v0.13.1/priv/static/fresco.js" } };
  const p = page({ scriptSrc: "https://app.test/assets/vendor/phoenix_kit.js", facts });
  let ok = false;
  const pr = p.lib.loadVendored("Fresco", "fresco", { check: () => ok });
  p.scripts[0].onerror();
  assert.strictEqual(p.scripts[1].src, facts.fresco.cdn);
  ok = true;
  p.scripts[1].onload();
  await pr;
  assert.strictEqual(p.window.__pkLibFailures.Fresco, undefined);
  assert.strictEqual(p.events.length, 0, "nothing announced");
});

test("Etcher is pointed at the host's SortableJS, with its own CDN load off in every mode", () => {
  const block = src.slice(src.indexOf("function configureEtcherSortable() {"));
  const apply = src.slice(src.indexOf("function applyEtcherSortableSettings() {"));
  assert.match(apply, /if \(urls && window\.Etcher\.sortableUrl === undefined\) window\.Etcher\.sortableUrl = urls\.local;/,
    "the host's own copy, unless the host set its own");
  assert.match(apply, /if \(window\.Etcher\.loadSortableFromCdn === undefined\) window\.Etcher\.loadSortableFromCdn = false;/);
  assert.match(block, /var urls = applyEtcherSortableSettings\(\);/);
  // A host that pre-imports Etcher replaces the wrapper hook: the settings
  // are also applied once the page has parsed, so they reach that Etcher too.
  assert.match(src, /document\.addEventListener\("DOMContentLoaded", applyEtcherSortableSettings\);/);
  assert.match(src, /var sortable = configureEtcherSortable\(\);[\s\S]{0,200}?return Promise\.all\(\[etcher, sortable\]\);/,
    "configured before Etcher can mount");
});

test("a module (wavesurfer) tries an opted-in CDN once after the host's copy fails, and a rescue leaves no alert", async () => {
  const p = page({});
  const mod = await p.lib.load("wavesurfer", "data:text/javascript,throw new Error('local broken')",
    { module: true, fallback: "data:text/javascript,export default 7" });
  assert.strictEqual(mod.default, 7);
  assert.strictEqual(p.window.__pkLibFailures.wavesurfer, undefined);
});

test("a module with no fallback fails once, and stays failed for the page", async () => {
  const p = page({});
  await assert.rejects(p.lib.load("wavesurfer", "data:text/javascript,throw new Error('x')", { module: true }));
  assert.strictEqual(p.window.__pkLibFailures.wavesurfer.reason, "load");
});
