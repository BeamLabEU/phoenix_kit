"use strict";

// A fake browser page for tests that need the shipped bundles as a browser
// would run them: one `window` shared by every file loaded into it, scripts
// appended to <head> recorded (and made to load or fail on demand), and the
// console captured.
//
//   const env = createEnv({ facts: { admin: { file: "admin-1.js", cdn: null } } });
//   env.load("phoenix_kit.js");           // the public bundle
//   env.load("phoenix_kit_admin.js");     // what a stub's load would run
//
// The older tests build their own stubs and `require` the bundle; this one
// exists for the split, where the same page has to run two files in turn and
// the test has to see what the first one asked the browser to fetch.

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const ASSETS = path.join(__dirname, "..", "..", "..", "priv", "static", "assets");

function createEnv(opts) {
  opts = opts || {};
  const scripts = [];
  const errors = [];
  const warnings = [];
  const logs = [];
  const docListeners = {};
  const winListeners = {};
  const storage = {};
  const els = {};

  function makeEl(tag) {
    const el = {
      tagName: String(tag || "div").toUpperCase(),
      style: {},
      dataset: {},
      attrs: {},
      children: [],
      textContent: "",
      removed: false,
      classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
      setAttribute(k, v) { this.attrs[k] = String(v); },
      getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; },
      removeAttribute(k) { delete this.attrs[k]; },
      hasAttribute(k) { return k in this.attrs; },
      appendChild(c) { this.children.push(c); return c; },
      remove() { this.removed = true; },
      addEventListener() {},
      removeEventListener() {},
      querySelector: () => null,
      querySelectorAll: () => [],
      closest: () => null,
      insertAdjacentElement() {},
    };
    return el;
  }

  const marked = { admin: !!opts.adminLayout };
  const document = {
    readyState: opts.readyState || "complete",
    currentScript: null,
    documentElement: makeEl("html"),
    body: makeEl("body"),
    head: {
      appendChild(s) { if (s.tagName === "SCRIPT") scripts.push(s); return s; },
      querySelector: () => null,
    },
    cookie: "",
    createElement: makeEl,
    createElementNS: makeEl,
    createTextNode: (t) => ({ nodeType: 3, textContent: t }),
    getElementById: (id) => els[id] || null,
    // The one selector the bundle asks the document about at load.
    querySelector: (sel) => (sel === "[data-pk-admin]" && marked.admin ? makeEl("div") : null),
    querySelectorAll: () => [],
    addEventListener: (n, fn) => ((docListeners[n] = docListeners[n] || []).push(fn)),
    removeEventListener: (n, fn) => {
      docListeners[n] = (docListeners[n] || []).filter((f) => f !== fn);
    },
  };

  const sessionStorage = {
    getItem: (k) => (k in storage ? storage[k] : null),
    setItem: (k, v) => { storage[k] = String(v); },
    removeItem: (k) => { delete storage[k]; },
  };
  const localStorage = { getItem: () => null, setItem() {}, removeItem() {} };

  function CustomEvent(type, init) { this.type = type; this.detail = init && init.detail; }

  const sandbox = {
    console: {
      error: (...a) => errors.push(a.join(" ")),
      warn: (...a) => warnings.push(a.join(" ")),
      log: (...a) => logs.push(a.join(" ")),
      debug: () => {},
      info: () => {},
    },
    document,
    sessionStorage,
    localStorage,
    CustomEvent,
    URL,
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
    requestAnimationFrame: (fn) => setTimeout(fn, 0),
    cancelAnimationFrame: clearTimeout,
    navigator: { userAgent: "node", language: "en" },
    location: { href: "https://app.test/admin", origin: "https://app.test", pathname: "/admin" },
    matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
    addEventListener: (n, fn) => ((winListeners[n] = winListeners[n] || []).push(fn)),
    removeEventListener: (n, fn) => {
      winListeners[n] = (winListeners[n] || []).filter((f) => f !== fn);
    },
    dispatchEvent: (e) => { (winListeners[e.type] || []).forEach((fn) => fn(e)); return true; },
    MutationObserver: function () { this.observe = () => {}; this.disconnect = () => {}; },
    ResizeObserver: function () { this.observe = () => {}; this.disconnect = () => {}; },
    IntersectionObserver: function () { this.observe = () => {}; this.disconnect = () => {}; },
    getComputedStyle: () => ({ getPropertyValue: () => "" }),
    fetch: () => Promise.reject(new Error("no network in tests")),
    Intl,
  };
  // A clock the test moves: code that asks `Date.now()` sees `env.advance(ms)`,
  // so a pause of seconds is tested without waiting for it.
  const clock = { t: 1_700_000_000_000 };
  const RealDate = Date;
  sandbox.Date = class extends RealDate {
    static now() { return clock.t; }
  };
  sandbox.window = sandbox;
  sandbox.self = sandbox;
  sandbox.globalThis = sandbox;
  sandbox.location.reload = () => {};
  sandbox.history = { replaceState() {}, pushState() {} };
  if (opts.facts) sandbox.PHOENIX_KIT_LIBS = opts.facts;
  if (opts.libBase) sandbox.PHOENIX_KIT_LIB_BASE = opts.libBase;

  const ctx = vm.createContext(sandbox);

  // Runs one shipped file the way a <script> tag would: `currentScript` is
  // set while it evaluates, and CommonJS `module` exists so the pure helpers
  // each file exports for the node tests are returned.
  function load(file, loadOpts) {
    loadOpts = loadOpts || {};
    const full = path.isAbsolute(file) ? file : path.join(ASSETS, file);
    const code = fs.readFileSync(full, "utf8");
    sandbox.module = { exports: {} };
    document.currentScript = {
      src: loadOpts.src || "https://app.test/assets/vendor/" + path.basename(file),
      nonce: loadOpts.nonce || "",
    };
    try {
      vm.runInContext(code, ctx, { filename: full });
    } finally {
      document.currentScript = null;
    }
    const exported = sandbox.module.exports;
    delete sandbox.module;
    return exported;
  }

  // The nth script the page asked the browser to fetch settles.
  const settle = (i, ok) => {
    const s = scripts[i];
    if (!s) throw new Error("no script #" + i + " was requested");
    if (ok) s.onload && s.onload(); else s.onerror && s.onerror();
  };

  // The page finished parsing: what DOMContentLoaded listeners were waiting for.
  const fireDocument = (name) => (docListeners[name] || []).slice().forEach((fn) => fn({ type: name }));

  return {
    advance: (ms) => { clock.t += ms; },
    fireDocument,
    markAdminLayout: () => { marked.admin = true; },
    window: sandbox,
    document,
    scripts,
    errors,
    warnings,
    logs,
    els,
    makeEl,
    load,
    loaded: (i) => settle(i, true),
    failed: (i) => settle(i, false),
    storage,
  };
}

// A LiveView `ViewHook` stand-in: callbacks set on it are what the framework
// would call, `handleEvent` registrations and `pushEvent` calls are recorded.
function makeHook(def, el) {
  const h = Object.assign({}, def);
  h.el = el || null;
  h.pushed = [];
  h.handlers = {};
  h.pushEvent = function (name, payload) { h.pushed.push([name, payload]); };
  h.handleEvent = function (name, fn) { h.handlers[name] = fn; };
  return h;
}

module.exports = { createEnv, makeHook, ASSETS };
