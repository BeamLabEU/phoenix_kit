"use strict";

// The public / admin split of the hook bundle
// (dev_docs/plans/2026-10-27-public-admin-js-split.md).
//
// `phoenix_kit.js` is what every page loads. The hooks that only the admin
// area and the user dashboard use live in `phoenix_kit_admin.js`, fetched on
// the first mount of any of them. A host spreads `window.PhoenixKitHooks` into
// LiveSocket once, so each admin hook keeps its NAME there as a small stub
// that loads the bundle and then becomes the real hook.
//
//   node --test test/js/admin_split.test.cjs

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { createEnv, makeHook, ASSETS } = require("./support/pk_env.cjs");

// Every hook `phoenix_kit.js` registered before the split (unchanged in 3.0.0). A hook
// that is neither listed as public nor as admin has been lost; one that is
// listed twice has been classified twice.
const PUBLIC = `LibraryLoadNotice CookieConsent FlashAutoDismiss TimezoneOffset TimezoneDetector
  LanguageSwitcherSearch LanguageSwitcherPosition PkDialog PkDialogTrigger PopupLink ResetSelect
  SelectOnMount TimeAgo CopyToClipboard FadeOut PreserveScroll InfiniteScroll PageSizeAutoFit
  MaintenanceCountdown PkShiftEnter PkUrlMirror PhoenixKitUrlState PkCheckboxIndeterminate PkDateInput
  PkChartCrosshair ViewportPopover Leaf FrescoViewer FrescoCanvas TesseraLayer EtcherLayer`.split(/\s+/);

const ADMIN = `SortableGrid MediaImageZoom MarkdownEditor InstantViewer ViewerKeydown ViewerPaneFit
  MediaViewerDialog PkHashHighlight BulkSelectScope TableLocalSearch AdminSidebarScroll PkDialogDraft
  AnnotationBurn EtcherTooltipActions AnnotationComposerPosition ListFilter TreePickerSearch CrumbSwitcher
  TableFit TableCardView RowMenu RowMenuAuto EmailCharts IntegrationPickerSearch MediaDragDrop EtcherReset
  ViewerSwipe ViewerGallery ViewerHiresLoading UploadResume FolderDropUpload StackMemory StackExpand
  WaveformPlayer SearchPicker MentionInput UploadStats UploadGuard ContextMenu AvatarCrop ImageEditor`.split(/\s+/);

const ADMIN_FILE = path.join(ASSETS, "phoenix_kit_admin.js");
const PUBLIC_FILE = path.join(ASSETS, "phoenix_kit.js");

const FACTS = { admin: { file: "admin-3.0.0-cafebabe.js", cdn: null } };
const ADMIN_URL = "https://app.test/assets/vendor/lib/admin-3.0.0-cafebabe.js?vsn=d";

function publicPage(opts) {
  const env = createEnv(Object.assign({ facts: FACTS }, opts));
  env.load("phoenix_kit.js", { src: "https://app.test/assets/vendor/phoenix_kit.js" });
  return env;
}

const tick = () => new Promise((r) => setTimeout(r, 0));

// How long after a failed load a mount is refused without a request (the page
// code says 4000); the tests only need "more than that".
const RETRY_PAUSE_MS = 4000;

// Values made inside the page's vm context have that realm's Array and Object
// prototypes, which deepEqual (rightly) tells apart from ours.
const plain = (v) => JSON.parse(JSON.stringify(v));

// ── The inventory ──────────────────────────────────────────────────────────

test("the two lists are disjoint and together are the 72 hooks the bundle always had", () => {
  assert.equal(PUBLIC.length, 31);
  assert.equal(ADMIN.length, 41);
  assert.deepEqual(PUBLIC.filter((n) => ADMIN.includes(n)), []);
});

test("every hook name is still registered after the public bundle alone has run", () => {
  const { window } = publicPage();
  for (const name of [...PUBLIC, ...ADMIN]) {
    assert.ok(window.PhoenixKitHooks[name], name + " must stay in PhoenixKitHooks: a host spreads it once");
    assert.equal(typeof window.PhoenixKitHooks[name].mounted, "function", name + " has a mounted()");
  }
});

