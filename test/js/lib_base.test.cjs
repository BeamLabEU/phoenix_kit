"use strict";

// Where the browser looks for the vendored libraries (and the admin bundle).
//
// The compiler writes the URL the files are served from into the install
// facts (`window.PHOENIX_KIT_LIB_BASE`). The browser used to guess it from the
// address of the script it was running in, which is wrong once `phoenix_kit.js`
// is bundled into the host's app.js, or the facts file is served from a
// directory of its own.
//
//   node --test test/js/lib_base.test.cjs

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { createEnv, makeHook } = require("./support/pk_env.cjs");

const FACTS = { admin: { file: "admin-2.65.0-cafebabe.js", cdn: null } };

// What the compiler writes at the top of phoenix_kit_modules.js (the Elixir
// side asserts the same statement).
function factsFile(base) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pk_facts_"));
  const file = path.join(dir, "phoenix_kit_modules.js");
  fs.writeFileSync(file,
    "window.PHOENIX_KIT_LIB_BASE=window.PHOENIX_KIT_LIB_BASE||" + JSON.stringify(base) + ";\n" +
    "window.PHOENIX_KIT_LIBS=" + JSON.stringify(FACTS) + ";\n");
  return { file, cleanup: () => fs.rmSync(dir, { recursive: true, force: true }) };
}

function mountAdminHook(env) {
  makeHook(env.window.PhoenixKitHooks.SortableGrid).mounted();
  return env.scripts[0] && env.scripts[0].src;
}

test("the base in the facts wins over the address of the script phoenix_kit.js runs in", () => {
  // phoenix_kit.js inside the host's app.js, the facts file deferred ahead of it
  // and served from a directory of its own.
  const env = createEnv();
  const facts = factsFile("/assets/vendor/lib/");
  env.load(facts.file, { src: "https://app.test/somewhere/else/phoenix_kit_modules.js" });
  env.load("phoenix_kit.js", { src: "https://app.test/assets/js/app.js" });

  assert.equal(mountAdminHook(env),
    "https://app.test/assets/vendor/lib/admin-2.65.0-cafebabe.js?vsn=d");
  facts.cleanup();
});

test("a host that serves its assets from a CDN says so in config, and the files are fetched from there", () => {
  const env = createEnv();
  const facts = factsFile("https://cdn.example.test/app/assets/vendor/lib/");
  env.load(facts.file);
  env.load("phoenix_kit.js", { src: "https://app.test/assets/js/app.js" });

  assert.equal(mountAdminHook(env),
    "https://cdn.example.test/app/assets/vendor/lib/admin-2.65.0-cafebabe.js?vsn=d");
  facts.cleanup();
});

test("a base the host set on window itself wins, set before the facts or after", () => {
  const before = createEnv({ libBase: "/own/lib/" });
  const f1 = factsFile("/assets/vendor/lib/");
  before.load(f1.file);
  before.load("phoenix_kit.js", { src: "https://app.test/assets/js/app.js" });
  assert.equal(mountAdminHook(before), "https://app.test/own/lib/admin-2.65.0-cafebabe.js?vsn=d");
  f1.cleanup();

  const after = createEnv();
  const f2 = factsFile("/assets/vendor/lib/");
  after.load(f2.file);
  after.window.PHOENIX_KIT_LIB_BASE = "/later/lib/";
  after.load("phoenix_kit.js", { src: "https://app.test/assets/js/app.js" });
  assert.equal(mountAdminHook(after), "https://app.test/later/lib/admin-2.65.0-cafebabe.js?vsn=d");
  f2.cleanup();
});

test("facts from an older version name no base: the address of phoenix_kit.js still decides", () => {
  const env = createEnv({ facts: FACTS });
  env.load("phoenix_kit.js", { src: "https://app.test/assets/vendor/phoenix_kit.js" });

  assert.equal(mountAdminHook(env),
    "https://app.test/assets/vendor/lib/admin-2.65.0-cafebabe.js?vsn=d");
});
