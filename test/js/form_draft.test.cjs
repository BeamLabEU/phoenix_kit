"use strict";

// Unit tests for FormDraft in priv/static/assets/phoenix_kit.js — opt-in
// drafts of a form's fields: which fields are kept, how they are written and
// put back, expiry; and the hook offering, restoring, declining and clearing.
//
// Run: mix test.js  (node --test needs the explicit file on Node 25)
const test = require("node:test");
const assert = require("node:assert/strict");

const noop = () => {};

function stubElement() {
  return {
    style: {}, dataset: {},
    classList: { add: noop, remove: noop, toggle: noop, contains: () => false },
    setAttribute: noop, getAttribute: () => null, removeAttribute: noop,
    appendChild: noop, remove: noop, addEventListener: noop, removeEventListener: noop,
    querySelector: () => null, querySelectorAll: () => [],
  };
}

function memoryStorage() {
  const m = new Map();
  return {
    m,
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => m.set(k, String(v)),
    removeItem: (k) => m.delete(k),
  };
}

const local = memoryStorage();
const session = memoryStorage();

global.document = {
  documentElement: stubElement(), head: stubElement(), body: stubElement(),
  createElement: stubElement, createTextNode: () => ({}),
  getElementById: () => null, querySelector: () => null, querySelectorAll: () => [],
  addEventListener: noop, removeEventListener: noop, cookie: "",
};
global.window = {
  addEventListener: noop, removeEventListener: noop,
  matchMedia: () => ({ matches: false, addEventListener: noop, removeEventListener: noop }),
  localStorage: local, sessionStorage: session,
  location: { href: "http://localhost/posts/new", pathname: "/posts/new", reload: noop },
  navigator: { userAgent: "node" }, document: global.document, setTimeout, clearTimeout,
};
global.localStorage = local;
global.sessionStorage = session;

const d = require("../../priv/static/assets/phoenix_kit.js").formDraft;
const Hook = global.window.PhoenixKitHooks.FormDraft;

function field(name, props) {
  const attrs = (props && props.attrs) || {};
  const f = Object.assign({
    tagName: "INPUT", type: "text", name, value: "", disabled: false, dispatched: [],
    hasAttribute: (k) => k in attrs,
    dispatchEvent(e) { this.dispatched.push(e.type); },
  }, props);
  delete f.attrs;
  return f;
}

function select(name, values, selected) {
  return field(name, {
    tagName: "SELECT", type: "select-multiple", multiple: true,
    options: values.map((v) => ({ value: v, selected: selected.includes(v) })),
  });
}

test("which fields are kept", () => {
  assert.equal(d.eligible(field("post[title]"), []), true);
  assert.equal(d.eligible(field("post[body]", { tagName: "TEXTAREA", type: "textarea" }), []), true);
  for (const type of ["password", "hidden", "file", "submit", "button", "reset", "image"]) {
    assert.equal(d.eligible(field("x", { type }), []), false, type);
  }
  assert.equal(d.eligible(field("_csrf_token"), []), false);
  assert.equal(d.eligible(field("_target"), []), false);
  assert.equal(d.eligible(field("user[csrf]"), []), false);
  assert.equal(d.eligible(field(""), []), false);
  assert.equal(d.eligible(field("a", { disabled: true }), []), false);
  assert.equal(d.eligible(field("a", { attrs: { "data-draft-skip": "" } }), []), false);
  assert.equal(d.eligible(field("a", { tagName: "BUTTON" }), []), false);
});

test("exclude matches a name and the same name nested", () => {
  const ex = d.excludeList(" email , post[slug],");
  assert.deepEqual(ex, ["email", "post[slug]"]);
  assert.equal(d.nameExcluded("email", ex), true);
  assert.equal(d.nameExcluded("user[email]", ex), true);
  assert.equal(d.nameExcluded("user[email][]", ex), true);
  assert.equal(d.nameExcluded("user[email_confirm]", ex), false);
  assert.equal(d.nameExcluded("post[slug]", ex), true);
  assert.equal(d.nameExcluded("other[slug]", ex), false, "a nested name only matches itself");
  assert.equal(d.nameExcluded("a[b.c]", ["b.c"]), true, "names are not regexes");
  assert.equal(d.nameExcluded("a[bxc]", ["b.c"]), false);
});