test("exactly the admin hooks are stubs; the public ones are the real thing", () => {
  const { window } = publicPage();
  const stubs = Array.from(Object.keys(window.PhoenixKitHooks)).filter((n) => window.PhoenixKitHooks[n].__pkAdminStub);
  assert.deepEqual(stubs.sort(), [...ADMIN].sort());
  for (const name of PUBLIC) assert.ok(!window.PhoenixKitHooks[name].__pkAdminStub, name);
});

test("the admin bundle defines exactly the hooks the stubs stand for, and touches no other namespace", () => {
  const env = publicPage();
  env.load("phoenix_kit_admin.js");
  assert.deepEqual(Array.from(Object.keys(env.window.PhoenixKitAdminHooks)).sort(), [...ADMIN].sort());
  assert.equal(env.window.PhoenixKitAdminLoaded, true);
  assert.deepEqual(plain(env.warnings), [], "no hook without a stub");
  for (const name of ADMIN) {
    assert.ok(env.window.PhoenixKitHooks[name].__pkAdminStub, name + " is still the stub: the admin bundle does not rewrite the host's hooks");
  }
});

test("the public file carries no admin implementation and no Chart.js", () => {
  const src = fs.readFileSync(PUBLIC_FILE, "utf8");
  assert.ok(!/Chart\.js v\d/.test(src), "Chart.js is its own vendored library");
  for (const name of ADMIN) {
    assert.ok(!new RegExp("PhoenixKitHooks\\." + name + "\\s*=").test(src), name + " is assigned in the public file");
  }
});

test("the admin file registers into its own namespace only", () => {
  const src = fs.readFileSync(ADMIN_FILE, "utf8");
  // Reading the public namespace is fine (the sanity check at the end does);
  // writing to it is not: a hook put there after the host built LiveSocket is
  // never seen, and the stub would look for it in the admin namespace anyway.
  const withoutAdmin = src.replace(/PhoenixKitAdminHooks/g, "");
  assert.ok(!/PhoenixKitHooks(\.\w+|\[[^\]]*\])?\s*=(?!=)/.test(withoutAdmin), "a hook assigned to the public namespace");
});

test("a size budget keeps the public file public", () => {
  const publicBytes = fs.statSync(PUBLIC_FILE).size;
  const adminBytes = fs.statSync(ADMIN_FILE).size;
  assert.ok(publicBytes < 240 * 1024, "phoenix_kit.js is " + publicBytes + " bytes");
  assert.ok(adminBytes > publicBytes / 2, "the admin file is where the weight went");
});

// ── The stub ───────────────────────────────────────────────────────────────

// A stand-in admin bundle, so the stub's behaviour is tested without any real
// hook's logic in the way.
function fakeAdmin(calls) {
  return (
    "window.PhoenixKitAdminHooks = window.PhoenixKitAdminHooks || {};\n" +
    "var calls = " + JSON.stringify([]) + ";\n" +
    "window.__calls = window.__calls || [];\n" +
    "function rec(name, self) { window.__calls.push([name, self]); }\n" +
    ["SortableGrid", "RowMenu", "ListFilter"].map((n) =>
      "window.PhoenixKitAdminHooks." + n + " = {\n" +
      "  mounted() { rec('" + n + ".mounted', this); this.handleEvent('ping', () => rec('" + n + ".event', this)); this.pushEvent('hello', {n: '" + n + "'}); },\n" +
      "  beforeUpdate() { rec('" + n + ".beforeUpdate', this); },\n" +
      "  updated() { rec('" + n + ".updated', this); },\n" +
      "  disconnected() { rec('" + n + ".disconnected', this); },\n" +
      "  reconnected() { rec('" + n + ".reconnected', this); },\n" +
      "  destroyed() { rec('" + n + ".destroyed', this); },\n" +
      "  helper() { return 'h:" + n + "'; }\n" +
      "};\n").join("") +
    "window.PhoenixKitAdminLoaded = true;\n"
  );
}

function withFakeAdmin() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pk_admin_"));
  const file = path.join(dir, "fake_admin.js");
  fs.writeFileSync(file, fakeAdmin());
  const env = publicPage();
  const arrive = () => { env.load(file); env.loaded(0); };
  const calls = () => env.window.__calls || [];
  const names = () => Array.from(calls(), (c) => c[0]);
  return { env, arrive, calls, names, cleanup: () => fs.rmSync(dir, { recursive: true, force: true }) };
}

