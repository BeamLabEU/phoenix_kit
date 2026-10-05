"use strict";

// Unit tests for RowMenu's portal inside a modal dialog, in
// priv/static/assets/phoenix_kit.js. The menu is portaled out of its row
// while open so `position: fixed` escapes any transformed ancestor; but a
// popup shown with showModal() sits in the top layer and makes everything
// outside it inert, so a menu portaled to <body> was hidden behind the
// popup and took no click (the projects hub's "Modules & Features" popup,
// 2026-10-05). Inside an open dialog the portal is the dialog itself, and
// with the Popover API the menu is shown as a manual popover on top.
//
// The hook's real mounted(), _open() and _close() run over stub elements.
//
// Run: mix test.js  (node --test needs the explicit file on Node 25)

const test = require("node:test");
const assert = require("node:assert/strict");

const noop = () => {};

function stubElement() {
  const el = {
    style: {},
    dataset: {},
    children: [],
    parentNode: null,
    attrs: {},
    classList: { add: noop, remove: noop, toggle: noop, contains: () => false },
    setAttribute: (name, value) => { el.attrs[name] = value; },
    getAttribute: (name) => (name in el.attrs ? el.attrs[name] : null),
    removeAttribute: noop,
    appendChild: (child) => {
      if (child.parentNode && child.parentNode !== el && child.parentNode.children) {
        child.parentNode.children = child.parentNode.children.filter((c) => c !== child);
      }
      child.parentNode = el;
      el.children.push(child);
    },
    insertBefore: (child) => el.appendChild(child),
    remove: noop,
    addEventListener: noop,
    removeEventListener: noop,
    querySelector: () => null,
    querySelectorAll: () => [],
  };
  return el;
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

const storage = { getItem: () => null, setItem: noop, removeItem: noop, key: () => null, length: 0 };

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
  innerWidth: 1000,
  innerHeight: 800,
  setTimeout,
  clearTimeout,
};

global.localStorage = storage;
global.sessionStorage = storage;

require("../../priv/static/assets/phoenix_kit.js");
const RowMenu = global.window.PhoenixKitHooks.RowMenu;

// A row menu whose wrapper sits inside `dialog` (or on a plain page when
// null); `popover` gives the <ul> the Popover API, as current browsers do.
function mountMenu({ dialog = null, popover = true } = {}) {
  const trigger = Object.assign(stubElement(), {
    getBoundingClientRect: () => ({ top: 10, bottom: 34, left: 900, right: 940 }),
    focus: noop,
  });
  const menu = Object.assign(stubElement(), {
    offsetWidth: 200,
    offsetHeight: 300,
    contains: () => false,
    popoverOpen: false,
    calls: [],
    matches: (selector) => (selector === ":popover-open" ? menu.popoverOpen : false),
  });
  if (popover) {
    menu.showPopover = () => { menu.calls.push("show"); menu.popoverOpen = true; };
    menu.hidePopover = () => { menu.calls.push("hide"); menu.popoverOpen = false; };
  }
  const home = stubElement();
  home.appendChild(menu);
  const wrapper = Object.assign(stubElement(), {
    contains: () => false,
    closest: (sel) => (sel === "dialog" ? dialog : null),
    querySelector: (sel) => {
      if (sel === "[data-row-menu-trigger]") return trigger;
      if (sel === "[data-row-menu-content]") return menu;
      return null;
    },
  });
  const hook = Object.create(RowMenu);
  hook.el = wrapper;
  hook.mounted();
  return { hook, menu, home, trigger };
}

test("inside an open dialog the menu is portaled into the dialog and shown as a popover", () => {
  const dialog = Object.assign(stubElement(), { open: true });
  const { hook, menu, home } = mountMenu({ dialog });
  assert.equal(menu.attrs.popover, "manual");
  hook._open();
  assert.equal(menu.parentNode, dialog);
  assert.deepEqual(menu.calls, ["show"]);
  // right edge on the trigger's right edge, below it
  assert.equal(menu.style.left, 940 - 200 + "px");
  assert.equal(menu.style.top, 34 + 4 + "px");
  hook._close();
  assert.deepEqual(menu.calls, ["show", "hide"]);
  assert.equal(menu.parentNode, home);
});

test("on a plain page the portal is <body>, still a popover", () => {
  const { hook, menu } = mountMenu();
  hook._open();
  assert.equal(menu.parentNode, global.document.body);
  assert.deepEqual(menu.calls, ["show"]);
});

test("a closed dialog is not a portal", () => {
  const dialog = Object.assign(stubElement(), { open: false });
  const { hook, menu } = mountMenu({ dialog });
  hook._open();
  assert.equal(menu.parentNode, global.document.body);
});

test("without the Popover API the dialog portal still applies", () => {
  const dialog = Object.assign(stubElement(), { open: true });
  const { hook, menu } = mountMenu({ dialog, popover: false });
  assert.equal(menu.attrs.popover, undefined);
  hook._open();
  assert.equal(menu.parentNode, dialog);
  assert.deepEqual(menu.calls, []);
});

test("a patch that strips the popover attribute while closed does not break the next open", () => {
  const { hook, menu } = mountMenu();
  // The patcher removes attributes the server did not render.
  delete menu.attrs.popover;
  menu.style = {};
  // Like the browser: showPopover() throws on an element that is not a popover.
  const show = menu.showPopover;
  menu.showPopover = () => {
    if (menu.attrs.popover !== "manual") throw new Error("NotSupportedError");
    show();
  };
  hook._open();
  assert.equal(menu.attrs.popover, "manual");
  assert.equal(menu.style.inset, "auto");
  assert.equal(menu.popoverOpen, true);
  assert.equal(hook.isOpen, true);
});