test("serialize writes text, checkbox groups, radios and multiple selects", () => {
  const els = [
    field("title", { value: "Hi" }),
    field("pw", { type: "password", value: "secret" }),
    field("tags[]", { type: "checkbox", value: "a", checked: true }),
    field("tags[]", { type: "checkbox", value: "b", checked: false }),
    field("agree", { type: "checkbox", value: "true", checked: false }),
    field("size", { type: "radio", value: "s", checked: false }),
    field("size", { type: "radio", value: "m", checked: true }),
    field("color", { type: "radio", value: "red", checked: false }),
    select("langs[]", ["en", "et", "ru"], ["et", "ru"]),
  ];
  assert.deepEqual(d.serialize(els, []), {
    title: "Hi", "tags[]": ["a"], agree: [], size: "m", color: null, "langs[]": ["et", "ru"],
  });
  assert.ok(!("pw" in d.serialize(els, [])), "never a password");
});

test("apply puts it back and reports what changed", () => {
  const els = [
    field("title", { value: "" }),
    field("tags[]", { type: "checkbox", value: "a", checked: false }),
    field("tags[]", { type: "checkbox", value: "b", checked: true }),
    field("size", { type: "radio", value: "s", checked: true }),
    field("size", { type: "radio", value: "m", checked: false }),
    select("langs[]", ["en", "et"], []),
    field("untouched", { value: "keep" }),
    field("pw", { type: "password", value: "" }),
  ];
  const changed = d.apply(els, {
    title: "Draft", "tags[]": ["a"], size: "m", "langs[]": ["et"], pw: "stolen",
  }, []);
  assert.equal(els[0].value, "Draft");
  assert.deepEqual([els[1].checked, els[2].checked], [true, false]);
  assert.deepEqual([els[3].checked, els[4].checked], [false, true]);
  assert.deepEqual(els[5].options.map((o) => o.selected), [false, true]);
  assert.equal(els[6].value, "keep", "a field the draft does not name is left alone");
  assert.equal(els[7].value, "", "a password is never written, even if a draft names it");
  assert.equal(changed.length, 6);
});

test("keys and stored drafts", () => {
  assert.equal(d.key("/posts/new", "post-form"), "pk:draft:/posts/new#post-form");
  assert.equal(d.key("/x", "f", "post:1"), "pk:draft:post:1");
  const now = 1_000_000_000;
  const raw = JSON.stringify({ v: 1, t: now - 1000, fields: { a: "b" } });
  assert.deepEqual(d.parse(raw, now, 60).fields, { a: "b" });
  assert.equal(d.parse(raw, now + 61_000, 60), null, "expired");
  assert.equal(d.parse("{nope", now, 60), null);
  assert.equal(d.parse(JSON.stringify({ v: 2, t: now, fields: {} }), now, 60), null);
  assert.equal(d.parse(null, now, 60), null);
  assert.equal(d.equal({ a: "1", b: ["x"] }, { b: ["x"], a: "1" }), true);
  assert.equal(d.equal({ a: "1" }, { a: "2" }), false);
});

// ── The hook ─────────────────────────────────────────────────────────────

function fakeForm({ dataset = {}, bar = true, elements } = {}) {
  const listeners = {};
  const prompt = { hidden: true };
  const barListeners = {};
  const barEl = bar ? {
    querySelector: (s) => (s === "[data-pk-draft-prompt]" ? prompt : null),
    addEventListener: (t, fn) => { barListeners[t] = fn; },
    removeEventListener: noop,
  } : null;
  const els = elements || [field("post[title]", { value: "" }), field("post[body]", { value: "" })];
  const el = {
    id: "post-form",
    dataset: Object.assign({ draftStorage: "local", draftTtl: "3600", draftExclude: "" }, dataset),
    elements: els,
    addEventListener: (t, fn) => { listeners[t] = fn; },
    removeEventListener: noop,
    querySelector: () => barEl,
  };
  const handlers = {};
  const pushed = [];
  const hook = Object.assign(Object.create(Hook), {
    el,
    handleEvent: (name, fn) => { handlers[name] = fn; },
    pushEvent: (name, payload, cb) => pushed.push({ name, payload, cb }),
  });
  const button = (attr) => ({ target: { closest: () => ({ hasAttribute: (k) => k === attr }) }, preventDefault: noop });
  return { hook, el, els, listeners, prompt, barListeners, handlers, pushed, button };
}

const KEY = "pk:draft:/posts/new#post-form";

function waitSave() {
  return new Promise((r) => setTimeout(r, 450));
}

