"use strict";

// The listeners in priv/static/assets/phoenix_kit.js that replaced the kit's
// inline handlers (onclick=, onerror=, onfocus= ...), which a
// Content-Security-Policy without 'unsafe-inline' blocks.
//
// Run: mix test.js

const test = require("node:test");
const assert = require("node:assert/strict");

const noop = () => {};

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

global.document = {
  documentElement: stubElement(),
  head: stubElement(),
  body: stubElement(),
  createElement: stubElement,
  createTextNode: () => ({}),
  getElementById: () => null,
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener: noop,
  removeEventListener: noop,
  readyState: "complete",
};

const storage = {
  getItem: () => null,
  setItem: noop,
  removeItem: noop,
  key: () => null,
  length: 0,
};

global.window = {
  PhoenixKitHooks: {},
  addEventListener: noop,
  removeEventListener: noop,
  matchMedia: () => ({ matches: false, addEventListener: noop, removeEventListener: noop }),
  localStorage: storage,
  sessionStorage: storage,
  location: { href: "http://localhost/", reload: noop },
  navigator: { userAgent: "node" },
  document: global.document,
  setTimeout,
  clearTimeout,
};

global.localStorage = storage;
global.sessionStorage = storage;

const copied = [];
Object.defineProperty(global, "navigator", {
  configurable: true,
  value: { clipboard: { writeText: (t) => { copied.push(t); return Promise.resolve(); } } },
});

const {
  sweepBrokenImages, onConsentClick,
  copyTextFor, onImageError, zeroFocus, zeroBlur, zeroEnter, filterLanguages, previewMark,
  onDeclaredClick,
} = require("../../priv/static/assets/phoenix_kit.js");

function el(attrs, extra) {
  return Object.assign({
    attrs: attrs || {},
    hasAttribute(k) { return k in this.attrs; },
    getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; },
    closest(selector) {
      return selector.split(",").some((s) => s.slice(1, -1) in this.attrs) ? this : null;
    },
  }, extra || {});
}

// --- copy -------------------------------------------------------------------

test("a copy button gives its own text, or the text of the element it names", () => {
  const doc = {
    getElementById: (id) => ({
      pre: { tagName: "PRE", textContent: "{json}" },
      field: { tagName: "INPUT", value: "typed", textContent: "" },
      // An <li> has a numeric `value` of its own; its text is what is copied.
      item: { tagName: "LI", value: 0, textContent: "third" },
    })[id] || null,
  };

  assert.equal(copyTextFor(el({ "data-pk-copy": "https://x/cb" }), doc), "https://x/cb");
  assert.equal(copyTextFor(el({ "data-pk-copy-from": "pre" }), doc), "{json}");
  assert.equal(copyTextFor(el({ "data-pk-copy-from": "field" }), doc), "typed");
  assert.equal(copyTextFor(el({ "data-pk-copy-from": "item" }), doc), "third");
  assert.equal(copyTextFor(el({ "data-pk-copy-from": "gone" }), doc), null);
});

test("a click on a copy button writes to the clipboard", () => {
  copied.length = 0;
  onDeclaredClick({ target: el({ "data-pk-copy": "a'b\"c" }) });
  assert.deepEqual(copied, ["a'b\"c"]);
});

test("a click inside data-pk-blur drops the focus, any other click does not", () => {
  let blurred = 0;
  global.document.activeElement = { blur: () => blurred++ };

  onDeclaredClick({ target: el({ "data-pk-blur": "" }) });
  onDeclaredClick({ target: el({}) });

  assert.equal(blurred, 1);
});

test("a focused node without blur() does not throw", () => {
  global.document.activeElement = {};
  assert.doesNotThrow(() => onDeclaredClick({ target: el({ "data-pk-blur": "" }) }));
  global.document.activeElement = null;
});

// --- broken images ----------------------------------------------------------

test("a broken image hides, removes itself or shows its placeholder", () => {
  const hide = el({ "data-pk-img-error": "hide" }, { style: {} });
  onImageError(hide);
  assert.equal(hide.style.display, "none");

  let removed = false;
  onImageError(el({ "data-pk-img-error": "remove" }, { remove: () => { removed = true; } }));
  assert.equal(removed, true);

  const holder = { style: {} };
  onImageError(el({ "data-pk-img-error": "placeholder" }, {
    parentElement: { querySelector: (q) => (q === ".image-error-placeholder" ? holder : null) },
  }));
  assert.equal(holder.style.display, "grid");
});

// --- <.decimal_input>: the zero that clears on focus --------------------------

// Steps: "focus", "blur", ["type", text], ["key", key]. Returns the value after
// the first focus, the value at the end, and how many input events the element
// dispatched on its own.
function run(value, steps, opts) {
  const input = Object.assign(new EventTarget(), { value, readOnly: !!(opts && opts.readonly) });
  let own = 0, typing = false, focused;
  input.addEventListener("input", () => { if (!typing) own++; });

  steps.forEach((step) => {
    if (step === "focus") {
      zeroFocus(input);
      if (focused === undefined) focused = input.value;
    } else if (step === "blur") {
      zeroBlur(input);
    } else if (step[0] === "key") {
      if (step[1] === "Enter") zeroEnter(input);
    } else {
      input.value = step[1];
      typing = true;
      input.dispatchEvent(new Event("input"));
      typing = false;
    }
  });

  return [focused, input.value, own];
}