test("mounting fetches the admin bundle once, however many admin hooks mount", async () => {
  const t = withFakeAdmin();
  const a = makeHook(t.env.window.PhoenixKitHooks.SortableGrid);
  const b = makeHook(t.env.window.PhoenixKitHooks.RowMenu);
  const c = makeHook(t.env.window.PhoenixKitHooks.ListFilter);
  a.mounted(); b.mounted(); c.mounted();

  assert.equal(t.env.scripts.length, 1);
  assert.equal(t.env.scripts[0].src, ADMIN_URL);
  assert.deepEqual(t.names(), [], "nothing runs before the bundle is there");

  t.arrive();
  await tick();
  assert.deepEqual(t.names(), ["SortableGrid.mounted", "RowMenu.mounted", "ListFilter.mounted"]);
  t.cleanup();
});

test("the real mounted() runs on the very hook instance: handleEvent and pushEvent work", async () => {
  const t = withFakeAdmin();
  const hook = makeHook(t.env.window.PhoenixKitHooks.SortableGrid);
  hook.mounted();
  t.arrive();
  await tick();

  assert.deepEqual(plain(hook.pushed), [["hello", { n: "SortableGrid" }]]);
  assert.equal(typeof hook.handlers.ping, "function", "registered on this hook, not on a copy");
  hook.handlers.ping();
  assert.ok(t.calls().some(([n, self]) => n === "SortableGrid.event" && self === hook));
  assert.equal(t.calls()[0][1], hook, "mounted ran with the LiveView's hook as this");
  assert.equal(hook.helper(), "h:SortableGrid", "the real hook's own methods are on the instance");
  t.cleanup();
});

test("once loaded, every lifecycle callback reaches the real hook with the same this", async () => {
  const t = withFakeAdmin();
  const hook = makeHook(t.env.window.PhoenixKitHooks.RowMenu);
  hook.mounted();
  t.arrive();
  await tick();

  for (const cb of ["beforeUpdate", "updated", "disconnected", "reconnected", "destroyed"]) {
    assert.equal(typeof hook[cb], "function", cb + " is wired");
    hook[cb]();
  }
  assert.deepEqual(t.names().slice(1), [
    "RowMenu.beforeUpdate", "RowMenu.updated", "RowMenu.disconnected", "RowMenu.reconnected", "RowMenu.destroyed",
  ]);
  assert.ok(t.calls().every(([, self]) => self === hook));
  t.cleanup();
});

test("callbacks that arrive before the bundle do nothing, and mounted then reads the DOM as it is", async () => {
  const t = withFakeAdmin();
  const hook = makeHook(t.env.window.PhoenixKitHooks.ListFilter);
  hook.mounted();

  // A LiveView may call these while the file is still on its way.
  for (const cb of ["beforeUpdate", "updated", "disconnected", "reconnected"]) {
    if (typeof hook[cb] === "function") hook[cb]();
  }
  t.arrive();
  await tick();

  assert.deepEqual(t.names(), ["ListFilter.mounted"], "mounted once; the early updates are not replayed");
  t.cleanup();
});

test("a hook destroyed before the bundle arrives never mounts late", async () => {
  const t = withFakeAdmin();
  const hook = makeHook(t.env.window.PhoenixKitHooks.SortableGrid);
  hook.mounted();
  hook.destroyed();
  t.arrive();
  await tick();

  assert.deepEqual(t.names(), []);
  t.cleanup();
});

