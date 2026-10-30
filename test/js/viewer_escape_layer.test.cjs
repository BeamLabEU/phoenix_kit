"use strict";

// The media viewer's Escape closes the viewer and nothing under it. A picker
// is usually opened in a host's modal <dialog>, which takes Escape as its own
// close request: ViewerKeydown cancels the keydown of a picker's viewer (so
// the dialog gets no `cancel`) whenever it is the top layer, and leaves the
// key alone when a dialog was opened over it. Any other viewer leaves the
// key to the page, as before. A picker's viewer carries
// `popover`, and the hook shows it, which lifts it into the top layer, out of
// the reach of the host modal's transformed box.
//
//   node --test test/js/viewer_escape_layer.test.cjs

const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const src = fs.readFileSync(
  path.join(__dirname, "..", "..", "priv", "static", "assets", "phoenix_kit_admin.js"),
  "utf8"
);

function load({ dialogs = [], active = null } = {}) {
  const start = src.indexOf("  window.PhoenixKitAdminHooks.ViewerKeydown = {");
  assert.notEqual(start, -1, "could not find ViewerKeydown");
  const end = src.indexOf("\n  };", start) + "\n  };".length;
  const listeners = {};
  const doc = {
    activeElement: active,
    querySelectorAll: (sel) => (sel === "dialog" ? dialogs : []),
    addEventListener: (n, fn) => ((listeners[n] = listeners[n] || []).push(fn)),
    removeEventListener: (n, fn) => (listeners[n] = (listeners[n] || []).filter((f) => f !== fn)),
  };
  const win = { addEventListener() {}, removeEventListener() {}, dispatchEvent() {} };
  const hook = new Function(
    "window", "document", "Image", "CustomEvent", "navigator",
    "window.PhoenixKitAdminHooks = {};" + src.slice(start, end) + "; return window.PhoenixKitAdminHooks.ViewerKeydown;"
  )(win, doc, function () {}, function (n, o) { this.name = n; this.detail = o && o.detail; }, {});
  return { hook, listeners, doc };
}

// The viewer's modal element; `popover` as the picker renders it.
function viewerEl({ popover = false } = {}) {
  const el = {
    dataset: {},
    shown: 0,
    open: false,
    hasAttribute: (name) => name === "popover" && popover,
    matches: (sel) => (sel === ":popover-open" ? el.open : false),
    showPopover: () => { el.shown++; el.open = true; },
    addEventListener() {},
    removeEventListener() {},
    querySelector: () => null,
  };
  return el;
}

function dialog({ modal = true, holds = null } = {}) {
  return {
    open: modal,
    matches: (sel) => (sel === ":modal" ? modal : false),
    contains: (node) => node === holds,
  };
}

function mount(opts) {
  const env = load(opts);
  const el = opts && opts.el ? opts.el : viewerEl();
  const pushed = [];
  const ctx = { el, pushEventTo: (_el, event, payload) => pushed.push({ event, payload }) };
  env.hook.mounted.call(ctx);
  const press = (key) => {
    const e = { key, prevented: false, preventDefault() { this.prevented = true; } };
    env.listeners.keydown.forEach((fn) => fn(e));
    return e;
  };
  return { ...env, ctx, el, pushed, press };
}

test("Escape with nothing over a picker's viewer closes it and cancels the key for the page", () => {
  const v = mount({ el: viewerEl({ popover: true }) });
  const e = v.press("Escape");
  assert.equal(e.prevented, true, "a host <dialog> must not take the same Escape");
  assert.deepEqual(v.pushed, [{ event: "viewer_keydown", payload: { key: "Escape" } }]);
});

test("any other viewer leaves the key to the page, as it always did", () => {
  const el = viewerEl();
  const v = mount({ el, dialogs: [dialog({ holds: el })] });
  const e = v.press("Escape");
  assert.equal(e.prevented, false, "a host <dialog> around a browser that is not a picker still closes");
  assert.deepEqual(v.pushed, [{ event: "viewer_keydown", payload: { key: "Escape" } }]);
  assert.equal(mount({ active: { tagName: "TEXTAREA" } }).press("Escape").prevented, false);
});

test("a host dialog holding the viewer does not count as a layer over it", () => {
  const el = viewerEl({ popover: true });
  const v = mount({ el, dialogs: [dialog({ holds: el })] });
  const e = v.press("Escape");
  assert.equal(e.prevented, true);
  assert.equal(v.pushed.length, 1);
});

test("a dialog opened over the viewer keeps its Escape; the viewer stays", () => {
  const el = viewerEl({ popover: true });
  const v = mount({ el, dialogs: [dialog({ holds: el }), dialog({ holds: null })] });
  const e = v.press("Escape");
  assert.equal(e.prevented, false, "that dialog closes on its own close request");
  assert.equal(v.pushed.length, 0);
});

test("a dialog that is not modal is not a layer over the viewer", () => {
  const v = mount({ el: viewerEl({ popover: true }), dialogs: [dialog({ modal: false })] });
  assert.equal(v.press("Escape").prevented, true);
  assert.equal(v.pushed.length, 1);
});

test("Escape typed in a field of the viewer closes nothing, the host modal included", () => {
  const v = mount({ el: viewerEl({ popover: true }), active: { tagName: "TEXTAREA" } });
  const e = v.press("Escape");
  assert.equal(e.prevented, true);
  assert.equal(v.pushed.length, 0);
});

test("the arrow keys are left as they were", () => {
  const v = mount();
  const e = v.press("ArrowRight");
  assert.equal(e.prevented, false);
  assert.deepEqual(v.pushed, [{ event: "viewer_keydown", payload: { key: "ArrowRight" } }]);
});

test("the arrows do not step the viewer while the removal dialog is open over it", () => {
  const v = mount();
  v.doc.querySelector = (sel) => (sel === "[data-removal-state]" ? {} : null);
  const e = v.press("ArrowRight");
  assert.deepEqual(v.pushed, []);
  assert.equal(e.prevented, false);
  v.doc.querySelector = () => null;
  v.press("ArrowRight");
  assert.equal(v.pushed.length, 1, "and step again once it is closed");
});

test("a picker's viewer (popover) is shown in the top layer on mount, once", () => {
  const el = viewerEl({ popover: true });
  const v = mount({ el });
  assert.equal(el.shown, 1);
  v.hook.updated.call(v.ctx);
  assert.equal(el.shown, 1, "an open popover is not shown again");
  el.open = false;
  v.hook.updated.call(v.ctx);
  assert.equal(el.shown, 2, "a patch that left it hidden shows it again");
});

test("a viewer without `popover`, or a browser without the API, is left in place", () => {
  const plain = viewerEl();
  mount({ el: plain });
  assert.equal(plain.shown, 0);

  const old = viewerEl({ popover: true });
  delete old.showPopover;
  assert.doesNotThrow(() => mount({ el: old }));
});
