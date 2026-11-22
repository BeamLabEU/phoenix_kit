"use strict";

// Tests for the NavTabsOverflow hook in priv/static/assets/phoenix_kit_admin.js:
// the pure fitting logic (navTabsHidden, navTabsLayout) and, against a stub DOM,
// the hook's event handlers and sync() (which tabs hide, "⋯", focus). Real
// layout (measured widths, ResizeObserver, how LiveView patches reset classes)
// needs a browser and is not covered here.
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

const admin = (require("../../priv/static/assets/phoenix_kit.js"), require("../../priv/static/assets/phoenix_kit_admin.js"));
if (typeof admin.navTabsHidden !== "function" || !global.window.PhoenixKitAdminHooks.NavTabsOverflow) {
  throw new Error("NavTabsOverflow and navTabsHidden are expected in priv/static/assets/phoenix_kit_admin.js (the hook is an admin hook behind a stub)");
}
const { navTabsHidden } = admin;

test("the hook is registered", () => {
  assert.equal(typeof global.window.PhoenixKitAdminHooks.NavTabsOverflow.mounted, "function");
  assert.equal(typeof global.window.PhoenixKitAdminHooks.NavTabsOverflow.updated, "function");
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

  const hook = Object.assign(Object.create(global.window.PhoenixKitAdminHooks.NavTabsOverflow), { el });
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
  const hook = Object.assign(Object.create(global.window.PhoenixKitAdminHooks.NavTabsOverflow), { el });
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
  const hook = Object.assign(Object.create(global.window.PhoenixKitAdminHooks.NavTabsOverflow), { el });
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

// Escape with the menu open closes the menu and nothing else: the key must not
// fall through to a native <dialog>'s cancel or a `phx-window-keydown` modal
// around the strip. With the menu closed, Escape is left alone.
test("Escape on an open menu is consumed so it does not close a surrounding dialog", () => {
  global.MutationObserver = class { observe() {} takeRecords() { return []; } disconnect() {} };

  const docHandlers = {};
  const realAdd = global.document.addEventListener;
  global.document.addEventListener = (type, fn) => { docHandlers[type] = fn; };

  const more = { focused: false, focus() { this.focused = true; } };
  const el = {
    addEventListener: noop,
    removeEventListener: noop,
    contains: () => true,
    querySelector: (sel) => (sel === "[data-nav-more]" ? more : null),
    querySelectorAll: () => [],
  };

  try {
    const hook = Object.assign(Object.create(global.window.PhoenixKitAdminHooks.NavTabsOverflow), { el });
    hook.mounted();
    const states = [];
    hook.setOpen = function(open) { this._open = open; states.push(open); };

    const escape = () => ({
      key: "Escape",
      prevented: false,
      stopped: false,
      preventDefault() { this.prevented = true; },
      stopPropagation() { this.stopped = true; },
    });

    // Closed: not ours to swallow.
    const closed = escape();
    docHandlers.keydown(closed);
    assert.equal(closed.prevented, false);
    assert.equal(closed.stopped, false);
    assert.deepEqual(states, []);

    hook._open = true;
    const open = escape();
    docHandlers.keydown(open);
    assert.equal(open.prevented, true);
    assert.equal(open.stopped, true);
    assert.deepEqual(states, [false]);
    assert.equal(more.focused, true);
  } finally {
    global.document.addEventListener = realAdd;
  }
});

// navTabsLayout: the same fitting with tabs the caller keeps in the menu
// (`in_menu`). Arguments: widths, gap, avail, the "⋯" button's width, the
// active index, and which tabs are forced into the menu.
const { navTabsLayout } = admin;

test("layout: with nothing forced and everything fitting, nothing hides", () => {
  assert.deepEqual(navTabsLayout([100, 100, 100], 0, 300, 44, 0, [false, false, false]), [false, false, false]);
});

test("layout: with nothing forced it is navTabsHidden beside the button", () => {
  assert.deepEqual(
    navTabsLayout([100, 100, 100, 100], 0, 350, 50, 0, [false, false, false, false]),
    navTabsHidden([100, 100, 100, 100], 0, 300, 0)
  );
});

test("layout: a forced tab hides however much room there is", () => {
  assert.deepEqual(navTabsLayout([100, 0, 100], 0, 1000, 44, 0, [false, true, false]), [false, true, false]);
});

test("layout: a forced tab's width is ignored", () => {
  // 100 + 100 + the 44 button = 244 fits in 244 even though the forced tab reports 500.
  assert.deepEqual(navTabsLayout([100, 500, 100], 0, 244, 44, 0, [false, true, false]), [false, true, false]);
});

test("layout: the others must fit beside the button once a tab is forced", () => {
  // Without a forced tab 300 fits in 300; with one the button takes 44.
  assert.deepEqual(navTabsLayout([100, 100, 100], 0, 300, 44, 0, [false, false, false]), [false, false, false]);
  assert.deepEqual(navTabsLayout([100, 100, 100, 0], 0, 300, 44, 0, [false, false, false, true]), [false, false, true, true]);
});

test("layout: the active index is mapped past forced tabs", () => {
  // Tab 3 is active and last among the free ones: room is reserved for it.
  assert.deepEqual(
    navTabsLayout([100, 0, 100, 100], 0, 250, 50, 3, [false, true, false, false]),
    [false, true, true, false]
  );
});

test("layout: every tab forced leaves an empty strip", () => {
  assert.deepEqual(navTabsLayout([0, 0], 0, 300, 44, -1, [true, true]), [true, true]);
});

// A layout test with a non-zero gap, at the exact boundary: tabs [100, 100] and a
// forced one need 100 + 10 + 100 for the tabs, a gap and the 44px button = 264.
// Dropping `- gap` from the room beside the button, or the `gap * (n - 1)` term
// from the tabs' total, moves that boundary and fails one of the two.
test("layout: with a gap, forced tabs fit exactly at the boundary and hide one pixel below", () => {
  const widths = [100, 100, 0];
  const forced = [false, false, true];
  assert.deepEqual(navTabsLayout(widths, 10, 264, 44, -1, forced), [false, false, true]);
  assert.deepEqual(navTabsLayout(widths, 10, 263, 44, -1, forced), [false, true, true]);
});

test("layout: with a gap and nothing forced, the row fits exactly at the boundary and hides one pixel below", () => {
  // 3 tabs and 2 gaps = 320; beside the button, the room for tabs is avail - 44 - 10.
  const widths = [100, 100, 100];
  const forced = [false, false, false];
  assert.deepEqual(navTabsLayout(widths, 10, 320, 44, -1, forced), [false, false, false]);
  assert.deepEqual(navTabsLayout(widths, 10, 319, 44, -1, forced), [false, false, true]);
});

// sync() against a stub DOM. A strip of tabs with fixed natural widths: an
// element measures 0 while it has the `hidden` class, as in a browser, so the
// hook has to unhide the tabs it measures and the "⋯" button it measures.
function syncFixture({ widths, forced = [], active = -1, hiddenAtStart = [], width, gap = 0, moreWidth = 44, trailing = 0 }) {
  const classes = (initial) => {
    const set = new Set(initial);
    return {
      set,
      add: (c) => set.add(c),
      remove: (c) => set.delete(c),
      toggle: (c, on) => { if (on === undefined ? !set.has(c) : on) set.add(c); else set.delete(c); },
      contains: (c) => set.has(c),
    };
  };
  const node = (id, natural, extra) => {
    const cls = classes(extra.hidden ? ["hidden"] : []);
    return {
      id,
      classList: cls,
      attrs: extra.attrs || {},
      style: {},
      focused: 0,
      hasAttribute(n) { return n in this.attrs; },
      getAttribute(n) { return n in this.attrs ? this.attrs[n] : null; },
      setAttribute(n, v) { this.attrs[n] = v; },
      getBoundingClientRect: () => ({ width: cls.contains("hidden") ? 0 : natural, right: 0, bottom: 0, left: 0, top: 0 }),
      focus() { this.focused += 1; global.document.activeElement = this; },
      click() {},
    };
  };
  const tabs = widths.map((w, i) => {
    const attrs = { "data-nav-tab": String(i) };
    if (forced[i]) attrs["data-nav-in-menu"] = "";
    if (i === active) attrs["data-nav-active"] = "";
    return node(i, w, { attrs, hidden: hiddenAtStart[i] || forced[i] });
  });
  const items = widths.map((_w, i) => node(`item${i}`, 40, { attrs: { "data-nav-item": String(i) }, hidden: !forced[i] }));
  const more = node("more", moreWidth, { hidden: !forced.some(Boolean) });
  const trail = trailing ? node("trail", trailing, {}) : null;
  const menu = node("menu", 100, { hidden: true });
  menu.querySelectorAll = () => items;
  const strip = node("strip", 0, {});
  strip.clientWidth = width;
  strip.querySelectorAll = (sel) => (sel === "[data-nav-tab]" ? tabs : []);
  strip.querySelector = (sel) => (sel === "[data-nav-trailing]" ? trail : null);
  const el = {
    querySelector: (sel) =>
      ({ "[data-nav-strip]": strip, "[data-nav-more]": more, "[data-nav-menu]": menu })[sel] || null,
    querySelectorAll: (sel) => (sel === "[data-nav-strip] [data-nav-tab]" ? tabs : []),
    contains: () => true,
  };
  global.window.getComputedStyle = () => ({ columnGap: `${gap}px`, paddingLeft: "0px", paddingRight: "0px" });
  const hook = Object.assign(Object.create(global.window.PhoenixKitAdminHooks.NavTabsOverflow), {
    el,
    _open: false,
    _mutations: { takeRecords: () => [] },
  });
  const hiddenTabs = () => tabs.map((t) => t.classList.contains("hidden"));
  const shownItems = () => items.map((i) => !i.classList.contains("hidden"));
  return { hook, tabs, items, more, hiddenTabs, shownItems, moreHidden: () => more.classList.contains("hidden") };
}

test("sync: tabs that fit stay in the strip; the button and the menu items stay hidden", () => {
  const f = syncFixture({ widths: [100, 100, 100], width: 300 });
  f.hook.sync();
  assert.deepEqual(f.hiddenTabs(), [false, false, false]);
  assert.deepEqual(f.shownItems(), [false, false, false]);
  assert.equal(f.moreHidden(), true);
  assert.equal(f.tabs[0].style.flexShrink, "", "the temporary freeze is lifted");
});

test("sync: tabs that do not fit move to the menu beside the button, which is measured while hidden", () => {
  // 4 x 100 do not fit in 250; with the 44px button two do (206 of room).
  const f = syncFixture({ widths: [100, 100, 100, 100], width: 250 });
  f.hook.sync();
  assert.deepEqual(f.hiddenTabs(), [false, false, true, true]);
  assert.deepEqual(f.shownItems(), [false, false, true, true]);
  assert.equal(f.moreHidden(), false);
});

test("sync: a forced tab is in the menu whatever the room, and the button is shown", () => {
  const f = syncFixture({ widths: [100, 100, 100], forced: [false, true, false], width: 1000 });
  f.hook.sync();
  assert.deepEqual(f.hiddenTabs(), [false, true, false]);
  assert.deepEqual(f.shownItems(), [false, true, false]);
  assert.equal(f.moreHidden(), false);
});

test("sync: a forced tab that is the active one stays in the strip, and with no other the button hides", () => {
  const f = syncFixture({ widths: [100, 100], forced: [false, true], active: 1, width: 1000, hiddenAtStart: [false, true] });
  f.hook.sync();
  assert.deepEqual(f.hiddenTabs(), [false, false]);
  assert.deepEqual(f.shownItems(), [false, false]);
  assert.equal(f.moreHidden(), true);
});

test("sync: a forced tab that is the active one is exempt while another forced tab keeps the button", () => {
  const f = syncFixture({ widths: [100, 100, 100], forced: [false, true, true], active: 1, width: 1000, hiddenAtStart: [false, true, true] });
  f.hook.sync();
  assert.deepEqual(f.hiddenTabs(), [false, false, true]);
  assert.deepEqual(f.shownItems(), [false, false, true]);
  assert.equal(f.moreHidden(), false);
});

test("sync: every tab forced leaves an empty strip and the button", () => {
  const f = syncFixture({ widths: [100, 100], forced: [true, true], width: 1000 });
  f.hook.sync();
  assert.deepEqual(f.hiddenTabs(), [true, true]);
  assert.deepEqual(f.shownItems(), [true, true]);
  assert.equal(f.moreHidden(), false);
});

test("sync: a strip that is not laid out (zero width) hides only the forced tabs", () => {
  const f = syncFixture({ widths: [100, 100, 100], forced: [false, true, false], width: 0 });
  f.hook.sync();
  assert.deepEqual(f.hiddenTabs(), [false, true, false]);
  assert.deepEqual(f.shownItems(), [false, true, false]);
  assert.equal(f.moreHidden(), false);

  const plain = syncFixture({ widths: [100, 100, 100], width: 0 });
  plain.hook.sync();
  assert.deepEqual(plain.hiddenTabs(), [false, false, false]);
  assert.equal(plain.moreHidden(), true);
});

test("sync: the exact boundary, with a forced tab, a gap and a trailing slot", () => {
  // Tabs 100 + 10 + 100, a gap and the 44px button: 264; the trailing slot of 50
  // and its gap take 60 more.
  const fits = syncFixture({ widths: [100, 100, 0], forced: [false, false, true], width: 324, gap: 10, trailing: 50 });
  fits.hook.sync();
  assert.deepEqual(fits.hiddenTabs(), [false, false, true]);

  const tight = syncFixture({ widths: [100, 100, 0], forced: [false, false, true], width: 323, gap: 10, trailing: 50 });
  tight.hook.sync();
  assert.deepEqual(tight.hiddenTabs(), [false, true, true]);
  assert.deepEqual(tight.shownItems(), [false, true, true]);
});

test("sync: tabs hidden by an earlier pass are measured again once there is room", () => {
  const f = syncFixture({ widths: [100, 100, 100], width: 300, hiddenAtStart: [false, true, true] });
  f.hook.sync();
  assert.deepEqual(f.hiddenTabs(), [false, false, false]);
});

// Picking a menu item moves focus to "⋯" and clicks the strip tab. When that tab
// was the last one kept in the menu, it becomes the active tab, "⋯" hides, and
// focus would fall to <body>: it must land on the active strip tab instead.
test("focus: when picking the last menu tab hides the button, focus lands on that strip tab", () => {
  const realActive = global.document.activeElement;
  try {
    const f = syncFixture({ widths: [100, 100], forced: [false, true], active: 0, width: 1000 });
    // The click is answered the way a LiveView patch answers it: tab 1 is now active.
    f.tabs[1].click = () => {
      delete f.tabs[0].attrs["data-nav-active"];
      f.tabs[1].attrs["data-nav-active"] = "";
    };
    f.hook.sync();
    assert.equal(f.moreHidden(), false);

    f.hook.pick(
      { type: "click" },
      { closest: () => ({ getAttribute: () => "1" }) }
    );
    assert.equal(global.document.activeElement, f.more, "focus waits on the button until the patch arrives");

    f.hook.sync();
    assert.equal(f.moreHidden(), true);
    assert.equal(global.document.activeElement, f.tabs[1]);
    assert.equal(f.tabs[1].focused, 1);
  } finally {
    global.document.activeElement = realActive;
  }
});

test("focus: it is moved only when it was on the button and the button hides", () => {
  const realActive = global.document.activeElement;
  try {
    // The button stays (another tab is still in the menu): focus is left alone.
    const staying = syncFixture({ widths: [100, 100, 100], forced: [false, true, true], active: 0, width: 1000 });
    global.document.activeElement = staying.more;
    staying.hook.sync();
    assert.equal(staying.moreHidden(), false);
    assert.equal(staying.tabs[0].focused, 0);

    // The button hides, but focus was elsewhere: it is not stolen.
    const elsewhere = syncFixture({ widths: [100, 100], forced: [false, true], active: 1, width: 1000 });
    const other = { focus() {} };
    global.document.activeElement = other;
    elsewhere.hook.sync();
    assert.equal(elsewhere.moreHidden(), true);
    assert.equal(elsewhere.tabs[1].focused, 0);
    assert.equal(global.document.activeElement, other);
  } finally {
    global.document.activeElement = realActive;
  }
});
