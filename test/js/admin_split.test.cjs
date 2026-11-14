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

// The fake bundles each test writes get a directory of their own; the file's last
// test is followed by their removal.
const tmpDirs = [];
function tmpDir(prefix) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  tmpDirs.push(dir);
  return dir;
}
test.after(() => {
  for (const dir of tmpDirs) fs.rmSync(dir, { recursive: true, force: true });
});

// Every hook `phoenix_kit.js` registered before the split (unchanged in 3.0.0), plus
// the ones added since (`RemovalModal`, #999; `UploadManager`, #1006; `AudioRecorder`, 3.4.0;
// `PasskeySignIn` and `PasskeyRegister`, the passkeys of the sign-in page and the Security tab; `NavTabsOverflow`,
// the opt-in overflow menu of `<.nav_tabs>`, admin until a page outside the admin area opts in; `Turnstile`, the
// Cloudflare bot check of the sign-up, magic-link, confirmation and password-reset forms). A hook
// that is neither listed as public nor as admin has been lost; one that is
// listed twice has been classified twice.
const PUBLIC = `LibraryLoadNotice CookieConsent FlashAutoDismiss TimezoneOffset TimezoneDetector
  LanguageSwitcherSearch LanguageSwitcherPosition PkDialog PkDialogTrigger PopupLink ResetSelect
  SelectOnMount TimeAgo CopyToClipboard FadeOut PreserveScroll InfiniteScroll PageSizeAutoFit
  MaintenanceCountdown PkShiftEnter PkUrlMirror PhoenixKitUrlState PkCheckboxIndeterminate PkDateInput
  PkChartCrosshair ViewportPopover Leaf FrescoViewer FrescoCanvas TesseraLayer EtcherLayer
  MentionInput UploadStats UploadGuard AudioRecorder PasskeySignIn PasskeyRegister Turnstile`.split(/\s+/);

const ADMIN = `SortableGrid MediaImageZoom MarkdownEditor InstantViewer ViewerKeydown ViewerPaneFit
  MediaViewerDialog PkHashHighlight BulkSelectScope TableLocalSearch AdminSidebarScroll PkDialogDraft
  AnnotationBurn EtcherTooltipActions AnnotationComposerPosition ListFilter TreePickerSearch CrumbSwitcher
  TableFit TableCardView RowMenu RowMenuAuto EmailCharts IntegrationPickerSearch MediaDragDrop EtcherReset
  ViewerSwipe ViewerGallery ViewerHiresLoading UploadResume UploadManager FolderDropUpload RemovalModal StackMemory StackExpand
  WaveformPlayer SearchPicker ContextMenu AvatarCrop ImageEditor NavTabsOverflow`.split(/\s+/);

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

test("the two lists are disjoint and together are the 79 hooks the bundle has", () => {
  assert.equal(PUBLIC.length, 38);
  assert.equal(ADMIN.length, 41);
  assert.deepEqual(PUBLIC.filter((n) => ADMIN.includes(n)), []);
});

