"use strict";

// The MentionInput hook sends the field's `data-mention-context` with every
// search, so a module's handler can offer what belongs with the page (a `#`
// typed in a project's task offers that project's records, not every
// project the viewer may see). Broken JSON or no attribute → null, never a
// thrown search.
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
    classList: { add: noop, remove: noop, toggle: noop, contains: () => false },
    setAttribute: noop,
    getAttribute: () => null,
    removeAttribute: noop,
    appendChild: (child) => { child.parentNode = el; el.children.push(child); },
    removeChild: noop,
    remove: noop,
    addEventListener: noop,
    removeEventListener: noop,
    querySelector: () => null,
    querySelectorAll: () => [],
    closest: () => null,
    getBoundingClientRect: () => ({ top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 }),
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
  scrollX: 0, scrollY: 0, innerHeight: 800,
  addEventListener: noop, removeEventListener: noop,
  matchMedia: () => ({ matches: false, addEventListener: noop, removeEventListener: noop }),
  localStorage: storage, sessionStorage: storage,
  location: { href: "http://localhost/", reload: noop },
  navigator: { userAgent: "node" },
  document: global.document,
  setTimeout, clearTimeout,
};
global.localStorage = storage;
global.sessionStorage = storage;
global.MutationObserver = function() { this.observe = noop; this.disconnect = noop; };

require("../../priv/static/assets/phoenix_kit.js");
const MentionInput = global.window.PhoenixKitHooks.MentionInput;

function mountWith(dataset) {
  const el = stubElement();
  el.dataset = dataset;
  el.value = "#wal";
  el.selectionStart = 4;
  const hook = Object.create(MentionInput);
  hook.el = el;
  hook.pushed = [];
  hook.pushEvent = (event, payload) => hook.pushed.push({ event, payload });
  hook.handleEvent = noop;
  hook.mounted();
  return hook;
}

test("the search carries the field's context", () => {
  const hook = mountWith({ mentionContext: JSON.stringify({ project: "p-1" }) });
  hook.search();
  assert.equal(hook.pushed.length, 1);
  assert.equal(hook.pushed[0].event, "pk_mention_search");
  assert.deepEqual(hook.pushed[0].payload.context, { project: "p-1" });
  assert.equal(hook.pushed[0].payload.kind, "resource");
  assert.equal(hook.pushed[0].payload.query, "wal");
});

test("no attribute, or broken JSON, is a null context and still a search", () => {
  const bare = mountWith({});
  bare.search();
  assert.equal(bare.pushed[0].payload.context, null);

  const broken = mountWith({ mentionContext: "{not json" });
  broken.search();
  assert.equal(broken.pushed[0].payload.context, null);

  const scalar = mountWith({ mentionContext: "42" });
  scalar.search();
  assert.equal(scalar.pushed[0].payload.context, null);
});
