// The upload manager ships twice: as its own file (for projects that take just
// that) and inside `phoenix_kit_admin.js`, the bundle the admin area and the
// user dashboard load. The media browser and both media pickers are the only
// places core renders it, so it is an admin hook: `phoenix_kit.js` holds a stub
// under its name and nothing else of it.
//
// The admin bundle's copy must be the file, verbatim, but for the last two
// lines: the standalone file registers the hook in `window.PhoenixKitHooks`
// (its host spreads that into LiveSocket), the bundle in
// `window.PhoenixKitAdminHooks` (a host's LiveSocket was built before the
// bundle ran, so a hook added to the other object would not be seen).
//
// To refresh the bundle after editing the standalone file, replace what is
// between the two marker comments in phoenix_kit_admin.js with the file and
// change its last two lines the same way.
//
//   node --test test/js/upload_manager_bundle.test.cjs

const fs = require("fs");
const path = require("path");
const assert = require("node:assert");
const { test } = require("node:test");
const { createEnv, makeHook, ASSETS } = require("./support/pk_env.cjs");

const STANDALONE_FILE = path.join(ASSETS, "phoenix_kit_upload_manager.js");
const standalone = fs.readFileSync(STANDALONE_FILE, "utf8");
const admin = fs.readFileSync(path.join(ASSETS, "phoenix_kit_admin.js"), "utf8");
const pub = fs.readFileSync(path.join(ASSETS, "phoenix_kit.js"), "utf8");

const BEGIN = "// >>> phoenix_kit_upload_manager.js >>>";
const END = "// <<< phoenix_kit_upload_manager.js <<<";

const STANDALONE_TAIL =
  "  window.PhoenixKitHooks = window.PhoenixKitHooks || {};\n" +
  "  window.PhoenixKitHooks.UploadManager = UploadManagerHook;\n" +
  "})();";
const ADMIN_TAIL = "  window.PhoenixKitAdminHooks.UploadManager = UploadManagerHook;\n})();";

const tick = () => new Promise((r) => setTimeout(r, 0));
const FACTS = { admin: { file: "admin-3.0.0-cafebabe.js", cdn: null } };

test("the admin bundle carries the standalone file, verbatim but for how it registers the hook", () => {
  const start = admin.indexOf(BEGIN);
  assert.notStrictEqual(start, -1, "the admin bundle has no copy of the upload manager");
  const from = admin.indexOf("\n", start) + 1;
  const to = admin.indexOf(END, from);
  assert.notStrictEqual(to, -1);

  const file = standalone.trimEnd();
  assert.ok(file.endsWith(STANDALONE_TAIL), "the standalone file registers its hook as this test expects");
  assert.strictEqual(
    admin.slice(from, to).trimEnd(),
    file.slice(0, -STANDALONE_TAIL.length) + ADMIN_TAIL,
    "phoenix_kit_admin.js's copy of the upload manager is out of date: copy " +
      "priv/static/assets/phoenix_kit_upload_manager.js between the markers, " +
      "its last two lines registering the hook in window.PhoenixKitAdminHooks"
  );
});

test("the admin bundle registers the hook once, in its own namespace", () => {
  assert.strictEqual(admin.split("window.PhoenixKitAdminHooks.UploadManager = UploadManagerHook").length - 1, 1);
  assert.strictEqual(admin.split("window.PhoenixKitHooks.UploadManager =").length - 1, 0);
});

test("the public bundle holds the hook's name and none of its code", () => {
  assert.ok(!pub.includes(BEGIN), "the upload manager's copy belongs in phoenix_kit_admin.js");
  for (const marker of ["PhoenixKitUploadManager", "function UploadQueue(", "function ChunkJob(", "PkChunked", "pk-um:"]) {
    assert.ok(!pub.includes(marker), marker + " is upload manager code: it belongs in phoenix_kit_admin.js");
    assert.ok(admin.includes(marker), marker + " is missing from phoenix_kit_admin.js");
  }
  const env = createEnv({ facts: FACTS });
  env.load("phoenix_kit.js");
  assert.ok(env.window.PhoenixKitHooks.UploadManager.__pkAdminStub, "a stub stands in for it");
  assert.strictEqual(env.window.PhoenixKitUploadManager, undefined, "the script's namespace comes with the bundle");
});

// The panel the component renders, as far as `mounted` and `render` reach.
function panel(env) {
  const wrapper = env.makeEl("div");
  wrapper.addEventListener = function (type, fn, capture) { (this.listeners = this.listeners || []).push([type, !!capture]); };
  const el = env.makeEl("div");
  Object.assign(el.dataset, {
    uploadRef: "phx-F1", uploadName: "photos", entries: "photos-entries",
    max: "3", resumable: "true", remember: "false", labels: "{}"
  });
  el.parentElement = wrapper;
  return { el, wrapper };
}

test("the stub starts the real hook on LiveView's own instance, and a resumable panel registers its uploader", async () => {
  const env = createEnv({ facts: FACTS });
  env.load("phoenix_kit.js");
  const { el, wrapper } = panel(env);
  const hook = makeHook(env.window.PhoenixKitHooks.UploadManager, el);
  hook.liveSocket = { uploaders: {} };
  hook.mounted();
  assert.strictEqual(env.scripts.length, 1, "the first mount asks for the admin bundle");

  env.load("phoenix_kit_admin.js");
  env.loaded(0);
  await tick();

  try {
    assert.strictEqual(hook.queue.cap, 3, "the hook mounted on the instance LiveView made");
    assert.strictEqual(hook.queue.resumable, true);
    assert.strictEqual(typeof hook.liveSocket.uploaders.PkChunked, "function", "the chunked uploader is registered with the page's LiveSocket");
    assert.deepStrictEqual(wrapper.listeners.map((l) => l.join(":")).sort(), ["change:true", "input:true"]);
    assert.strictEqual(env.window.PhoenixKitAdminHooks.UploadManager, env.window.PhoenixKitUploadManager.hook);
    assert.deepStrictEqual(Array.from(env.errors), []);
  } finally {
    hook.destroyed();
  }
});

test("a page that ran the standalone file after building LiveSocket still gets the hook from the stub", async () => {
  const env = createEnv({ facts: FACTS });
  env.load("phoenix_kit.js");
  const built = Object.assign({}, env.window.PhoenixKitHooks); // what LiveSocket was given
  env.load("phoenix_kit_upload_manager.js");
  const first = env.window.PhoenixKitUploadManager;
  const { el } = panel(env);
  const hook = makeHook(built.UploadManager, el);
  hook.liveSocket = { uploaders: {} };
  hook.mounted();

  env.load("phoenix_kit_admin.js");
  env.loaded(0);
  await tick();

  try {
    assert.strictEqual(env.window.PhoenixKitUploadManager, first, "the copy in the bundle stood down");
    assert.strictEqual(env.window.PhoenixKitAdminHooks.UploadManager, first.hook);
    assert.strictEqual(hook.queue.cap, 3, "the stub found the hook and started it");
    assert.deepStrictEqual(Array.from(env.errors), []);
  } finally {
    hook.destroyed();
  }
});