test("a page that already has the admin bundle fetches nothing", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pk_admin_"));
  const file = path.join(dir, "fake_admin.js");
  fs.writeFileSync(file, fakeAdmin());
  const env = publicPage();
  env.load(file); // a host that imported it in its own app.js
  const hook = makeHook(env.window.PhoenixKitHooks.SortableGrid);
  hook.mounted();
  await tick();

  assert.equal(env.scripts.length, 0);
  assert.deepEqual(Array.from(env.window.__calls, (c) => c[0]), ["SortableGrid.mounted"]);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("a failed load is reported with the hook's name and the file, throws nothing, and the next mount tries again", async () => {
  const t = withFakeAdmin();
  const first = makeHook(t.env.window.PhoenixKitHooks.SortableGrid);
  first.mounted();
  t.env.failed(0);
  await tick();

  assert.ok(t.env.errors.some((m) => m.includes("SortableGrid") && m.includes(ADMIN_URL)),
    "the console names the hook and the file: " + JSON.stringify(t.env.errors));
  assert.deepEqual(t.names(), []);

  t.env.advance(RETRY_PAUSE_MS + 1); // the pause after a failure is over

  const second = makeHook(t.env.window.PhoenixKitHooks.RowMenu);
  second.mounted();
  assert.equal(t.env.scripts.length, 2, "a later mount starts a new attempt");
  t.cleanup();
});

test("a retry after a failure works", async () => {
  const t = withFakeAdmin();
  makeHook(t.env.window.PhoenixKitHooks.SortableGrid).mounted();
  t.env.failed(0);
  await tick();

  t.env.advance(RETRY_PAUSE_MS + 1);
  const again = makeHook(t.env.window.PhoenixKitHooks.RowMenu);
  again.mounted();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pk_admin_"));
  const file = path.join(dir, "fake_admin.js");
  fs.writeFileSync(file, fakeAdmin());
  t.env.load(file);
  t.env.loaded(1);
  await tick();

  assert.deepEqual(t.names(), ["RowMenu.mounted"]);
  fs.rmSync(dir, { recursive: true, force: true });
  t.cleanup();
});

test("without install facts naming the bundle the stub says so instead of throwing", async () => {
  const env = createEnv({ facts: {} });
  env.load("phoenix_kit.js", { src: "https://app.test/assets/vendor/phoenix_kit.js" });
  const hook = makeHook(env.window.PhoenixKitHooks.SortableGrid);
  assert.doesNotThrow(() => hook.mounted());
  await tick();

  assert.ok(env.errors.some((m) => m.includes("SortableGrid")), JSON.stringify(env.errors));
  assert.equal(env.scripts.length, 0);
});

// ── Load order ─────────────────────────────────────────────────────────────

test("a module bundle that ran before this file keeps its hooks, and its facts are still found", async () => {
  // A host that defers phoenix_kit_modules.js ahead of an app.js holding
  // phoenix_kit.js: the facts and the module hooks exist before this file runs.
  const env = createEnv({ facts: FACTS });
  const moduleHook = { mounted() {} };
  const overridden = { mounted() {} };
  env.window.PhoenixKitHooks = { MyModuleHook: moduleHook, RowMenu: overridden };
  env.load("phoenix_kit.js", { src: "https://app.test/assets/js/app.js" });

  assert.equal(env.window.PhoenixKitHooks.MyModuleHook, moduleHook, "not dropped");
  assert.equal(env.window.PhoenixKitHooks.RowMenu, overridden, "a name the module defines stays the module's");
  assert.ok(env.window.PhoenixKitHooks.SortableGrid.__pkAdminStub, "the rest are stubs as usual");
});

// ── Early start ────────────────────────────────────────────────────────────

test("a page whose layout is the admin or dashboard layout starts the download before any hook mounts", async () => {
  const env = createEnv({ facts: FACTS, readyState: "loading", adminLayout: true });
  env.load("phoenix_kit.js", { src: "https://app.test/assets/vendor/phoenix_kit.js" });
  assert.equal(env.scripts.length, 0, "not before the document is parsed");

  env.fireDocument("DOMContentLoaded");
  assert.equal(env.scripts.length, 1);
  assert.equal(env.scripts[0].src, ADMIN_URL);

  // The first stub to mount joins that same request.
  makeHook(env.window.PhoenixKitHooks.SortableGrid).mounted();
  assert.equal(env.scripts.length, 1);
});

test("a public page fetches nothing, however its hooks mount", async () => {
  const env = createEnv({ facts: FACTS, readyState: "loading" });
  env.load("phoenix_kit.js", { src: "https://app.test/assets/vendor/phoenix_kit.js" });
  env.fireDocument("DOMContentLoaded");
  await tick();

  assert.equal(env.scripts.length, 0);
  for (const name of PUBLIC) {
    if (["Leaf", "FrescoViewer", "FrescoCanvas", "TesseraLayer", "EtcherLayer"].includes(name)) continue;
    assert.ok(!env.window.PhoenixKitHooks[name].__pkAdminStub, name);
  }
});

test("an already parsed page is checked on the next tick", async () => {
  const env = createEnv({ facts: FACTS, adminLayout: true });
  env.load("phoenix_kit.js", { src: "https://app.test/assets/vendor/phoenix_kit.js" });
  await new Promise((r) => setTimeout(r, 5));

  assert.equal(env.scripts.length, 1);
});

test("a failed early start is reported once and leaves later mounts free to try again", async () => {
  const env = createEnv({ facts: FACTS, adminLayout: true });
  env.load("phoenix_kit.js", { src: "https://app.test/assets/vendor/phoenix_kit.js" });
  await new Promise((r) => setTimeout(r, 5));
  env.failed(0);
  await tick();

  assert.ok(env.errors.some((m) => m.includes("admin") && m.includes(ADMIN_URL)));
  env.advance(RETRY_PAUSE_MS + 1);
  makeHook(env.window.PhoenixKitHooks.SortableGrid).mounted();
  assert.equal(env.scripts.length, 2, "a later mount tries again");
});

// ── Admin hooks of modules ─────────────────────────────────────────────────

// What phoenix_kit_modules.js says for a module whose js_sources/0 entry is
// `scope: :admin, hooks: ["GridSort"]` (the compiler's test pins the text).
const MODULE_STUBS =
  '(function(n){var w=window;w.PhoenixKitModuleAdminHooks=(w.PhoenixKitModuleAdminHooks||[]).concat(n);' +
  'if(w.PhoenixKitRegisterAdminStubs)w.PhoenixKitRegisterAdminStubs(n)})(["GridSort"]);';

// The admin bundle as the compiler builds it for that module: the module's
// bundle, then the fold into the namespace the stubs read from.
function moduleAdminBundle() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pk_mod_admin_"));
  const file = path.join(dir, "grid_admin.js");
  fs.writeFileSync(file,
    "window.GridHooks = { GridSort: { mounted() { (window.__mods = window.__mods || []).push(this.el.id); } } };\n" +
    "window.PhoenixKitAdminHooks = Object.assign(window.PhoenixKitAdminHooks || {}, window.GridHooks || {});\n" +
    "window.PhoenixKitAdminLoaded = true;\n");
  return { file, cleanup: () => fs.rmSync(dir, { recursive: true, force: true }) };
}

