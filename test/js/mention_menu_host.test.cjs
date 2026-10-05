"use strict";

// Unit tests for MentionInput's menu host and placement in
// priv/static/assets/phoenix_kit.js. A textarea inside a <dialog> shown with
// showModal() sits in the browser's top layer, which paints over everything
// outside it whatever its z-index — a menu left on <body> was there, open,
// and invisible behind the popup (the projects hub's "Add task" popup,
// 2026-10-05), and a popover on <body> is painted above it but inert — a
// modal dialog makes everything outside it inert. The menu is now a manual
// popover INSIDE the open dialog (top layer, not inert), put back by a
// MutationObserver when a LiveView patch of the dialog discards it; on a
// plain page it stays on <body>. And it opens under the `@`/`#` itself
// rather than under the whole field.
//
// The hook's real `mounted()`, `render()` and `position()` run here over
// stub elements; the trigger character's box is stubbed (`anchor`), since
// there is no layout engine.
//
// Run: mix test.js  (node --test needs the explicit file on Node 25)

const test = require("node:test");
const assert = require("node:assert/strict");

const noop = () => {};

function stubElement() {
  const el = {
    style: {},
    offsetWidth: 288,
    offsetHeight: 200,
    scrollTop: 0,
    scrollLeft: 0,
    innerHTML: "",
    popoverOpen: false,
    matches: (selector) => (selector === ":popover-open" ? el.popoverOpen : false),
    dataset: {},
    children: [],
    parentNode: null,
    classList: { add: noop, remove: noop, toggle: noop, contains: () => false },
    attrs: {},
    setAttribute: (name, value) => { el.attrs[name] = value; },
    getAttribute: () => null,
    removeAttribute: noop,
    appendChild: (child) => {
      if (child.parentNode && child.parentNode !== el) {
        child.parentNode.children = child.parentNode.children.filter((c) => c !== child);
      }
      child.parentNode = el;
      el.children.push(child);
    },
    removeChild: (child) => {
      el.children = el.children.filter((c) => c !== child);
      child.parentNode = null;
    },
    remove: noop,
    addEventListener: noop,
    removeEventListener: noop,
    querySelector: () => null,
    querySelectorAll: () => [],
  };
  return el;
}

