"use strict";

// The language submenu of the account menu (<pk-session-languages> in
// priv/static/assets/phoenix_kit.js) closes when focus leaves it. Safari does
// not focus a pressed button or link: it focuses the nearest focusable
// ancestor, which is the account menu's own list. That must not close the
// panel, or the language under the finger is hidden before its click arrives
// (an iPad could open the list and never switch).
//
// Run: mix test.js  (node --test needs the explicit file on Node 25)

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

// Listeners the element puts on `document` while its panel is open.
const docListeners = {};

global.document = {
  documentElement: stubElement(),
  head: stubElement(),
  body: stubElement(),
  createElement: stubElement,
  createTextNode: () => ({}),
  getElementById: () => null,
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener(type, fn, options) {
    (docListeners[type] = docListeners[type] || []).push(fn);
    const signal = options && options.signal;
    if (signal) {
      signal.addEventListener("abort", () => {
        docListeners[type] = docListeners[type].filter(other => other !== fn);
      });
    }
  },
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

let SessionLanguages = null;

global.HTMLElement = class {};
global.customElements = {
  get: () => undefined,
  define(name, klass) {
    if (name === "pk-session-languages") SessionLanguages = klass;
  },
};

global.window = {
  PhoenixKitHooks: {},
  customElements: global.customElements,
  addEventListener: noop,
  removeEventListener: noop,
  matchMedia: () => ({ matches: false, addEventListener: noop, removeEventListener: noop }),
  localStorage: storage,
  sessionStorage: storage,
  location: { href: "http://localhost/", reload: noop },
  navigator: { userAgent: "node" },
  document: global.document,
  innerWidth: 1024,
  innerHeight: 768,
  setTimeout,
  clearTimeout,
};

global.localStorage = storage;
global.sessionStorage = storage;

require("../../priv/static/assets/phoenix_kit.js");

// An open submenu: the element, its <details>, the panel with one language
// button, and the account menu's focusable list around it.
function openMenu() {
  const element = new SessionLanguages();
  const button = { contains: node => node === button };
  const summary = { focus: noop };
  const panel = { contains: node => node === panel || node === button };
  const details = { open: true, firstElementChild: summary, lastElementChild: panel };
  const inside = [element, details, summary, panel, button];

  element.querySelector = () => details;
  element.contains = node => inside.includes(node);
  element.closest = () => null;

  const list = { contains: node => node === list || inside.includes(node) };
  const elsewhere = { contains: node => node === elsewhere };

  element.openPanel();
  return { element, details, button, list, elsewhere };
}

function focusin(target) {
  (docListeners.focusin || []).slice().forEach(fn => fn({ target }));
}

test("the bundle defines the element", () => {
  assert.equal(typeof SessionLanguages, "function");
});

test("focus landing on the account menu's list keeps the panel open", () => {
  const { element, details, list } = openMenu();

  focusin(list);

  assert.equal(details.open, true);
  element.close();
});

test("focus on a language keeps the panel open", () => {
  const { element, details, button } = openMenu();

  focusin(button);

  assert.equal(details.open, true);
  element.close();
});

test("focus moving elsewhere on the page closes the panel", () => {
  const { details, elsewhere } = openMenu();

  focusin(elsewhere);

  assert.equal(details.open, false);
});