test("every hook name is still registered after the public bundle alone has run", () => {
  const { window } = publicPage();
  for (const name of [...PUBLIC, ...ADMIN]) {
    assert.ok(window.PhoenixKitHooks[name], name + " must stay in PhoenixKitHooks: a host spreads it once");
    assert.equal(typeof window.PhoenixKitHooks[name].mounted, "function", name + " has a mounted()");
  }
  // And nothing else: a hook the bundle registers that neither list names (one main added, say) is
  // unclassified, and would otherwise be noticed by nothing but the size budget.
  assert.deepEqual(Array.from(Object.keys(window.PhoenixKitHooks)).sort(), [...PUBLIC, ...ADMIN].sort());
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

test("the media browser's box select stays out of the public file, bar the press it keeps for the admin file", () => {
  // The box select and Shift-click range listeners are installed on `document`
  // when their script loads, not by a hook, so the hook-name check above cannot
  // see them: pin the markers instead. The public file holds only the first
  // moments of a press (media_early_box.test.cjs), which the admin file replays.
  const pub = fs.readFileSync(PUBLIC_FILE, "utf8");
  const adm = fs.readFileSync(ADMIN_FILE, "utf8");
  for (const marker of ["function startBoxSelect(", "__pkPendingBox", "x-pk-batch", "box_select", "move_selected_to_folder"]) {
    assert.ok(!pub.includes(marker), marker + " is admin code: it belongs in phoenix_kit_admin.js");
    assert.ok(adm.includes(marker), marker + " is missing from phoenix_kit_admin.js");
  }
  for (const marker of ["__pkEarlyPress", "data-box-area"]) {
    assert.ok(pub.includes(marker) && adm.includes(marker), marker + " is how the two files hand a press over");
  }
  const from = pub.indexOf("// The first moments of a box select");
  const to = pub.indexOf("\n  }, true);\n", from);
  assert.ok(from !== -1 && to !== -1, "the early press listener is in the public file");
  assert.ok(to - from < 2800, "the public side is only a catcher (" + (to - from) + " bytes): the box logic is in the admin file");
});

test("the media browser hook starts through its stub; its document listeners arrive with the bundle", async () => {
  // The real admin file, not a stand-in: the hook keeps a handle to itself on its
  // element (`__pkBoxHook`) for the listeners that are installed on `document`.
  const env = publicPage();
  const added = [];
  const addListener = env.document.addEventListener;
  env.document.addEventListener = (name, fn, capture) => { added.push(name); return addListener(name, fn, capture); };
  const count = (name) => added.filter((n) => n === name).length;
  const root = env.makeEl("div");
  root.id = "media";
  const hook = makeHook(env.window.PhoenixKitHooks.MediaDragDrop, root);
  hook.mounted();
  const pointerdownBefore = count("pointerdown");
  const clickBefore = count("click");
  assert.equal(env.scripts.length, 1);

  env.load("phoenix_kit_admin.js");
  env.loaded(0);
  await tick();

  assert.ok(count("pointerdown") > pointerdownBefore, "the box select listener came with the bundle");
  assert.ok(count("click") > clickBefore, "so did the Shift-click range listener");
  assert.equal(root.__pkBoxHook, hook, "the element points at the LiveView's own hook instance");
  assert.deepEqual(plain(env.errors), []);
  hook.destroyed();
  assert.equal(root.__pkBoxHook, null, "the real destroyed() ran on the instance");
});

test("a media browser destroyed before the bundle arrives never mounts", async () => {
  const env = publicPage();
  const root = env.makeEl("div");
  root.id = "media";
  const hook = makeHook(env.window.PhoenixKitHooks.MediaDragDrop, root);
  hook.mounted();
  hook.destroyed();
  env.load("phoenix_kit_admin.js");
  env.loaded(0);
  await tick();
  assert.equal(root.__pkBoxHook, undefined);
  assert.deepEqual(plain(env.errors), []);
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
  // 288 KiB: the public half is about 286 KiB with the mention field, the two upload hooks (public pages
  // render them), the audio recorder, a public primitive that main added (15 KB, "any page can use"), the
  // retry and the menu restore of the stubs, and main's two passkey hooks (9.3 KB: core renders them on the
  // sign-in page and on the Security tab of the account settings, outside the admin area and the dashboard),
  // and main's Turnstile hook with its phoenix_kit:set_input listener (3.9 KB, the public auth forms).
  // The budget went 256 -> 272 KiB (the recorder), -> 280 (headroom for the next public hook from main),
  // -> 288 (main's passkey hooks). What it is for has not changed: an admin hook that lands in the public
  // file by mistake pushes it over (AvatarCrop alone is 13 158 B). A coarse backstop only: a small admin
  // hook would still fit in the margin, and it is the name checks above that catch one put in the wrong file
  // (or one that neither list names: the inventory test compares every registered hook with the two lists).
  assert.ok(publicBytes < 288 * 1024, "phoenix_kit.js is " + publicBytes + " bytes");
  assert.ok(adminBytes > publicBytes / 2, "the admin file is where the weight went");
});

// ── The stub ───────────────────────────────────────────────────────────────

// A stand-in admin bundle, so the stub's behaviour is tested without any real
// hook's logic in the way.
function fakeAdmin(calls, throwIn) {
  return (
    "window.PhoenixKitAdminHooks = window.PhoenixKitAdminHooks || {};\n" +
    "var calls = " + JSON.stringify([]) + ";\n" +
    "window.__calls = window.__calls || [];\n" +
    "function rec(name, self) { window.__calls.push([name, self]); }\n" +
    ["SortableGrid", "RowMenu", "ListFilter"].map((n) =>
      "window.PhoenixKitAdminHooks." + n + " = {\n" +
      "  mounted() { rec('" + n + ".mounted', this); " + (n === throwIn ? "throw new Error('boom in " + n + "'); " : "") + "this.handleEvent('ping', () => rec('" + n + ".event', this)); this.pushEvent('hello', {n: '" + n + "'}); },\n" +
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

function withFakeAdmin(throwIn) {
  const dir = tmpDir("pk_admin_");
  const file = path.join(dir, "fake_admin.js");
  fs.writeFileSync(file, fakeAdmin(undefined, throwIn));
  const env = publicPage();
  const arrive = () => { env.load(file); env.loaded(0); };
  const calls = () => env.window.__calls || [];
  const names = () => Array.from(calls(), (c) => c[0]);
  return { env, file, arrive, calls, names, cleanup: () => fs.rmSync(dir, { recursive: true, force: true }) };
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
  const dir = tmpDir("pk_admin_");
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
  const dir = tmpDir("pk_admin_");
  const file = path.join(dir, "fake_admin.js");
  fs.writeFileSync(file, fakeAdmin());
  t.env.load(file);
  t.env.loaded(1);
  await tick();

  // The mount that asked is the real hook, and so is the stub that had given up on the failed request.
  assert.deepEqual(t.names(), ["RowMenu.mounted", "SortableGrid.mounted"]);
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
  const dir = tmpDir("pk_mod_admin_");
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
  // The mount that asked, then the four that had given up on the earlier failures.
  assert.deepEqual(t.names(), new Array(5).fill("SortableGrid.mounted"));
  assert.equal(t.calls()[0][1], hook);
  t.cleanup();
});

function fakeAdminFile(t) {
  const dir = tmpDir("pk_admin_");
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
  const dir = tmpDir("pk_empty_admin_");
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

// ── A stub mounts synchronously once the bundle is there ──────────────────

// LiveView mounts the hooks of a diff and dispatches the diff's events in one
// synchronous stack. A hook that registers its `handleEvent` a microtask later
// misses an event pushed in the diff that mounted it.
test("with the bundle already loaded, a stub's real mounted() runs before mounted() returns", () => {
  const dir = tmpDir("pk_admin_");
  const file = path.join(dir, "fake_admin.js");
  fs.writeFileSync(file, fakeAdmin());
  const env = publicPage();
  env.load(file); // the bundle is here: a host that imported it, or an earlier mount fetched it
  const hook = makeHook(env.window.PhoenixKitHooks.SortableGrid);
  hook.mounted();

  assert.equal(typeof hook.handlers.ping, "function", "handleEvent is registered in the same turn");
  assert.deepEqual(plain(hook.pushed), [["hello", { n: "SortableGrid" }]]);
  hook.handlers.ping(); // the event of the very diff that mounted the hook
  assert.deepEqual(Array.from(env.window.__calls, (c) => c[0]), ["SortableGrid.mounted", "SortableGrid.event"]);
  assert.equal(hook.helper(), "h:SortableGrid", "the real hook's methods are on the instance");
  fs.rmSync(dir, { recursive: true, force: true });
});

test("a stub destroyed right after a synchronous mount still reaches the real destroyed()", () => {
  const dir = tmpDir("pk_admin_");
  const file = path.join(dir, "fake_admin.js");
  fs.writeFileSync(file, fakeAdmin());
  const env = publicPage();
  env.load(file);
  const hook = makeHook(env.window.PhoenixKitHooks.RowMenu);
  hook.mounted();
  hook.destroyed();

  assert.deepEqual(Array.from(env.window.__calls, (c) => c[0]), ["RowMenu.mounted", "RowMenu.destroyed"]);
  fs.rmSync(dir, { recursive: true, force: true });
});

// ── A stub that missed the bundle is revived by a retry ───────────────────

// A hook that mounts once and finds the bundle's request failed (or is refused
// during the pause after a failure) is not remounted by LiveView, so the page
// retries for it: after the pause, then at growing intervals, for as long as a
// stub is still waiting.
test("a stub whose request failed becomes the real hook when the retry after the pause gets the bundle", async () => {
  const t = withFakeAdmin();
  const hook = makeHook(t.env.window.PhoenixKitHooks.SortableGrid);
  hook.mounted();
  t.env.failed(0);
  await tick();

  assert.deepEqual(t.names(), []);
  assert.deepEqual(t.env.pendingTimers().map((x) => x.ms), [RETRY_PAUSE_MS], "one retry waits, a pause away");

  t.env.advance(RETRY_PAUSE_MS);
  t.env.runTimers();
  assert.equal(t.env.scripts.length, 2, "the retry asks for the bundle again");
  t.env.load(t.file);
  t.env.loaded(1);
  await tick();

  assert.deepEqual(t.names(), ["SortableGrid.mounted"], "the stub that had given up is the real hook now");
  assert.equal(typeof hook.handlers.ping, "function", "on the very instance LiveView made");
  assert.deepEqual(t.env.pendingTimers(), [], "nothing is left to retry");
  t.cleanup();
});

test("a mount refused during the pause is revived by the same retry", async () => {
  const t = withFakeAdmin();
  const first = makeHook(t.env.window.PhoenixKitHooks.SortableGrid);
  first.mounted();
  t.env.failed(0);
  await tick();
  const second = makeHook(t.env.window.PhoenixKitHooks.RowMenu);
  second.mounted(); // inside the pause: refused without a request
  await tick();
  assert.equal(t.env.scripts.length, 1);
  assert.equal(t.env.pendingTimers().length, 1, "both wait on one timer");

  t.env.advance(RETRY_PAUSE_MS);
  t.env.runTimers();
  t.env.load(t.file);
  t.env.loaded(1);
  await tick();

  assert.deepEqual(t.names(), ["SortableGrid.mounted", "RowMenu.mounted"]);
  t.cleanup();
});

test("a stub destroyed while it waits for a retry never mounts, and a retry with nobody waiting asks for nothing", async () => {
  const t = withFakeAdmin();
  const hook = makeHook(t.env.window.PhoenixKitHooks.SortableGrid);
  hook.mounted();
  t.env.failed(0);
  await tick();
  assert.equal(t.env.pendingTimers().length, 1, "a retry is waiting for it");
  hook.destroyed();

  t.env.advance(RETRY_PAUSE_MS);
  t.env.runTimers();
  assert.equal(t.env.scripts.length, 1, "no request for a page that has no stub left");
  assert.deepEqual(t.env.pendingTimers(), []);
  assert.deepEqual(t.names(), []);
  t.cleanup();
});

test("each failed retry waits twice as long as the one before, up to a minute", async () => {
  const t = withFakeAdmin();
  makeHook(t.env.window.PhoenixKitHooks.SortableGrid).mounted();
  t.env.failed(0);
  await tick();

  const waits = [];
  for (let i = 1; i <= 7; i++) {
    const [timer] = t.env.pendingTimers();
    waits.push(timer.ms);
    t.env.advance(timer.ms);
    t.env.runTimers();
    t.env.failed(i);
    await tick();
  }
  assert.deepEqual(waits, [4000, 8000, 16000, 32000, 60000, 60000, 60000]);
  t.cleanup();
});

test("a bundle that arrives through another mount's request revives the waiting stubs and stops the timer", async () => {
  const t = withFakeAdmin();
  const waiting = makeHook(t.env.window.PhoenixKitHooks.SortableGrid);
  waiting.mounted();
  t.env.failed(0);
  await tick();

  t.env.advance(RETRY_PAUSE_MS + 1); // the pause is over; the timer has not fired yet
  makeHook(t.env.window.PhoenixKitHooks.ListFilter).mounted(); // asks again at once
  assert.equal(t.env.scripts.length, 2);
  t.env.load(t.file);
  t.env.loaded(1);
  await tick();

  assert.deepEqual(t.names().sort(), ["ListFilter.mounted", "SortableGrid.mounted"]);
  assert.deepEqual(t.env.pendingTimers(), [], "the retry that was waiting is gone");
  t.cleanup();
});


// ── The early start waits for the install facts ───────────────────────────

// A host that defers both tags runs phoenix_kit.js at readyState "interactive",
// before a slower phoenix_kit_modules.js (the facts) has run. Asking for the
// admin bundle then fails on facts that are late, not missing, and the pause
// after the failure refuses the first real mounts.
test("an early start that finds the facts not there yet neither complains nor opens a pause", async () => {
  const env = createEnv({ readyState: "interactive", adminLayout: true }); // no facts yet
  env.load("phoenix_kit.js", { src: "https://app.test/assets/vendor/phoenix_kit.js" });
  await new Promise((r) => setTimeout(r, 5)); // the setTimeout(0) of the early start

  assert.equal(env.scripts.length, 0);
  assert.deepEqual(env.errors, [], "late facts are not a failure to report");

  env.window.PHOENIX_KIT_LIBS = FACTS; // the deferred facts file runs
  makeHook(env.window.PhoenixKitHooks.SortableGrid).mounted();
  assert.equal(env.scripts.length, 1, "the first mount asks for the bundle: no pause was opened");
  assert.equal(env.scripts[0].src, ADMIN_URL);
});

test("and the early start still happens, once the document has been parsed and the facts are there", async () => {
  const env = createEnv({ readyState: "interactive", adminLayout: true });
  env.load("phoenix_kit.js", { src: "https://app.test/assets/vendor/phoenix_kit.js" });
  await new Promise((r) => setTimeout(r, 5));
  assert.equal(env.scripts.length, 0);

  env.window.PHOENIX_KIT_LIBS = FACTS;
  env.fireDocument("DOMContentLoaded");
  assert.equal(env.scripts.length, 1);
  assert.equal(env.scripts[0].src, ADMIN_URL);
  assert.deepEqual(env.errors, []);
});

test("a mount that finds no facts says so, but opens no pause: the facts may still arrive", async () => {
  const env = createEnv({}); // a complete page without facts
  env.load("phoenix_kit.js", { src: "https://app.test/assets/vendor/phoenix_kit.js" });
  makeHook(env.window.PhoenixKitHooks.SortableGrid).mounted();
  await tick();
  assert.ok(env.errors.some((m) => m.includes("SortableGrid")), "the hook that went without is named");
  assert.equal(env.scripts.length, 0, "nothing to request");

  env.window.PHOENIX_KIT_LIBS = FACTS;
  makeHook(env.window.PhoenixKitHooks.RowMenu).mounted();
  assert.equal(env.scripts.length, 1, "not refused by a pause that protects no request");
});

test("a stub that mounted before the late facts arrived becomes the real hook at the retry", async () => {
  const dir = tmpDir("pk_admin_");
  const file = path.join(dir, "fake_admin.js");
  fs.writeFileSync(file, fakeAdmin());
  const env = createEnv({});
  env.load("phoenix_kit.js", { src: "https://app.test/assets/vendor/phoenix_kit.js" });
  const hook = makeHook(env.window.PhoenixKitHooks.SortableGrid);
  hook.mounted();
  await tick();
  assert.equal(env.pendingTimers().length, 1, "it waits for a retry");

  env.window.PHOENIX_KIT_LIBS = FACTS; // the facts file has run since
  env.advance(RETRY_PAUSE_MS);
  env.runTimers();
  assert.equal(env.scripts.length, 1);
  env.load(file);
  env.loaded(0);
  await tick();

  assert.deepEqual(Array.from(env.window.__calls, (c) => c[0]), ["SortableGrid.mounted"]);
  assert.equal(typeof hook.handlers.ping, "function");
  fs.rmSync(dir, { recursive: true, force: true });
});

// ── One hook that throws does not strand the others ──────────────────────

// The stubs that gave up are taken off the waiting list before they are mounted, so a real
// mounted() that threw in the middle of the loop would leave the rest on no list at all.
test("a real mounted() that throws is reported by name and does not strand the stubs that wait behind it", async () => {
  const t = withFakeAdmin("RowMenu");
  const hooks = ["SortableGrid", "RowMenu", "ListFilter"].map((n) => makeHook(t.env.window.PhoenixKitHooks[n]));
  hooks[0].mounted();
  t.env.failed(0);
  await tick();
  hooks[1].mounted(); // refused in the pause
  hooks[2].mounted();
  await tick();

  t.env.advance(RETRY_PAUSE_MS);
  t.env.runTimers();
  t.env.load(t.file);
  t.env.loaded(1);
  await tick();

  assert.deepEqual(t.names(), ["SortableGrid.mounted", "RowMenu.mounted", "ListFilter.mounted"], "the third still mounted");
  assert.ok(t.env.errors.some((m) => m.includes("RowMenu") && m.includes("boom in RowMenu")), JSON.stringify(t.env.errors));
  t.cleanup();
});

test("and the mount that fetched the bundle may throw without stranding the stubs that were waiting", async () => {
  const t = withFakeAdmin("ListFilter");
  const waiting = makeHook(t.env.window.PhoenixKitHooks.SortableGrid);
  waiting.mounted();
  t.env.failed(0);
  await tick();

  t.env.advance(RETRY_PAUSE_MS + 1);
  makeHook(t.env.window.PhoenixKitHooks.ListFilter).mounted(); // asks again, and its real mounted throws
  t.env.load(t.file);
  t.env.loaded(1);
  await tick();

  assert.deepEqual(t.names().sort(), ["ListFilter.mounted", "SortableGrid.mounted"]);
  assert.equal(typeof waiting.handlers.ping, "function");
  t.cleanup();
});

test("with the bundle loaded, a throwing mounted() does not stop the waiting stubs either", () => {
  const dir = tmpDir("pk_admin_");
  const file = path.join(dir, "fake_admin.js");
  fs.writeFileSync(file, fakeAdmin(undefined, "RowMenu"));
  const env = publicPage();
  env.load(file);
  assert.doesNotThrow(() => makeHook(env.window.PhoenixKitHooks.RowMenu).mounted());
  assert.ok(env.errors.some((m) => m.includes("RowMenu")));
  fs.rmSync(dir, { recursive: true, force: true });
});

// ── A bundle that loads but throws while running is not run again ────────

// The browser fires `load` for a script that threw, so the loader sees "loaded, but the hooks are
// not there" and used to take it for a transient failure. Retrying a transport failure is right; an
// error in the file will not heal, and every run executes the top-level code that already ran (a
// document listener each time).
test("a bundle that loads but throws while running is reported once and never run again", async () => {
  const dir = tmpDir("pk_admin_");
  const file = path.join(dir, "throwing_admin.js");
  fs.writeFileSync(file, "document.addEventListener('scroll', function() {}, true);\nthrow new Error('version skew');\n");
  const env = publicPage();
  const listeners = env.listenerCount("document", "scroll");
  const hook = makeHook(env.window.PhoenixKitHooks.SortableGrid);
  hook.mounted();
  try { env.load(file); } catch (_e) { /* the browser reports it and still fires load */ }
  env.loaded(0);
  await tick();

  assert.equal(env.listenerCount("document", "scroll"), listeners + 1, "ran once");
  assert.deepEqual(env.pendingTimers(), [], "no retry is scheduled for an error that will not go away");
  assert.ok(env.errors.some((m) => m.includes("SortableGrid") && m.includes("while running")),
    "the hook that went without is named: " + JSON.stringify(env.errors));

  // Nor does a later mount, after the pause, fetch and run it again.
  env.advance(RETRY_PAUSE_MS + 1);
  makeHook(env.window.PhoenixKitHooks.RowMenu).mounted();
  await tick();
  env.advance(60000);
  env.runTimers();
  assert.equal(env.scripts.length, 1, "one request, for the life of the page");
  assert.ok(env.errors.some((m) => m.includes("RowMenu")), "the later mount is told as well");
  fs.rmSync(dir, { recursive: true, force: true });
});

test("a failed request (the file is not there) is still retried: only a run that threw is final", async () => {
  const t = withFakeAdmin();
  makeHook(t.env.window.PhoenixKitHooks.SortableGrid).mounted();
  t.env.failed(0);
  await tick();
  assert.equal(t.env.pendingTimers().length, 1);
  t.cleanup();
});

test("an admin file next to a phoenix_kit.js that predates what it reads says so, before it registers anything", () => {
  const env = publicPage();
  delete env.window.PhoenixKitInternals.sidebarScroll; // an older phoenix_kit.js
  const listeners = env.listenerCount("document", "scroll");

  assert.throws(() => env.load("phoenix_kit_admin.js"), /different PhoenixKit versions/);
  assert.equal(env.listenerCount("document", "scroll"), listeners, "no listener was left behind");
  assert.ok(!env.window.PhoenixKitAdminLoaded);
  assert.deepEqual(Object.keys(env.window.PhoenixKitAdminHooks || {}), [], "no hook was registered");
});

// ── A class-based hook cannot stand behind a stub ─────────────────────────

// A stub is an object of callbacks copied onto the hook LiveView made; a class has none of its own
// to copy (`Object.keys` of it is its statics), so such a hook used to do nothing, silently.
test("a hook exported as a class says so by name instead of silently doing nothing", async () => {
  const dir = tmpDir("pk_admin_");
  const file = path.join(dir, "class_admin.js");
  fs.writeFileSync(file,
    "window.PhoenixKitAdminHooks = window.PhoenixKitAdminHooks || {};\n" +
    "window.PhoenixKitAdminHooks.SortableGrid = class { mounted() { window.__ran = true; } };\n" +
    "window.PhoenixKitAdminLoaded = true;\n");
  const env = publicPage();
  makeHook(env.window.PhoenixKitHooks.SortableGrid).mounted();
  env.load(file);
  env.loaded(0);
  await tick();

  const message = env.errors.find((m) => m.includes("SortableGrid"));
  assert.ok(message, JSON.stringify(env.errors));
  assert.match(message, /class/);
  assert.match(message, /object of callbacks/);
  assert.ok(!env.window.__ran, "and it did not run");
  fs.rmSync(dir, { recursive: true, force: true });
});