global.document = {
  documentElement: Object.assign(stubElement(), { clientWidth: 1200 }),
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

const storage = { getItem: () => null, setItem: noop, removeItem: noop, key: () => null, length: 0 };

global.window = {
  PhoenixKitHooks: {},
  scrollX: 0,
  scrollY: 500,
  innerHeight: 800,
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

// The observers the hook installs, so a test can fire one as a patch would.
const observers = [];
global.MutationObserver = function(callback) {
  this.callback = callback;
  this.observe = (target, options) => { this.target = target; this.options = options; observers.push(this); };
  this.disconnect = () => { const i = observers.indexOf(this); if (i >= 0) observers.splice(i, 1); };
};

require("../../priv/static/assets/phoenix_kit.js");
const MentionInput = global.window.PhoenixKitHooks.MentionInput;

// A textarea stub whose `closest("dialog")` answers `dialog` (or nothing).
function field(dialog) {
  const el = stubElement();
  el.value = "#";
  el.selectionStart = 1;
  el.getBoundingClientRect = () => ({ top: 100, bottom: 180, left: 300, right: 800, width: 500, height: 80 });
  el.closest = (selector) => (selector === "dialog" ? dialog : null);
  return el;
}

// `popover: true` gives the menu the Popover API, as current browsers do.
function mount(el, { popover = true } = {}) {
  const hook = Object.create(MentionInput);
  hook.el = el;
  hook.pushEvent = noop;
  hook.handleEvent = noop;
  const createElement = global.document.createElement;
  if (popover) {
    global.document.createElement = () => {
      const menu = createElement();
      menu.calls = [];
      menu.showPopover = () => { menu.calls.push("show"); menu.popoverOpen = true; };
      menu.hidePopover = () => { menu.calls.push("hide"); menu.popoverOpen = false; };
      return menu;
    };
  }
  try {
    hook.mounted();
  } finally {
    global.document.createElement = createElement;
  }
  // the `#` sits 20px down and 40px in, on a 20px line
  hook.anchor = () => ({ top: 20, left: 40, height: 20 });
  return hook;
}

function open(hook) {
  hook.active = { char: "#", start: 0, query: "" };
  hook.results = [{ title: "ANDI Manager", subtitle: "Project" }];
  hook.render();
}

test("with the Popover API, inside an open dialog, the menu is a popover IN the dialog", () => {
  const dialog = Object.assign(stubElement(), { open: true, isConnected: true });
  const hook = mount(field(dialog));
  assert.equal(hook.menu.attrs.popover, "manual");
  open(hook);
  assert.equal(hook.menu.parentNode, dialog);
  assert.equal(global.document.body.children.includes(hook.menu), false);
  assert.equal(hook.menu.style.position, "fixed");
  assert.deepEqual(hook.menu.calls, ["show"]);
  // viewport coordinates, under the trigger's line, at its column
  assert.equal(hook.menu.style.top, 100 + 20 + 20 + 2 + "px");
  assert.equal(hook.menu.style.left, 300 + 40 + "px");
});

test("on a plain page the popover menu stays on <body>", () => {
  const hook = mount(field(null));
  open(hook);
  assert.equal(hook.menu.parentNode, global.document.body);
  assert.equal(hook.menu.style.position, "fixed");
  assert.deepEqual(hook.menu.calls, ["show"]);
  assert.equal(hook.menu.style.top, 100 + 20 + 20 + 2 + "px");
});

test("a patch that discards the menu from the dialog gets it put back and reopened", () => {
  const dialog = Object.assign(stubElement(), { open: true, isConnected: true });
  const hook = mount(field(dialog));
  open(hook);
  const observer = observers.find((o) => o.target === dialog);
  assert.ok(observer, "the dialog is observed");
  assert.deepEqual(observer.options, { childList: true });
  // the patch: node gone, popover closed with it
  dialog.removeChild(hook.menu);
  hook.menu.popoverOpen = false;
  observer.callback([]);
  assert.equal(hook.menu.parentNode, dialog);
  assert.deepEqual(hook.menu.calls, ["show", "show"]);
  // closed menu: a patch is left alone
  hook.close();
  dialog.removeChild(hook.menu);
  observer.callback([]);
  assert.equal(hook.menu.parentNode, null);
});

test("closing hides the popover; rendering again does not call showPopover twice", () => {
  const hook = mount(field(null));
  open(hook);
  hook.render();
  assert.deepEqual(hook.menu.calls, ["show"]);
  hook.close();
  assert.deepEqual(hook.menu.calls, ["show", "hide"]);
  assert.equal(hook.menu.popoverOpen, false);
});

test("without the Popover API, inside an open dialog, the menu moves into it, fixed", () => {
  const dialog = Object.assign(stubElement(), { open: true });
  const hook = mount(field(dialog), { popover: false });
  open(hook);
  assert.equal(hook.menu.parentNode, dialog);
  assert.equal(global.document.body.children.includes(hook.menu), false);
  assert.equal(hook.menu.style.position, "fixed");
  assert.equal(hook.menu.style.top, 100 + 20 + 20 + 2 + "px");
});

test("without the Popover API, on a plain page, the menu stays on <body> in document coordinates", () => {
  const hook = mount(field(null), { popover: false });
  open(hook);
  assert.equal(hook.menu.parentNode, global.document.body);
  assert.equal(hook.menu.style.position, "");
  assert.equal(hook.menu.style.top, 100 + 20 + 20 + 2 + 500 + "px");
  assert.equal(hook.menu.style.left, 300 + 40 + "px");
});

test("without the Popover API the menu follows the field back out when the dialog closes", () => {
  const dialog = Object.assign(stubElement(), { open: true });
  const hook = mount(field(dialog), { popover: false });
  open(hook);
  assert.equal(hook.menu.parentNode, dialog);
  dialog.open = false;
  hook.render();
  assert.equal(hook.menu.parentNode, global.document.body);
  assert.equal(hook.menu.style.position, "");
});

test("the menu flips above the line when there is no room below", () => {
  const el = field(null);
  el.getBoundingClientRect = () => ({ top: 700, bottom: 780, left: 300, right: 800, width: 500, height: 80 });
  const hook = mount(el);
  open(hook);
  // 700 + 20 + 20 + 2 = 742, plus 200 tall, past 800 - 8 → above: 720 - 200 - 2
  assert.equal(hook.menu.style.top, 720 - 200 - 2 + "px");
});

test("the column is kept inside the viewport", () => {
  const el = field(null);
  el.getBoundingClientRect = () => ({ top: 100, bottom: 180, left: 1000, right: 1500, width: 500, height: 80 });
  const hook = mount(el);
  hook.anchor = () => ({ top: 0, left: 400, height: 20 });
  open(hook);
  // 1400 would run off a 1200px viewport: 1200 - 288 - 8
  assert.equal(hook.menu.style.left, 1200 - 288 - 8 + "px");
});