const vm = require("vm");
const runSnippet = (env, code) => vm.runInContext(code, vm.createContext(env.window));

test("a module's admin hook is stubbed when its names arrive after phoenix_kit.js", async () => {
  const env = publicPage();
  runSnippet(env, MODULE_STUBS);

  const stub = env.window.PhoenixKitHooks.GridSort;
  assert.ok(stub && stub.__pkAdminStub, "stubbed in the object a host spreads");

  const bundle = moduleAdminBundle();
  makeHook(stub, { id: "grid-1" }).mounted();
  assert.equal(env.scripts.length, 1, "the same admin bundle");
  env.load(bundle.file);
  env.loaded(0);
  await tick();

  assert.deepEqual(Array.from(env.window.__mods), ["grid-1"]);
  bundle.cleanup();
});

test("and when they arrive before it: a deferred modules file ahead of an app.js holding phoenix_kit.js", async () => {
  const env = createEnv({ facts: FACTS });
  runSnippet(env, MODULE_STUBS); // phoenix_kit.js has not run: the names wait on the window
  assert.deepEqual(Array.from(env.window.PhoenixKitModuleAdminHooks), ["GridSort"]);

  env.load("phoenix_kit.js", { src: "https://app.test/assets/js/app.js" });
  const stub = env.window.PhoenixKitHooks.GridSort;
  assert.ok(stub && stub.__pkAdminStub);

  const bundle = moduleAdminBundle();
  makeHook(stub, { id: "grid-2" }).mounted();
  env.load(bundle.file);
  env.loaded(0);
  await tick();

  assert.deepEqual(Array.from(env.window.__mods), ["grid-2"]);
  bundle.cleanup();
});

test("the core admin bundle does not warn about a module's hooks: they are stubbed", () => {
  const env = publicPage();
  runSnippet(env, MODULE_STUBS);
  env.window.PhoenixKitAdminHooks = { GridSort: {} };
  env.load("phoenix_kit_admin.js");
  assert.deepEqual(plain(env.warnings), []);
});

// ── Retrying ───────────────────────────────────────────────────────────────

