"use strict";

// The admin menu's scroll position (AdminSidebarScroll). On a full page load the
// saved offset is applied by phoenix_kit.js as soon as the document is parsed,
// not when the admin bundle arrives: the bundle is requested at
// DOMContentLoaded at the earliest, and a menu painted at the top and then moved
// is a jump the person sees. The admin file still restores on a live redirect
// and centres the active link when nothing fits.
//
// Run: mix test.js

const test = require("node:test");
const assert = require("node:assert/strict");
const { createEnv, makeHook } = require("./support/pk_env.cjs");

const KEY = "phoenix_kit:admin:sidebar:scroll";
const FACTS = { admin: { file: "admin-3.0.0-cafebabe.js", cdn: null } };

function page(opts) {
  const env = createEnv(Object.assign({ facts: FACTS, adminLayout: true }, opts));
  return env;
}

function sidebar(env, geometry) {
  const el = env.makeEl("aside");
  el.id = "pk-admin-sidebar";
  Object.assign(el, { scrollTop: 0, scrollHeight: 1200, clientHeight: 500 }, geometry);
  env.els["pk-admin-sidebar"] = el;
  return el;
}

const loadPublic = (env) => env.load("phoenix_kit.js", { src: "https://app.test/assets/vendor/phoenix_kit.js" });

test("a full page load puts the menu back where it was once the document is parsed, with no admin bundle", () => {
  const env = page({ readyState: "loading" });
  env.storage[KEY] = "340";
  const el = sidebar(env);
  loadPublic(env);
  assert.equal(el.scrollTop, 0, "not before the document is parsed");

  env.fireDocument("DOMContentLoaded");
  assert.equal(el.scrollTop, 340);
  assert.ok(!env.window.PhoenixKitAdminLoaded, "the admin bundle has not been needed");
});

test("a script that runs after parsing restores at once", () => {
  const env = page({ readyState: "interactive" });
  env.storage[KEY] = "120";
  const el = sidebar(env);
  loadPublic(env);
  assert.equal(el.scrollTop, 120);
});

test("an offset past the end of the menu is clamped to it", () => {
  const env = page({ readyState: "interactive" });
  env.storage[KEY] = "9000";
  const el = sidebar(env, { scrollHeight: 800, clientHeight: 500 });
  loadPublic(env);
  assert.equal(el.scrollTop, 300);
});

test("nothing saved, a value that is not a number, or no menu on the page: nothing happens and nothing throws", () => {
  for (const saved of [undefined, "abc", ""]) {
    const env = page({ readyState: "interactive" });
    if (saved !== undefined) env.storage[KEY] = saved;
    const el = sidebar(env);
    loadPublic(env);
    assert.equal(el.scrollTop, 0, JSON.stringify(saved));
  }
  const bare = page({ readyState: "interactive" });
  bare.storage[KEY] = "100";
  assert.doesNotThrow(() => loadPublic(bare));
});

test("the admin hook still restores on a live redirect, from the same key", () => {
  const env = page();
  loadPublic(env);
  env.load("phoenix_kit_admin.js", { src: "https://app.test/assets/vendor/lib/admin-3.0.0-cafebabe.js" });
  env.storage[KEY] = "275";
  const el = sidebar(env);
  makeHook(env.window.PhoenixKitAdminHooks.AdminSidebarScroll, el).mounted();
  assert.equal(el.scrollTop, 275);
});
