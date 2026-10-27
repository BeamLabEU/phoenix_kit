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

// Every hook `phoenix_kit.js` registered before the split (2.65.0). A hook
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

const FACTS = { admin: { file: "admin-2.65.0-cafebabe.js", cdn: null } };
const ADMIN_URL = "https://app.test/assets/vendor/lib/admin-2.65.0-cafebabe.js?vsn=d";

function publicPage(opts) {
  const env = createEnv(Object.assign({ facts: FACTS }, opts));
  env.load("phoenix_kit.js", { src: "https://app.test/assets/vendor/phoenix_kit.js" });
  return env;
}

const tick = () => new Promise((r) => setTimeout(r, 0));

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
