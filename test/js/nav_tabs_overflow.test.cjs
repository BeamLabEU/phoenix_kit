"use strict";

// Unit tests for navTabsHidden, the pure fitting logic behind the
// NavTabsOverflow hook in priv/static/assets/phoenix_kit.js. The DOM side of
// the hook (measuring, toggling classes, the menu) needs a browser.
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

const storage = {
  getItem: () => null,
  setItem: noop,
  removeItem: noop,
  key: () => null,
  length: 0,
};

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

const { navTabsHidden } = require("../../priv/static/assets/phoenix_kit.js");

test("the hook is registered", () => {
  assert.equal(typeof global.window.PhoenixKitHooks.NavTabsOverflow.mounted, "function");
  assert.equal(typeof global.window.PhoenixKitHooks.NavTabsOverflow.updated, "function");
});

test("hides nothing that fits", () => {
  assert.deepEqual(navTabsHidden([100, 100, 100], 0, 300, 0), [false, false, false]);
});

test("hides the tabs that do not fit, keeping order, from the end", () => {
  // 100 each, 250 available: two fit, the third (and later) go.
  assert.deepEqual(navTabsHidden([100, 100, 100, 100], 0, 250, 0), [false, false, true, true]);
});

test("counts the gap between tabs", () => {
  // 2 tabs + 1 gap of 20 = 220 <= 220, a third would need 340.
  assert.deepEqual(navTabsHidden([100, 100, 100], 20, 220, 0), [false, false, true]);
  assert.deepEqual(navTabsHidden([100, 100, 100], 20, 219, 0), [false, true, true]);
});

test("a late active tab pushes earlier non-active tabs out instead of itself", () => {
  // The active tab is last: room is reserved for it, so only one earlier tab stays.
  assert.deepEqual(navTabsHidden([100, 100, 100, 100], 0, 250, 3), [false, true, true, false]);
});

test("a middle active tab stays; later tabs go once one did not fit", () => {
  assert.deepEqual(navTabsHidden([100, 100, 100, 100], 0, 250, 1), [false, false, true, true]);
});

test("a tab after the first hidden one stays hidden even if it is narrow", () => {
  assert.deepEqual(navTabsHidden([100, 200, 40], 0, 200, 0), [false, true, true]);
});

test("when the active tab alone fills the strip, every other tab hides", () => {
  assert.deepEqual(navTabsHidden([100, 400, 100], 0, 300, 1), [true, false, true]);
});

test("no active tab behaves like plain truncation from the end", () => {
  assert.deepEqual(navTabsHidden([100, 100, 100], 0, 150, -1), [false, true, true]);
});

test("sub-pixel measurement noise does not hide a tab that fits", () => {
  assert.deepEqual(navTabsHidden([100.3, 100.3], 0, 200.4, 0), [false, false]);
});

// A menu item carries no link or phx-* attributes: choosing one must close the
// menu and click the strip tab with the same id, which is what LiveView (event
// tabs) or its link handling (navigate/patch/href tabs) then acts on.
test("choosing a menu item closes the menu and clicks the matching strip tab", () => {
  global.MutationObserver = class { observe() {} takeRecords() { return []; } disconnect() {} };

  const clicks = [];
  const strip = ["a", "b", "c"].map((id) => ({
    getAttribute: (n) => (n === "data-nav-tab" ? id : null),
    click: () => clicks.push(id),
  }));
  let listener = null;
  const el = {
    addEventListener: (type, fn) => { if (type === "click") listener = fn; },
    removeEventListener: noop,
    querySelector: () => null,
    querySelectorAll: (sel) => (sel === "[data-nav-strip] [data-nav-tab]" ? strip : []),
  };

  const hook = Object.assign(Object.create(global.window.PhoenixKitHooks.NavTabsOverflow), { el });
  hook.mounted();

  const states = [];
  hook.setOpen = (open) => states.push(open);
  const item = (id) => ({
    getAttribute: (n) => (n === "data-nav-item" ? id : null),
  });
  const target = (node, selector) => ({
    closest: (sel) => (sel === selector ? node : null),
  });
  const pick = (id) =>
    listener({
      target: target(item(id), "[data-nav-menu] [role='menuitem']"),
      preventDefault: noop,
    });

  pick("b");
  assert.deepEqual(clicks, ["b"]);
  assert.deepEqual(states, [false]);

  // An id with no strip tab (stale markup) just closes.
  pick("zzz");
  assert.deepEqual(clicks, ["b"]);
  assert.deepEqual(states, [false, false]);

  // The "⋯" button toggles instead of clicking a tab.
  let prevented = false;
  listener({
    target: target({}, "[data-nav-more]"),
    preventDefault: () => { prevented = true; },
  });
  assert.equal(prevented, true);
  assert.deepEqual(clicks, ["b"]);
  assert.equal(states.length, 3);
});