test("0 clears on focus and returns on blur, typed text stays", () => {
  assert.deepEqual(run("0", ["focus", "blur"]), ["", "0", 0]);
  assert.deepEqual(run("0", ["focus", ["type", "8"], "blur"]), ["", "8", 0]);
  assert.deepEqual(run("0,00", ["focus", "blur"]), ["", "0,00", 0]);
  assert.deepEqual(run("0,00", ["focus", ["type", "15"], "blur"]), ["", "15", 0]);
  assert.deepEqual(run("2.5", ["focus", "blur"]), ["2.5", "2.5", 0]);
  assert.deepEqual(run("2.5", ["focus", ["type", "3"], "blur"]), ["2.5", "3", 0]);
  assert.deepEqual(run("", ["focus", "blur"]), ["", "", 0]);
});

test("only a zero-like text is cleared", () => {
  for (const zero of ["0", "0,00", "0.0", " 0 ", "-0", ",0", "00"]) {
    assert.equal(run(zero, ["focus"])[0], "", zero);
  }
  for (const other of ["1", "0,5", "10", "2.5", "0x"]) {
    assert.equal(run(other, ["focus"])[0], other, other);
  }
});

test("typed then erased: the zero returns and announces itself once", () => {
  const steps = ["focus", ["type", "5"], ["type", ""], "blur"];
  assert.deepEqual(run("0", steps), ["", "0", 1]);
  // the next untouched focus/blur does not re-announce
  assert.deepEqual(run("0", steps.concat(["focus", "blur"])), ["", "0", 1]);
});

test("Enter in the emptied field puts the zero back before the submit", () => {
  assert.deepEqual(run("0", ["focus", ["key", "Enter"]]), ["", "0", 0]);
  assert.deepEqual(run("0", ["focus", ["key", "Enter"], "blur"]), ["", "0", 0]);
  assert.deepEqual(run("0", ["focus", ["key", "a"]]), ["", "", 0]);
  assert.deepEqual(run("0", ["focus", ["type", "4"], ["key", "Enter"]]), ["", "4", 0]);
});

test("a readonly zero is left alone", () => {
  assert.deepEqual(run("0", ["focus", ["key", "Enter"], "blur"], { readonly: true }), ["0", "0", 0]);
});

// LiveView's patch of a focused input removes every attribute the server did
// not render, so a zero parked in `data-*` would be lost on a re-render.
test("the remembered zero never lives in a data- attribute", () => {
  const input = Object.assign(new EventTarget(), { value: "0", dataset: {} });
  zeroFocus(input);
  assert.deepEqual(input.dataset, {});
  assert.equal(input.__pkZero, "0");
});

// --- language switcher search -----------------------------------------------

test("the language filter hides what does not match and shows the empty line", () => {
  const item = (name, native) => ({ dataset: { name, native }, style: {} });
  const items = [item("english", "english"), item("estonian", "eesti"), item("german", "deutsch")];
  const empty = { style: {} };
  const list = {
    querySelectorAll: () => items,
    querySelector: () => empty,
  };
  const input = { value: " EEs ", closest: () => list };

  filterLanguages(input);
  assert.deepEqual(items.map((i) => i.style.display), ["none", "", "none"]);
  assert.equal(empty.style.display, "none");

  input.value = "zzz";
  filterLanguages(input);
  assert.equal(empty.style.display, "");

  input.value = "";
  filterLanguages(input);
  assert.deepEqual(items.map((i) => i.style.display), ["", "", ""]);
});

// --- <.preview_card> ---------------------------------------------------------

test("the jump strip marks the slide the track shows", () => {
  const tile = () => {
    const t = { on: new Set(), attrs: {} };
    t.classList = { toggle: (c, v) => (v ? t.on.add(c) : t.on.delete(c)) };
    t.setAttribute = (k, v) => { t.attrs[k] = v; };
    t.removeAttribute = (k) => { delete t.attrs[k]; };
    return t;
  };
  const tiles = [tile(), tile(), tile()];
  const root = { querySelector: () => ({ children: tiles }) };
  const track = { scrollLeft: 410, clientWidth: 400, closest: () => root };

  previewMark(track);

  assert.deepEqual(tiles.map((t) => t.on.has("border-primary")), [false, true, false]);
  assert.deepEqual(tiles.map((t) => t.attrs["aria-current"]), [undefined, "true", undefined]);
});

