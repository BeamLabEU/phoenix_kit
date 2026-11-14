"use strict";

// Unit tests for RowMenu's right-click path in
// priv/static/assets/phoenix_kit_admin.js. A row flagged `data-row-menu-context`
// opens the ⋮ menu rendered INSIDE it, at the pointer. The hook is driven for
// real here — the document listener it installs is captured and invoked, and
// the hook's own `_open` positions a stub menu — so a change to either would
// fail rather than be re-implemented by the test.
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

// Listeners the bundle installs on `document`, so the test can fire the real
// handler instead of a copy of it.
const docListeners = {};
// Rows on the "page", keyed by the name the fixtures use for them.
const rows = {};

global.document = {
  documentElement: stubElement(),
  head: stubElement(),
  body: Object.assign(stubElement(), { appendChild: noop }),
  createElement: stubElement,
  createTextNode: () => ({}),
  getElementById: () => null,
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener: (type, fn) => {
    (docListeners[type] = docListeners[type] || []).push(fn);
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

global.window = {
  PhoenixKitAdminHooks: {},
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

(require("../../priv/static/assets/phoenix_kit.js"), require("../../priv/static/assets/phoenix_kit_admin.js"));
const RowMenu = global.window.PhoenixKitAdminHooks.RowMenu;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

// A mounted row menu inside a right-clickable row: the row, the wrapper the
// hook binds to, its trigger and its floating <ul>. `menuSize` is what the
// <ul> measures once un-hidden.
function mountMenu(id, menuSize = { w: 200, h: 300 }) {
  const trigger = Object.assign(stubElement(), {
    getBoundingClientRect: () => ({ top: 10, bottom: 34, left: 900, right: 940 }),
    focus: noop,
  });

  const menu = Object.assign(stubElement(), {
    style: {},
    offsetWidth: menuSize.w,
    offsetHeight: menuSize.h,
    parentNode: null,
    contains: () => false,
    hidden: true,
    classList: {
      add: () => {
        menu.hidden = true;
      },
      remove: () => {
        menu.hidden = false;
      },
      toggle: noop,
      contains: () => false,
    },
  });

  // The row the user right-clicks. `closest` walks up from anything inside
  // it; `querySelectorAll` finds the menu wrapper it contains.
  const row = Object.assign(stubElement(), {
    querySelectorAll: (sel) => (sel === "[data-row-menu-wrapper]" ? [wrapper] : []),
  });

  const wrapper = Object.assign(stubElement(), {
    id: id,
    contains: () => false,
    closest: (sel) => (sel === "[data-row-menu-context]" ? row : null),
    querySelector: (sel) => {
      if (sel === "[data-row-menu-trigger]") return trigger;
      if (sel === "[data-row-menu-content]") return menu;
      return null;
    },
  });

  const hook = Object.create(RowMenu);
  hook.el = wrapper;
  hook.mounted();

  rows[id] = row;
  return { hook, row, wrapper, trigger, menu };
}

// A right-click whose target sits inside the row named `menuId`
// (`null` = a click on something that is not a right-clickable row at all).
function contextEvent(menuId, x = 100, y = 100) {
  const row = menuId === null ? null : rows[menuId] || unknownRow();
  return {
    clientX: x,
    clientY: y,
    prevented: false,
    preventDefault() {
      this.prevented = true;
    },
    target: { closest: (sel) => (sel === "[data-row-menu-context]" ? row : null) },
  };
}

// The same right-click, but landing on a text field inside the row.
function contextEventOnField(menuId) {
  const e = contextEvent(menuId);
  const row = rows[menuId];
  e.target = {
    closest: (sel) => {
      if (sel.startsWith("input, textarea, select")) return {}; // the field itself
      if (sel === "[data-row-menu-context]") return row;
      return null;
    },
  };
  return e;
}

// A flagged row whose menu is not in the DOM — the view mode renders the row
// but puts its menu behind an `:if`.
function unknownRow() {
  return Object.assign(stubElement(), { querySelectorAll: () => [] });
}

function fireContextMenu(event) {
  docListeners.contextmenu.forEach((fn) => fn(event));
  return event;
}

// ---------------------------------------------------------------------------

test("mounting a row menu installs exactly one document contextmenu listener", () => {
  mountMenu("menu-a");
  assert.equal(docListeners.contextmenu.length, 1);

  // A table of a hundred rows must not add a hundred listeners.
  mountMenu("menu-b");
  mountMenu("menu-c");
  assert.equal(docListeners.contextmenu.length, 1);
});

test("a right-click on a row opens that row's own menu at the pointer", () => {
  const { hook, menu } = mountMenu("menu-open");

  const e = fireContextMenu(contextEvent("menu-open", 120, 140));

  assert.equal(e.prevented, true, "the browser's own menu is suppressed on a row");
  assert.equal(hook.isOpen, true);
  // Down-right of the pointer — NOT beside the trigger, which this fixture
  // puts at x≈900, far to the right of the click.
  assert.equal(menu.style.left, "120px");
  assert.equal(menu.style.top, "140px");
  hook._close();
});

test("the pointer position is the shared rule, flips and all", () => {
  const { hook, menu } = mountMenu("menu-flip");

  // 950 + 200 > 1000 and 780 + 300 > 800, so both axes flip to the other
  // side of the pointer. Same arithmetic Core.ContextMenu uses.
  fireContextMenu(contextEvent("menu-flip", 950, 780));
  assert.equal(menu.style.left, "750px");
  assert.equal(menu.style.top, "480px");
  hook._close();
});

test("the ⋮ trigger still opens beside the trigger, not at a pointer", () => {
  const { hook, menu } = mountMenu("menu-trigger");

  hook._open();

  // trigger.right 940 - width 200 = 740; below its bottom edge + 4px gap.
  assert.equal(menu.style.left, "740px");
  assert.equal(menu.style.top, "38px");
  hook._close();
});

test("a right-click off any row leaves the browser's own menu alone", () => {
  const e = fireContextMenu(contextEvent(null));
  assert.equal(e.prevented, false);
});

test("a right-click in a text field inside the row keeps the browser's menu", () => {
  // The inline folder-rename box sits inside a right-clickable row. A
  // right-click there is a request to paste, not for the row's actions.
  const { hook } = mountMenu("row-with-field");
  const e = fireContextMenu(contextEventOnField("row-with-field"));
  assert.equal(e.prevented, false);
  assert.equal(hook.isOpen, false);
});

test("a flagged row holding no menu leaves the native menu alone", () => {
  // The view mode can render a row whose menu is behind an `:if` — the trash
  // view's rows, say. Suppressing the browser menu with nothing to put in its
  // place would cost the user Copy and Inspect for no gain.
  const e = fireContextMenu(contextEvent("row-with-no-menu"));
  assert.equal(e.prevented, false);
});

test("a wrapper with no mounted hook leaves the native menu alone", () => {
  const bare = stubElement();
  const row = Object.assign(stubElement(), {
    querySelectorAll: (sel) => (sel === "[data-row-menu-wrapper]" ? [bare] : []),
  });
  bare.closest = (sel) => (sel === "[data-row-menu-context]" ? row : null);
  rows["row-unmounted"] = row;

  const e = fireContextMenu(contextEvent("row-unmounted"));
  assert.equal(e.prevented, false);
});

test("a nested row's menu is not opened by a right-click on its parent", () => {
  // `closest` picks the innermost flagged row; a wrapper that answers to a
  // DIFFERENT row belongs to that row, not this one.
  const inner = mountMenu("row-inner");
  const outerRow = Object.assign(stubElement(), {
    querySelectorAll: (sel) =>
      sel === "[data-row-menu-wrapper]" ? [inner.wrapper] : [],
  });
  rows["row-outer"] = outerRow;

  const e = fireContextMenu(contextEvent("row-outer"));
  assert.equal(e.prevented, false);
  assert.equal(inner.hook.isOpen, false);
});

test("right-clicking a second row closes the first row's menu", () => {
  const first = mountMenu("menu-first");
  const second = mountMenu("menu-second");

  fireContextMenu(contextEvent("menu-first"));
  assert.equal(first.hook.isOpen, true);

  fireContextMenu(contextEvent("menu-second"));
  assert.equal(first.hook.isOpen, false, "two menus must never be open at once");
  assert.equal(second.hook.isOpen, true);
  second.hook._close();
});

test("the hook is reachable through a property, not an attribute", () => {
  // LiveView's patcher strips attributes the server did not render, so the
  // back-reference a right-click follows cannot be one.
  const { hook, wrapper } = mountMenu("menu-prop");
  assert.equal(wrapper._pkRowMenu, hook);

  // A re-render hands the wrapper back; `updated()` re-publishes it.
  wrapper._pkRowMenu = null;
  hook.updated();
  assert.equal(wrapper._pkRowMenu, hook);
});

test("a destroyed row stops answering right-clicks", () => {
  const { hook, wrapper } = mountMenu("row-gone");
  hook.destroyed();
  assert.equal(wrapper._pkRowMenu, null);

  const e = fireContextMenu(contextEvent("row-gone"));
  assert.equal(e.prevented, false);
});

// ---------------------------------------------------------------------------
// Found by the review panel (codex + grok), 2026-09-21
// ---------------------------------------------------------------------------

function fireDoc(type, event) {
  (docListeners[type] || []).forEach((fn) => fn(event));
  return event;
}

function clickEvent() {
  return {
    prevented: false,
    stoppedImmediate: false,
    target: {},
    preventDefault() {
      this.prevented = true;
    },
    stopImmediatePropagation() {
      this.stoppedImmediate = true;
    },
  };
}

test("after a touch long-press, the release click is swallowed", () => {
  // Android: long press → `contextmenu`, then the release dispatches a click
  // on the row's link or the ⋮ trigger. Unswallowed, it navigates away or
  // toggles the menu shut the moment it opened.
  const { hook } = mountMenu("row-touch");
  fireDoc("pointerdown", { pointerType: "touch" });
  fireContextMenu(contextEvent("row-touch"));
  assert.equal(hook.isOpen, true);

  const release = fireDoc("click", clickEvent());
  assert.equal(release.prevented, true);
  assert.equal(release.stoppedImmediate, true, "the menu's own outside-click must not see it");

  // Exactly one: the tap after it is the user's.
  const next = fireDoc("click", clickEvent());
  assert.equal(next.prevented, false);
  hook._close();
});

test("a mouse right-click arms no swallow", () => {
  const { hook } = mountMenu("row-mouse");
  fireDoc("pointerdown", { pointerType: "mouse" });
  fireContextMenu(contextEvent("row-mouse"));

  const next = fireDoc("click", clickEvent());
  assert.equal(next.prevented, false);
  hook._close();
});

test("text selected inside the row keeps the browser's menu, for Copy", () => {
  const { hook, row } = mountMenu("row-selected");
  const selectedText = {};
  row.contains = (n) => n === selectedText;
  global.window.getSelection = () => ({
    isCollapsed: false,
    toString: () => "SKU-123",
    anchorNode: selectedText,
    focusNode: selectedText,
  });

  try {
    const e = fireContextMenu(contextEvent("row-selected"));
    assert.equal(e.prevented, false);
    assert.equal(hook.isOpen, false);
  } finally {
    delete global.window.getSelection;
  }
});

test("a keyboard context menu (0,0) opens beside the ⋮ trigger, not in the corner", () => {
  const { hook, menu } = mountMenu("row-keyboard");
  fireContextMenu(contextEvent("row-keyboard", 0, 0));

  // Same place the trigger path puts it (see the ⋮ trigger test above).
  assert.equal(menu.style.left, "740px");
  assert.equal(menu.style.top, "38px");
  hook._close();
});

test("a right-click off every row closes an open menu instead of leaving it under the browser's", () => {
  const { hook } = mountMenu("row-then-elsewhere");
  fireContextMenu(contextEvent("row-then-elsewhere"));
  assert.equal(hook.isOpen, true);

  const e = fireContextMenu(contextEvent(null));
  assert.equal(e.prevented, false);
  assert.equal(hook.isOpen, false);
});

test("a right-click ON the open menu keeps it open, for a link's native menu", () => {
  const { hook, menu } = mountMenu("row-then-menu");
  fireContextMenu(contextEvent("row-then-menu"));

  const onItem = { closest: () => null };
  menu.contains = (n) => n === onItem;
  const e = fireContextMenu({ ...contextEvent(null), target: onItem });

  assert.equal(e.prevented, false, "the browser's menu offers Open in new tab");
  assert.equal(hook.isOpen, true);
  hook._close();
});

test("scrolling the page closes the menu rather than leaving it over another row", () => {
  const { hook } = mountMenu("row-scroll");
  fireContextMenu(contextEvent("row-scroll"));

  hook._onScrollClose({ target: global.document });
  assert.equal(hook.isOpen, false);
});

test("a patch while open replaces the menu's items with the fresh ones", () => {
  // The server re-rendered the row: "Retry" is gone now that extraction
  // succeeded. The open menu must stop offering it.
  const { hook, wrapper, menu } = mountMenu("row-patched");
  fireContextMenu(contextEvent("row-patched"));

  const freshItem = { fresh: true };
  const dup = { childNodes: [freshItem], removed: false, remove() { this.removed = true; } };
  wrapper.querySelector = (sel) => (sel === "[data-row-menu-content]" ? dup : null);
  let adopted = null;
  menu.replaceChildren = (...nodes) => {
    adopted = nodes;
  };

  hook.updated();

  assert.deepEqual(adopted, [freshItem]);
  assert.equal(dup.removed, true);
  assert.equal(hook.menu, menu, "the portaled menu stays the one on screen");
  hook._close();
});

test("a patch while open keeps keyboard focus on the item in the same slot", () => {
  // The swap detaches the focused item; without a refocus the next arrow key
  // starts over from the top and Tab walks off into the page.
  const { hook, wrapper, menu } = mountMenu("row-patched-focus");
  fireContextMenu(contextEvent("row-patched-focus"));

  const focused = [];
  const item = (name) => ({ focus: () => focused.push(name) });
  let items = [item("old-edit"), item("old-retry"), item("old-delete")];
  menu.querySelectorAll = () => items;
  global.document.activeElement = items[2];

  // "Retry" is gone, so the third slot no longer exists: focus the last one.
  const freshItems = [item("edit"), item("delete")];
  const dup = { childNodes: freshItems, remove: noop };
  wrapper.querySelector = (sel) => (sel === "[data-row-menu-content]" ? dup : null);
  menu.replaceChildren = (...nodes) => {
    items = nodes;
  };

  hook.updated();

  assert.deepEqual(focused, ["delete"]);
  global.document.activeElement = undefined;
  hook._close();
});
