"use strict";

// Where the browser looks for the vendored libraries (and the admin bundle).
//
// In this order:
//   1. window.PHOENIX_KIT_LIB_BASE — the host's own word (a global it set, or
//      `config :phoenix_kit, library_base_url:`, which the install facts turn into
//      that global without overriding one the host set);
//   2. next to the tag that loads phoenix_kit.js, when it is the vendored bundle
//      (phoenix_kit.js, phoenix_kit-<md5>.js): CDN hosts and hosts under a path
//      prefix are right with no configuration;
//   3. the compiler's default, window.PHOENIX_KIT_LIB_BASE_DEFAULT: only when no such
//      tag exists (phoenix_kit.js bundled into the host's app.js). It does not
//      depend on where the facts file is served from, so a host that moves, defers
//      or re-minifies that file is unaffected;
//   4. the directory of whatever script it was (facts from an older version).
//
//   node --test test/js/lib_base.test.cjs

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { createEnv, makeHook } = require("./support/pk_env.cjs");

const FACTS = { admin: { file: "admin-3.0.0-cafebabe.js", cdn: null } };
const FILE = "admin-3.0.0-cafebabe.js?vsn=d";

// What the compiler writes at the top of phoenix_kit_modules.js (the Elixir side
// asserts the same statements): the default under its own key, or the configured
// URL under the key a host's own word also uses.
function factsFile(kind, base) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pk_facts_"));
  const file = path.join(dir, "phoenix_kit_modules.js");
  const statement =
    kind === "configured"
      ? "window.PHOENIX_KIT_LIB_BASE=window.PHOENIX_KIT_LIB_BASE||" + JSON.stringify(base) + ";\n"
      : kind === "default"
        ? "window.PHOENIX_KIT_LIB_BASE_DEFAULT=window.PHOENIX_KIT_LIB_BASE_DEFAULT||" + JSON.stringify(base) + ";\n"
        : "";
  fs.writeFileSync(file, statement + "window.PHOENIX_KIT_LIBS=" + JSON.stringify(FACTS) + ";\n");
  return { file, cleanup: () => fs.rmSync(dir, { recursive: true, force: true }) };
}

// phoenix_kit.js evaluated as the script at `src`; the facts file at `factsSrc`.
function page({ src, factsSrc, kind = "default", base = "/assets/vendor/lib/", before }) {
  const env = createEnv();
  if (before) before(env);
  const facts = factsFile(kind, base);
  env.load(facts.file, { src: factsSrc || "https://app.test/assets/vendor/phoenix_kit_modules.js" });
  env.load("phoenix_kit.js", { src });
  makeHook(env.window.PhoenixKitHooks.SortableGrid).mounted();
  facts.cleanup();
  return env.scripts[0] && env.scripts[0].src;
}

test("a host behind a CDN (static_url): the files are where the tag that loads the bundle is", () => {
  const md5 = "0123456789abcdef0123456789abcdef";
  assert.equal(
    page({ src: `https://cdn.example.test/assets/vendor/phoenix_kit-${md5}.js?vsn=d` }),
    "https://cdn.example.test/assets/vendor/lib/" + FILE);
});

test("a host under a path prefix (url: [path: \"/shop\"]): the same, with no configuration", () => {
  assert.equal(
    page({ src: "https://app.test/shop/assets/vendor/phoenix_kit.js" }),
    "https://app.test/shop/assets/vendor/lib/" + FILE);
});

test("phoenix_kit.js bundled into app.js: no tag says where the files are, so the compiler's default does", () => {
  assert.equal(
    page({ src: "https://app.test/assets/js/app-abc123.js" }),
    "https://app.test/assets/vendor/lib/" + FILE);
});

test("where the facts file is served from makes no difference: moved, deferred, re-minified", () => {
  for (const factsSrc of [
    "https://app.test/assets/js/phoenix_kit_modules.min.js",
    "https://cdn.other.test/x/y/phoenix_kit_modules-deadbeef.js",
    "https://app.test/somewhere/else/phoenix_kit_modules.js",
  ]) {
    assert.equal(
      page({ src: "https://app.test/assets/js/app.js", factsSrc }),
      "https://app.test/assets/vendor/lib/" + FILE, factsSrc);
    assert.equal(
      page({ src: "https://app.test/shop/assets/vendor/phoenix_kit.js", factsSrc }),
      "https://app.test/shop/assets/vendor/lib/" + FILE, factsSrc);
  }
});

test("library_base_url from config beats the tag and the default", () => {
  assert.equal(
    page({
      src: "https://app.test/assets/vendor/phoenix_kit.js",
      kind: "configured",
      base: "https://static.example.test/lib-files/",
    }),
    "https://static.example.test/lib-files/" + FILE);
});

test("a base the host set on window itself beats everything, set before the facts or after", () => {
  assert.equal(
    page({
      src: "https://cdn.example.test/assets/vendor/phoenix_kit.js",
      kind: "configured",
      base: "/from/config/",
      before: (env) => { env.window.PHOENIX_KIT_LIB_BASE = "/own/lib/"; },
    }),
    "https://app.test/own/lib/" + FILE);

  const env = createEnv();
  const facts = factsFile("default", "/assets/vendor/lib/");
  env.load(facts.file);
  env.window.PHOENIX_KIT_LIB_BASE = "/later/lib/";
  env.load("phoenix_kit.js", { src: "https://app.test/assets/js/app.js" });
  makeHook(env.window.PhoenixKitHooks.SortableGrid).mounted();
  assert.equal(env.scripts[0].src, "https://app.test/later/lib/" + FILE);
  facts.cleanup();
});

test("facts from an older version name no default: the directory of the script still decides", () => {
  assert.equal(
    page({ src: "https://app.test/assets/js/app.js", kind: "none" }),
    "https://app.test/assets/js/lib/" + FILE);
});

test("a vendored copy that was renamed is not taken for the bundle's tag", () => {
  // Only phoenix_kit.js / phoenix_kit-<md5>.js are the tag's own names; anything
  // else (a host's own bundle that contains the file) falls to the default.
  assert.equal(
    page({ src: "https://app.test/assets/js/phoenix_kit_host.js" }),
    "https://app.test/assets/vendor/lib/" + FILE);
});
