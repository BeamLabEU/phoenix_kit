"use strict";

// The media browser's removal dialog (RemovalModal hook). It is drawn in the
// top layer (`popover="manual"`, shown by the hook) so it sits above an open
// viewer, and Escape closes THIS dialog only: the key is taken in the capture
// phase of the window and stopped, so neither the viewer's document listener
// nor a host <dialog> sees it.
//
//   node --test test/js/removal_modal.test.cjs

const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const src = fs.readFileSync(
  path.join(__dirname, "..", "..", "priv", "static", "assets", "phoenix_kit_admin.js"),
  "utf8"
);

function load() {
  const start = src.indexOf("  window.PhoenixKitAdminHooks.RemovalModal = {");
  assert.notEqual(start, -1, "could not find RemovalModal");
  const end = src.indexOf("\n  };", start) + "\n  };".length;
  const listeners = [];
  const win = {
    addEventListener: (n, fn, capture) => listeners.push({ n, fn, capture }),
    removeEventListener: (n, fn) => {
      const i = listeners.findIndex((l) => l.n === n && l.fn === fn);
      if (i >= 0) listeners.splice(i, 1);
    },
  };
  const doc = { activeElement: null };
  const hook = new Function(
    "window", "document",
    "window.PhoenixKitAdminHooks = {};" + src.slice(start, end) + "; return window.PhoenixKitAdminHooks.RemovalModal;"
  )(win, doc);
  return { hook, listeners, doc };
}

function el({ popover = true, buttons = 3 } = {}) {
  const kids = Array.from({ length: buttons }, (_, i) => ({ id: "b" + i, focused: 0, disabled: false,
    focus() { kids.active = this; } }));
  const e = {
    kids,
    contains: (n) => kids.includes(n),
    querySelectorAll: () => kids,
    dataset: { token: "tok" },
    shown: 0,
    open: false,
    focused: 0,
    hasAttribute: (n) => n === "popover" && popover,
    matches: (sel) => (sel === ":popover-open" ? e.open : false),
    showPopover: () => { e.shown++; e.open = true; },
    querySelector: () => ({ focus: () => { e.focused++; } }),
  };
  return e;
}

function mount(opts) {
  const env = load();
  const pushed = [];
  const ctx = { el: el(opts), pushEventTo: (_el, event, payload) => pushed.push({ event, payload }) };
  env.hook.mounted.call(ctx);
  return { ...env, ctx, pushed };
}

function key(k, extra) {
  return { key: k, shiftKey: false, prevented: false, stopped: false, ...extra,
    preventDefault() { this.prevented = true; }, stopPropagation() { this.stopped = true; } };
}

test("the dialog is lifted into the top layer, once, and again after a patch", () => {
  const m = mount();
  assert.equal(m.ctx.el.shown, 1);
  m.hook.updated.call(m.ctx);
  assert.equal(m.ctx.el.shown, 1, "already open: not shown twice");
  m.ctx.el.open = false;
  m.hook.updated.call(m.ctx);
  assert.equal(m.ctx.el.shown, 2, "a patch must not leave it hidden");
});

test("focus goes to the cancel button, not a destructive one", () => {
  const m = mount();
  assert.equal(m.ctx.el.focused, 1);
});

test("Escape cancels the dialog and is taken before the page's listeners", () => {
  const m = mount();
  const l = m.listeners.find((x) => x.n === "keydown");
  assert.ok(l, "a keydown listener on the window");
  assert.equal(l.capture, true, "in the capture phase, ahead of the viewer's");

  const e = key("Escape");
  l.fn(e);

  assert.equal(e.prevented, true, "a host dialog gets no cancel");
  assert.equal(e.stopped, true, "the viewer's handler never runs");
  assert.deepEqual(m.pushed, [{ event: "removal_cancel", payload: { token: "tok" } }]);
});

test("other keys are left alone", () => {
  const m = mount();
  const l = m.listeners.find((x) => x.n === "keydown");
  const e = key("a");
  l.fn(e);
  assert.equal(e.prevented, false);
  assert.equal(e.stopped, false);
  assert.deepEqual(m.pushed, []);
});

test("destroyed removes the listener", () => {
  const m = mount();
  m.hook.destroyed.call(m.ctx);
  assert.equal(m.listeners.filter((x) => x.n === "keydown").length, 0);
});

test("a browser without the Popover API keeps the dialog where it is", () => {
  const env = load();
  const e = el();
  e.showPopover = undefined;
  env.hook.mounted.call({ el: e, pushEventTo() {} });
  assert.equal(e.shown, 0);
});

test("Tab goes round the dialog's buttons and never leaves it", () => {
  const m = mount();
  const l = m.listeners.find((x) => x.n === "keydown");
  const [a, b, c] = m.ctx.el.kids;

  m.doc.activeElement = document_outside();
  let e = key("Tab");
  l.fn(e);
  assert.equal(e.prevented, true);
  assert.equal(m.ctx.el.kids.active, a, "from outside: back to the first");

  m.doc.activeElement = c;
  l.fn(key("Tab"));
  assert.equal(m.ctx.el.kids.active, a, "past the last: round to the first");

  m.doc.activeElement = a;
  l.fn(key("Tab", { shiftKey: true }));
  assert.equal(m.ctx.el.kids.active, c, "Shift+Tab before the first: round to the last");

  m.doc.activeElement = a;
  l.fn(key("Tab"));
  assert.equal(m.ctx.el.kids.active, b);
});

function document_outside() { return { id: "outside" }; }

test("the arrows are swallowed, so the viewer under the dialog does not step", () => {
  const m = mount();
  const l = m.listeners.find((x) => x.n === "keydown");
  for (const k of ["ArrowLeft", "ArrowRight"]) {
    const e = key(k);
    l.fn(e);
    assert.equal(e.prevented, true, k);
    assert.equal(e.stopped, true, k);
  }
  assert.deepEqual(m.pushed, []);
});