// Two strips on a page: a pointerdown must close THIS strip's menu unless it
// landed on this strip's own button or menu — another strip's menu does not count.
test("an outside pointerdown closes the menu; one on its own button or menu does not", () => {
  global.MutationObserver = class { observe() {} takeRecords() { return []; } disconnect() {} };
  const captured = {};
  global.document.addEventListener = (type, fn) => { captured[type] = fn; };

  const own = (inside) => ({ contains: (node) => node === inside });
  const menu = own("menu-node");
  const more = own("more-node");
  const el = {
    addEventListener: noop,
    removeEventListener: noop,
    querySelector: () => null,
    querySelectorAll: () => [],
  };
  const hook = Object.assign(Object.create(global.window.PhoenixKitHooks.NavTabsOverflow), { el });
  hook.mounted();
  global.document.addEventListener = noop;

  const closes = [];
  hook.setOpen = (open) => closes.push(open);
  hook.el.querySelector = (sel) => (sel === "[data-nav-menu]" ? menu : sel === "[data-nav-more]" ? more : null);

  hook._open = false;
  captured.pointerdown({ target: "elsewhere" });
  assert.deepEqual(closes, [], "nothing to close while closed");

  hook._open = true;
  captured.pointerdown({ target: "menu-node" });
  captured.pointerdown({ target: "more-node" });
  assert.deepEqual(closes, []);

  captured.pointerdown({ target: "other-strips-menu-node" });
  assert.deepEqual(closes, [false]);
});

// Ctrl/Cmd/Shift-click or middle-click on the menu item of a LINK tab opens its
// URL in a new browser tab, like the tab itself would; a plain click delegates.
test("modifier and middle clicks on a link tab's menu item open it in a new tab", () => {
  global.MutationObserver = class { observe() {} takeRecords() { return []; } disconnect() {} };
  const clicks = [];
  const opened = [];
  global.window.open = (...args) => opened.push(args);

  const tabs = [
    { id: "link", href: "/p?tab=l" },
    { id: "event", href: null },
  ].map(({ id, href }) => ({
    getAttribute: (n) => (n === "data-nav-tab" ? id : n === "href" ? href : null),
    click: () => clicks.push(id),
  }));
  const handlers = {};
  const el = {
    addEventListener: (type, fn) => { handlers[type] = fn; },
    removeEventListener: noop,
    querySelector: () => null,
    querySelectorAll: () => tabs,
  };
  const hook = Object.assign(Object.create(global.window.PhoenixKitHooks.NavTabsOverflow), { el });
  hook.mounted();
  const states = [];
  hook.setOpen = (open) => states.push(open);

  const event = (type, id, extra) => {
    const e = {
      type,
      target: {
        closest: (sel) =>
          sel === "[data-nav-menu] [role='menuitem']"
            ? { getAttribute: () => id }
            : null,
      },
      prevented: false,
      preventDefault() { this.prevented = true; },
      ...extra,
    };
    (type === "auxclick" ? handlers.auxclick : handlers.click)(e);
    return e;
  };

  // Plain click: delegated, menu closed.
  event("click", "link", {});
  assert.deepEqual(clicks, ["link"]);
  assert.deepEqual(opened, []);

  // Modifier clicks: new tab, no delegation.
  for (const mod of ["ctrlKey", "metaKey", "shiftKey"]) {
    const e = event("click", "link", { [mod]: true });
    assert.equal(e.prevented, true);
  }
  assert.equal(opened.length, 3);
  assert.deepEqual(opened[0], ["/p?tab=l", "_blank", "noopener"]);
  assert.deepEqual(clicks, ["link"]);

  // Middle click.
  event("auxclick", "link", { button: 1 });
  assert.equal(opened.length, 4);
  // Not the middle button: ignored.
  event("auxclick", "link", { button: 2 });
  assert.equal(opened.length, 4);

  // An event tab has no URL: a modifier click is just a click.
  event("click", "event", { ctrlKey: true });
  assert.deepEqual(clicks, ["link", "event"]);
  assert.equal(opened.length, 4);
});
