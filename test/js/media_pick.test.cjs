"use strict";

// A single-pick media picker confirms on a double click (LiveView has no
// double-click binding, so the MediaDragDrop hook listens for it).
//
//   node --test test/js/media_pick.test.cjs

const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const src = fs.readFileSync(
  path.join(__dirname, "..", "..", "priv", "static", "assets", "phoenix_kit_admin.js"),
  "utf8"
);

function setupPickConfirm() {
  const start = src.indexOf("    setupPickConfirm: function() {");
  assert.notEqual(start, -1, "could not find setupPickConfirm");
  const end = src.indexOf("\n    },", start) + "\n    }".length;
  return new Function("return {" + src.slice(start, end) + "}.setupPickConfirm;")();
}

function picker(mode) {
  const listeners = {};
  const calls = [];
  const el = {
    dataset: mode ? { pickMode: mode } : {},
    addEventListener: (name, fn) => (listeners[name] = fn),
  };
  const hook = {
    el,
    pushEventTo: (_el, event, payload) => calls.push({ event, payload }),
  };
  setupPickConfirm().call(hook);
  return { el, calls, dblclick: (target) => listeners.dblclick({ target }) };
}

function card(uuid, root) {
  return {
    getAttribute: (name) => (name === "phx-value-file-uuid" ? uuid : null),
    closest: (selector) => (selector === '[phx-hook="MediaDragDrop"]' ? root : null),
  };
}

function inside(cardEl) {
  return { closest: (selector) => (selector === '[phx-click="click_file"]' ? cardEl : null) };
}

test("a double click on a file of a single picker confirms that file", () => {
  const p = picker("single");
  p.dblclick(inside(card("file-1", p.el)));
  assert.deepEqual(p.calls, [{ event: "pick_quick_confirm", payload: { "file-uuid": "file-1" } }]);
});

test("a multiple picker or a plain browser ignores the double click", () => {
  for (const mode of ["multiple", undefined]) {
    const p = picker(mode);
    p.dblclick(inside(card("file-1", p.el)));
    assert.equal(p.calls.length, 0);
  }
});

test("a double click outside a file, or in another browser, does nothing", () => {
  const p = picker("single");
  p.dblclick({ closest: () => null });
  p.dblclick(inside(card("file-1", { other: true })));
  assert.equal(p.calls.length, 0);
});
