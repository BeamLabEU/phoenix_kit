"use strict";

// The person card (priv/static/assets/phoenix_kit.js, "PERSON CARD"): a click
// on a chip opens that person's card next to it; an element listing several
// people opens the side drawer with every card; a card that cannot be loaded
// says so and the page never navigates away (Max, 2026-11-25).
//
// Run: mix test.js  (node --test needs the explicit file on Node 25)

const test = require("node:test");
const assert = require("node:assert/strict");

const noop = () => {};
const created = [];

// An element whose descendants are made on demand: the bundle builds its
// dialogs from innerHTML and then asks for parts by selector.
function el(tag) {
  const parts = {};
  const node = {
    tagName: String(tag || "div").toUpperCase(),
    style: {},
    dataset: {},
    attrs: {},
    children: [],
    innerHTML: "",
    textContent: "",
    isConnected: true,
    open: false,
    offsetWidth: 288,
    offsetHeight: 120,
    classList: { add: noop, remove: noop, toggle: noop, contains: () => false },
    setAttribute(k, v) { this.attrs[k] = String(v); },
    getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; },
    removeAttribute(k) { delete this.attrs[k]; },
    appendChild(c) { this.children.push(c); return c; },
    remove() { this.isConnected = false; },
    addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); },
    removeEventListener: noop,
    listeners: {},
    querySelector(sel) { return (parts[sel] = parts[sel] || el("div")); },
    querySelectorAll: () => [],
    contains: () => false,
    focus: noop,
    showModal() { this.open = true; },
    close() {
      this.open = false;
      (this.listeners.close || []).forEach((fn) => fn({}));
    },
  };
  created.push(node);
  return node;
}

const docListeners = [];
const keyListeners = [];
const scrollListeners = [];

global.document = {
  documentElement: { getAttribute: (k) => (k === "lang" ? "et" : null) },
  head: el("head"),
  body: el("body"),
  createElement: el,
  createTextNode: () => ({}),
  getElementById: () => null,
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener(type, fn, capture) {
    if (type === "click" && capture === true) docListeners.push(fn);
    if (type === "keydown" && capture === true) keyListeners.push(fn);
    if (type === "scroll" && capture && capture.capture === true) scrollListeners.push(fn);
  },
  removeEventListener: noop,
  readyState: "complete",
};

const storage = { getItem: () => null, setItem: noop, removeItem: noop, key: () => null, length: 0 };
const navigations = [];
const fetched = [];
let answer = () => Promise.resolve({ ok: true, text: () => Promise.resolve("<p>card</p>") });

global.window = {
  PhoenixKitHooks: {},
  addEventListener: noop,
  removeEventListener: noop,
  matchMedia: () => ({ matches: false, addEventListener: noop, removeEventListener: noop }),
  localStorage: storage,
  sessionStorage: storage,
  location: { href: "http://localhost/", reload: noop, assign: (u) => navigations.push(u) },
  navigator: { userAgent: "node" },
  document: global.document,
  innerWidth: 1280,
  innerHeight: 800,
  setTimeout,
  clearTimeout,
};
global.localStorage = storage;
global.sessionStorage = storage;
global.fetch = (url, opts) => {
  fetched.push(url);
  return answer(url, opts);
};

require("../../priv/static/assets/phoenix_kit.js");

const flush = () => new Promise((r) => setTimeout(r, 0));

// A click on `target`, which answers `closest` from `matches`.
function click(matches, extra) {
  const ev = Object.assign(
    {
      button: 0,
      defaultPrevented: false,
      prevented: false,
      target: { closest: (sel) => matches[sel] || null },
      preventDefault() { this.prevented = true; },
      stopPropagation: noop,
    },
    extra || {}
  );
  docListeners.forEach((fn) => fn(ev));
  return ev;
}

function chip(uuid, attrs) {
  const c = el("a");
  c.attrs = Object.assign({ "data-mention-user": uuid }, attrs || {});
  c.getBoundingClientRect = () => ({ top: 100, bottom: 124, left: 200, right: 260 });
  return c;
}

function lastDialog(className) {
  return created.filter((n) => n.className === className).pop();
}

test("a chip opens the person's card, in the page's language, without navigating", async () => {
  const c = chip("u-1", { href: "/admin/users/view/u-1" });
  const ev = click({ "[data-mention-user]": c });
  assert.equal(ev.prevented, true);
  assert.match(fetched.pop(), /\/phoenix_kit\/people\/u-1\/card\?lang=et$/);

  const pop = lastDialog("pk-person-pop");
  assert.equal(pop.open, true);
  await flush();
  await flush();
  assert.equal(pop.querySelector("[data-pk-pop-body]").innerHTML, "<p>card</p>");
  // Placed next to the chip: below it, from its left edge.
  assert.equal(pop.style.top, "130px");
  assert.equal(pop.style.left, "200px");
  assert.deepEqual(navigations, []);
});

test("a card that cannot be loaded says so, in the chip's words, and never navigates", async () => {
  answer = () => Promise.resolve({ ok: false, text: () => Promise.resolve("") });
  const c = chip("u-2", { href: "/admin/users/view/u-2", "data-card-error": "Isikut ei saanud laadida." });
  click({ "[data-mention-user]": c });
  await flush();
  await flush();

  const body = lastDialog("pk-person-pop").querySelector("[data-pk-pop-body]");
  const box = body.children[body.children.length - 1];
  assert.equal(box.children[0].textContent, "Isikut ei saanud laadida.");
  // The profile link only because the chip had one, and it is same-site.
  assert.equal(box.children[1].href, "/admin/users/view/u-2");
  assert.deepEqual(navigations, []);
  answer = () => Promise.resolve({ ok: true, text: () => Promise.resolve("<p>card</p>") });
});