test("the admin bundle is asked for again after every failure, however many there have been", async () => {
  // The early start and the first mount are two failures already; a viewer
  // library would stop here. The admin hooks must not.
  const t = withFakeAdmin();
  const failures = [];
  const mountOne = () => {
    const hook = makeHook(t.env.window.PhoenixKitHooks.SortableGrid);
    hook.mounted();
    return hook;
  };

  for (let i = 0; i < 4; i++) {
    t.env.advance(RETRY_PAUSE_MS + 1);
    mountOne();
    assert.equal(t.env.scripts.length, i + 1, "mount " + (i + 1) + " makes its own request");
    t.env.failed(i);
    await tick();
    failures.push(t.env.errors.length);
  }
  assert.ok(failures.every((n, i) => n > (failures[i - 1] || 0)), "each failure is reported");

  // And the fifth attempt can succeed: the hook mounts.
  t.env.advance(RETRY_PAUSE_MS + 1);
  const hook = mountOne();
  assert.equal(t.env.scripts.length, 5);
  t.arrive2 = () => { t.env.load(fakeAdminFile(t)); t.env.loaded(4); };
  t.arrive2();
  await tick();
  assert.deepEqual(t.names(), ["SortableGrid.mounted"]);
  assert.equal(t.calls()[0][1], hook);
  t.cleanup();
});

function fakeAdminFile(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pk_admin_"));
  const file = path.join(dir, "fake_admin.js");
  fs.writeFileSync(file, fakeAdmin());
  return file;
}

test("mounts that overlap a failing request share it: one request, one failure", async () => {
  const t = withFakeAdmin();
  makeHook(t.env.window.PhoenixKitHooks.SortableGrid).mounted();
  makeHook(t.env.window.PhoenixKitHooks.RowMenu).mounted();
  makeHook(t.env.window.PhoenixKitHooks.ListFilter).mounted();
  assert.equal(t.env.scripts.length, 1);
  t.env.failed(0);
  await tick();

  assert.equal(t.env.errors.filter((m) => m.includes("hook did not start")).length, 3, "each hook says it went without");
  t.cleanup();
});

// ── Content-Security-Policy nonce ──────────────────────────────────────────

test("a script this bundle creates carries the nonce of the script that loaded the bundle", () => {
  const env = createEnv({ facts: FACTS });
  env.load("phoenix_kit.js", { src: "https://app.test/assets/vendor/phoenix_kit.js", nonce: "n0nce-123" });
  makeHook(env.window.PhoenixKitHooks.SortableGrid).mounted();

  assert.equal(env.scripts[0].nonce, "n0nce-123");
});

test("and none when the loading script had none", () => {
  const env = createEnv({ facts: FACTS });
  env.load("phoenix_kit.js", { src: "https://app.test/assets/vendor/phoenix_kit.js" });
  makeHook(env.window.PhoenixKitHooks.SortableGrid).mounted();

  assert.ok(!env.scripts[0].nonce);
});

// ── Hooks a module lists vs hooks its bundle exports ───────────────────────

// The compiler appends this check to the admin bundle for each admin module; the
// fixture is the exact text (the compiler's test asserts it is in the output).
const HOOKS_CHECK = fs.readFileSync(path.join(__dirname, "..", "fixtures", "admin_hooks_check.js"), "utf8");

test("a module whose bundle exports what it lists says nothing", () => {
  const env = publicPage();
  env.window.GridHooks = { GridSort: {} };
  runSnippet(env, HOOKS_CHECK);
  assert.deepEqual(plain(env.warnings), []);
});

test("a listed hook the bundle does not export is reported by name, module and global", () => {
  const env = publicPage();
  env.window.GridHooks = {};
  runSnippet(env, HOOKS_CHECK);

  assert.equal(env.warnings.length, 1);
  assert.match(env.warnings[0], /grid lists the admin hook GridSort/);
  assert.match(env.warnings[0], /window\.GridHooks does not export it/);
});

test("an exported hook nobody listed is reported too: it has no stub, so no page can mount it", () => {
  const env = publicPage();
  env.window.GridHooks = { GridSort: {}, GridUnlisted: {} };
  runSnippet(env, HOOKS_CHECK);

  assert.equal(env.warnings.length, 1);
  assert.match(env.warnings[0], /exports the hook GridUnlisted, which js_sources\/0 hooks: does not list/);
});