test("an arrow scrolls the track by one slide, a tile jumps to its slide", () => {
  const scrolled = [];
  const shown = [];
  const slides = [0, 1, 2].map((i) => ({ scrollIntoView: () => shown.push(i) }));
  const track = { clientWidth: 400, children: slides, scrollBy: (o) => scrolled.push(o.left) };
  const root = { querySelector: () => track };
  const button = (attrs) => el(attrs, {
    closest(selector) {
      if (selector === "[data-pc-root]") return root;
      return selector.split(",").some((s) => s.slice(1, -1) in this.attrs) ? this : null;
    },
  });

  onDeclaredClick({ target: button({ "data-pc-step": "-1" }) });
  onDeclaredClick({ target: button({ "data-pc-step": "1" }) });
  onDeclaredClick({ target: button({ "data-pc-jump": "2" }) });

  assert.deepEqual(scrolled, [-400, 400]);
  assert.deepEqual(shown, [2]);
});

// --- the sweep for images that failed before the bundle ran --------------------

test("the sweep handles a finished image with no pixels, and leaves SVGs and loaded ones alone", () => {
  const img = (src, complete, naturalWidth) =>
    el({ "data-pk-img-error": "hide", src }, { style: {}, complete, naturalWidth });
  const broken = img("/a.png", true, 0);
  const loaded = img("/b.png", true, 40);
  const pending = img("/c.png", false, 0);
  const svg = img("/logo.svg?v=2", true, 0);
  const inlineSvg = img("data:image/svg+xml;base64,AAAA", true, 0);
  const none = img("", true, 0);

  const before = global.document.querySelectorAll;
  global.document.querySelectorAll = () => [broken, loaded, pending, svg, inlineSvg, none];
  try {
    sweepBrokenImages();
  } finally {
    global.document.querySelectorAll = before;
  }

  assert.equal(broken.style.display, "none");
  for (const other of [loaded, pending, svg, inlineSvg, none]) {
    assert.equal(other.style.display, undefined);
  }
});

// --- cookie consent buttons ---------------------------------------------------

test("a consent button runs its allow-listed action and nothing else", () => {
  const calls = [];
  const before = global.window.PhoenixKitConsent;
  global.window.PhoenixKitConsent = {
    acceptAll: () => calls.push("acceptAll"),
    closePreferences: () => calls.push("closePreferences"),
    // Reachable on the object, not on the list: must never run from markup.
    init: () => calls.push("init"),
    updateGoogleConsent: () => calls.push("updateGoogleConsent"),
  };

  try {
    for (const action of ["acceptAll", "closePreferences", "init", "updateGoogleConsent",
      "constructor", "__proto__", "toString", ""]) {
      onConsentClick({ target: el({ "data-pk-consent": action }) });
    }
    onConsentClick({ target: el({}) });
    onConsentClick({ target: null });
  } finally {
    global.window.PhoenixKitConsent = before;
  }

  assert.deepEqual(calls, ["acceptAll", "closePreferences"]);
});

// --- the file included twice ---------------------------------------------------

test("a second include of the bundle installs no listener twice", () => {
  const { createEnv } = require("./support/pk_env.cjs");
  const env = createEnv({});
  env.load("phoenix_kit.js");

  const once = env.listenerCounts();
  assert.ok(once.document.click > 0, "the bundle listens for clicks");
  assert.equal(once.window["phx:phoenix_kit:set_input"], 1);

  env.load("phoenix_kit.js");
  assert.deepEqual(env.listenerCounts(), once);
  assert.deepEqual(env.errors, []);
});

test("consent script replacement skips the hidden nonce attribute and copies script.nonce", () => {
  const { createEnv } = require("./support/pk_env.cjs");
  const env = createEnv({});
  env.load("phoenix_kit.js");

  const replaced = [];
  const origCreate = env.document.createElement;
  env.document.createElement = (tag) => {
    const el = origCreate(tag);
    el.nonce = "";
    const origSet = el.setAttribute.bind(el);
    el.setAttribute = (k, v) => {
      // Model HTMLOrSVGElement attribute change steps: setting `nonce=""`
      // clears the internal nonce on spec-compliant engines.
      if (k === "nonce") el.nonce = String(v);
      origSet(k, v);
    };
    return el;
  };

  const blocked = {
    nonce: "page-nonce-123",
    src: "",
    textContent: "window.__ran = true;",
    attributes: [
      { name: "type", value: "text/plain" },
      { name: "data-consent-category", value: "analytics" },
      { name: "data-blocked", value: "true" },
      { name: "nonce", value: "" },
    ],
    parentNode: { replaceChild: (next, prev) => replaced.push({ next, prev }) },
  };
  const unnonced = {
    nonce: "",
    src: "",
    textContent: "window.__unnonced = true;",
    attributes: [
      { name: "type", value: "text/plain" },
      { name: "data-consent-category", value: "analytics" },
      { name: "data-blocked", value: "true" },
    ],
    parentNode: { replaceChild: (next, prev) => replaced.push({ next, prev }) },
  };

  env.document.querySelectorAll = (sel) =>
    sel.includes('data-consent-category="analytics"') ? [blocked, unnonced] : [];

  env.window.PhoenixKitConsent.acceptAll();

  assert.equal(replaced.length, 2);
  assert.equal(replaced[0].next.nonce, "page-nonce-123");
  assert.equal("nonce" in replaced[0].next.attrs, false);
  assert.equal(replaced[1].next.nonce, "");
});