test("a failed card omits a profile link outside the current origin", async () => {
  const prev = answer;
  answer = () => Promise.resolve({ ok: false });
  try {
    for (const href of ["//example.org", "/\\example.org", "/\t/example.org"]) {
      click({ "[data-mention-user]": chip("u-2", { href }) });
      await flush();
      const body = lastDialog("pk-person-pop").querySelector("[data-pk-pop-body]");
      assert.equal(body.children.at(-1).children.length, 1);
    }
  } finally {
    answer = prev;
  }
});

test("several people open the drawer with every card, each person once", async () => {
  const group = el("span");
  group.attrs = { "data-people": "a-1, a-2,a-1" };
  fetched.length = 0;
  const ev = click({ "[data-people]": group });
  assert.equal(ev.prevented, true);
  assert.equal(lastDialog("modal modal-end pk-person-drawer").open, true);
  assert.equal(fetched.length, 2);
  assert.match(fetched[0], /\/people\/a-1\/card/);
  assert.match(fetched[1], /\/people\/a-2\/card/);
});

test("a modifier click follows the chip's link; a chip inside an editor is the editor's", () => {
  fetched.length = 0;
  const c = chip("u-3");
  assert.equal(click({ "[data-mention-user]": c }, { metaKey: true }).prevented, false);
  const editor = el("div");
  const inEditor = click({
    "[data-mention-user]": c,
    "[contenteditable]:not([contenteditable='false']), textarea": editor,
  });
  assert.equal(inEditor.prevented, false);
  assert.equal(fetched.length, 0);
});

test("a chip that is not a link opens on Enter and Space, like a button", async () => {
  fetched.length = 0;
  const span = el("span");
  span.attrs = { "data-mention-user": "k-1", role: "button", tabindex: "0" };
  span.closest = () => null;
  span.getBoundingClientRect = () => ({ top: 100, bottom: 124, left: 200, right: 260 });

  for (const key of ["Enter", " "]) {
    const ev = { key, target: span, prevented: false, preventDefault() { this.prevented = true; } };
    keyListeners.forEach((fn) => fn(ev));
    assert.equal(ev.prevented, true, key);
  }
  assert.equal(fetched.filter((u) => /\/people\/k-1\/card/.test(u)).length, 2);

  // Another key, or a link (whose Enter is already a click), does nothing here.
  const other = { key: "a", target: span, prevented: false, preventDefault() { this.prevented = true; } };
  keyListeners.forEach((fn) => fn(other));
  assert.equal(other.prevented, false);
});

test("a close event that arrives after the card reopened does not empty it", async () => {
  const c = chip("r-1", { href: "/admin/users/view/r-1" });
  click({ "[data-mention-user]": c });
  await flush();
  await flush();
  const pop = lastDialog("pk-person-pop");
  const body = pop.querySelector("[data-pk-pop-body]");
  assert.equal(body.innerHTML, "<p>card</p>");

  // The previous opening's queued close fires while the card is open again.
  assert.equal(pop.open, true);
  (pop.listeners.close || []).forEach((fn) => fn({}));
  assert.equal(body.innerHTML, "<p>card</p>");
});

test("the openers survive the rest of the file: PhoenixKitInternals is merged, not replaced", () => {
  const internals = global.window.PhoenixKitInternals;
  assert.equal(typeof internals.openPersonCard, "function");
  assert.equal(typeof internals.openPeopleDrawer, "function");
  assert.equal(typeof internals.openPersonDrawer, "function");
  // …and the admin file's own entries, set later in the same file.
  assert.ok(Array.isArray(internals.adminHookNames));
});

test("under 640 px the card is a sheet as wide as the screen", async () => {
  global.window.innerWidth = 500;
  try {
    const c = chip("n-1");
    click({ "[data-mention-user]": c });
    const pop = lastDialog("pk-person-pop");
    assert.equal(pop.style.width, "calc(100vw - 1rem)");
    assert.equal(pop.style.bottom, "0.5rem");
  } finally {
    global.window.innerWidth = 1280;
  }
  // Back on a wide screen the explicit width goes again.
  const c2 = chip("n-2");
  click({ "[data-mention-user]": c2 });
  assert.equal(lastDialog("pk-person-pop").style.width, "");
});

test("the card follows its chip on scroll and closes when the chip leaves the view", async () => {
  const c = chip("s-1", { href: "/admin/users/view/s-1" });
  click({ "[data-mention-user]": c });
  const pop = lastDialog("pk-person-pop");
  assert.ok(scrollListeners.length > 0);

  // The chip's container scrolled: the card moves with it.
  c.getBoundingClientRect = () => ({ top: 300, bottom: 324, left: 200, right: 260 });
  scrollListeners.forEach((fn) => fn({}));
  assert.equal(pop.style.top, "330px");
  assert.equal(pop.open, true);

  // Scrolled out of view: closed.
  c.getBoundingClientRect = () => ({ top: -80, bottom: -56, left: 200, right: 260 });
  scrollListeners.forEach((fn) => fn({}));
  assert.equal(pop.open, false);
});