test("a stub whose hook is not in the bundle names the module's side of the mismatch", async () => {
  const env = publicPage();
  runSnippet(env, MODULE_STUBS);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pk_empty_admin_"));
  const file = path.join(dir, "empty_admin.js");
  // A bundle that loads but exports nothing under the listed name.
  fs.writeFileSync(file, "window.PhoenixKitAdminHooks = window.PhoenixKitAdminHooks || {};\nwindow.PhoenixKitAdminLoaded = true;\n");
  makeHook(env.window.PhoenixKitHooks.GridSort, { id: "g" }).mounted();
  env.load(file);
  env.loaded(0);
  await tick();

  const message = env.errors.join("\n");
  assert.match(message, /defines no hook named GridSort/);
  assert.match(message, /js_sources\/0 entry lists it in `hooks:`/);
  assert.match(message, /different PhoenixKit versions/);
  fs.rmSync(dir, { recursive: true, force: true });
});

// ── The pause after a failure ──────────────────────────────────────────────

test("right after a failure a mount is refused without a request, with the same console error", async () => {
  const t = withFakeAdmin();
  makeHook(t.env.window.PhoenixKitHooks.SortableGrid).mounted();
  t.env.failed(0);
  await tick();
  const reported = t.env.errors.length;

  // A page with many admin hooks: every one of them mounts in the pause.
  for (const name of ["RowMenu", "ListFilter", "SortableGrid"]) {
    makeHook(t.env.window.PhoenixKitHooks[name]).mounted();
  }
  await tick();

  assert.equal(t.env.scripts.length, 1, "no new request while the pause lasts");
  const refused = t.env.errors.slice(reported);
  assert.equal(refused.length, 3, "each refused hook says so");
  for (const [i, name] of ["RowMenu", "ListFilter", "SortableGrid"].entries()) {
    assert.ok(refused[i].includes(name) && refused[i].includes(ADMIN_URL), refused[i]);
  }
  assert.deepEqual(t.names(), []);
  t.cleanup();
});

test("the first mount after the pause asks again, and there is still no cap", async () => {
  const t = withFakeAdmin();
  makeHook(t.env.window.PhoenixKitHooks.SortableGrid).mounted();
  t.env.failed(0);
  await tick();

  t.env.advance(RETRY_PAUSE_MS - 1);
  makeHook(t.env.window.PhoenixKitHooks.RowMenu).mounted();
  await tick();
  assert.equal(t.env.scripts.length, 1, "one millisecond short of the pause: still refused");

  t.env.advance(1);
  makeHook(t.env.window.PhoenixKitHooks.RowMenu).mounted();
  assert.equal(t.env.scripts.length, 2, "the pause is over: a request");
  t.env.failed(1);
  await tick();

  // A second failure starts a new pause, and the next one ends it again.
  makeHook(t.env.window.PhoenixKitHooks.ListFilter).mounted();
  assert.equal(t.env.scripts.length, 2);
  t.env.advance(RETRY_PAUSE_MS);
  makeHook(t.env.window.PhoenixKitHooks.ListFilter).mounted();
  assert.equal(t.env.scripts.length, 3);
  t.cleanup();
});

test("a success is not followed by a pause", async () => {
  const t = withFakeAdmin();
  makeHook(t.env.window.PhoenixKitHooks.SortableGrid).mounted();
  t.arrive();
  await tick();

  makeHook(t.env.window.PhoenixKitHooks.RowMenu).mounted();
  await tick();
  assert.deepEqual(t.names(), ["SortableGrid.mounted", "RowMenu.mounted"]);
  t.cleanup();
});

// ── The nonce stays on the host's own copy ─────────────────────────────────

test("the CDN fallback does not borrow the nonce: it has to pass the host's allowlist on its own", async () => {
  const cdn = "https://cdn.example.test/admin-fallback.js";
  const env = createEnv({ facts: { admin: { file: "admin-3.0.0-cafebabe.js", cdn } } });
  env.load("phoenix_kit.js", { src: "https://app.test/assets/vendor/phoenix_kit.js", nonce: "n0nce-123" });
  makeHook(env.window.PhoenixKitHooks.SortableGrid).mounted();

  assert.equal(env.scripts[0].src, ADMIN_URL);
  assert.equal(env.scripts[0].nonce, "n0nce-123", "the host's own file has it");

  env.failed(0); // the local copy fails; the CDN is tried next
  assert.equal(env.scripts[1].src, cdn);
  assert.ok(!env.scripts[1].nonce, "the CDN copy has none");
});