test("typing saves a draft; nothing changed saves none", async () => {
  local.m.clear();
  const f = fakeForm();
  f.hook.mounted();
  f.els[0].value = "Hello";
  f.listeners.input({ target: f.els[0] });
  await waitSave();
  assert.deepEqual(JSON.parse(local.getItem(KEY)).fields, { "post[title]": "Hello", "post[body]": "" });
  f.els[0].value = "";
  f.listeners.input({ target: f.els[0] });
  await waitSave();
  assert.equal(local.getItem(KEY), null, "back to what was rendered: no draft");
});

test("session storage and a custom key", async () => {
  local.m.clear(); session.m.clear();
  const f = fakeForm({ dataset: { draftStorage: "session", draftKey: "post:42" } });
  f.hook.mounted();
  f.els[1].value = "x";
  f.listeners.change({ target: f.els[1] });
  await waitSave();
  assert.ok(session.getItem("pk:draft:post:42"));
  assert.equal(local.m.size, 0);
});

test("a found draft is offered; Restore fills the form and tells LiveView", () => {
  local.m.clear();
  local.setItem(KEY, JSON.stringify({ v: 1, t: Date.now(), fields: { "post[title]": "Saved", "post[body]": "" } }));
  const f = fakeForm();
  f.hook.mounted();
  assert.equal(f.prompt.hidden, false, "the bar shows");
  // Typing before answering does not overwrite the old draft.
  f.hook._save();
  assert.equal(JSON.parse(local.getItem(KEY)).fields["post[title]"], "Saved");
  f.barListeners.click(f.button("data-pk-draft-restore"));
  assert.equal(f.els[0].value, "Saved");
  assert.deepEqual(f.els[0].dispatched, ["input"], "phx-change hears about it");
  assert.equal(f.prompt.hidden, true);
});

test("Discard throws the draft away", () => {
  local.m.clear();
  local.setItem(KEY, JSON.stringify({ v: 1, t: Date.now(), fields: { "post[title]": "Saved" } }));
  const f = fakeForm();
  f.hook.mounted();
  f.barListeners.click(f.button("data-pk-draft-discard"));
  assert.equal(local.getItem(KEY), null);
  assert.equal(f.els[0].value, "");
});

test("an expired draft is removed, not offered", () => {
  local.m.clear();
  local.setItem(KEY, JSON.stringify({ v: 1, t: Date.now() - 7200 * 1000, fields: { "post[title]": "Old" } }));
  const f = fakeForm();
  f.hook.mounted();
  assert.equal(f.prompt.hidden, true);
  assert.equal(local.getItem(KEY), null);
});

test("the server is asked first when an event is named, and its answer wins", () => {
  for (const [reply, title, kept, shown] of [
    [{ restore: true }, "Saved", true, false],
    [{ restore: false }, "", false, false],
    [{}, "", true, true],
  ]) {
    local.m.clear();
    local.setItem(KEY, JSON.stringify({ v: 1, t: 123 + Date.now() - 123, fields: { "post[title]": "Saved" } }));
    const f = fakeForm({ dataset: { draftEvent: "draft_found" } });
    f.hook.mounted();
    assert.equal(f.pushed.length, 1);
    assert.equal(f.pushed[0].name, "draft_found");
    assert.deepEqual(f.pushed[0].payload.fields, ["post[title]"]);
    assert.equal(f.pushed[0].payload.id, "post-form");
    f.pushed[0].cb(reply);
    assert.equal(f.els[0].value, title, JSON.stringify(reply));
    assert.equal(local.getItem(KEY) !== null, kept, JSON.stringify(reply));
    assert.equal(f.prompt.hidden, !shown, JSON.stringify(reply));
  }
});

test("cleared by the server, or when a submitted form leaves the page", async () => {
  local.m.clear();
  const f = fakeForm();
  f.hook.mounted();
  f.els[0].value = "Hello";
  f.listeners.submit({});
  assert.ok(local.getItem(KEY), "kept until the save is known to have worked");
  f.handlers["pk:form-draft"]({ id: "other-form", action: "clear" });
  assert.ok(local.getItem(KEY), "another form's clear is not ours");
  f.handlers["pk:form-draft"]({ id: "post-form", action: "clear" });
  assert.equal(local.getItem(KEY), null);

  f.listeners.submit({});
  f.hook.destroyed();
  assert.equal(local.getItem(KEY), null, "submitted and gone");

  const g = fakeForm();
  g.hook.mounted();
  g.els[0].value = "Unsent";
  g.listeners.input({ target: g.els[0] });
  await waitSave();
  g.hook.destroyed();
  assert.ok(local.getItem(KEY), "left without submitting: the draft stays");
});
