// UploadResume: picked files are kept in the browser (IndexedDB) until the
// server says it has the bytes, so a transfer cut short by a refresh, a
// closed tab or a dropped connection can be resumed instead of lost.
//
// What has to hold between this hook and the server:
//   - the file key is the same three fields the server's `client_key/1`
//     reads off an upload entry (name | size | lastModified);
//   - the three pushed events, and the one reported back, use the names the
//     server pushes and handles;
//   - a reconnect counts this tab's in-flight files as leftovers (upload
//     channels die with the socket), and stale records from other tabs are
//     never mistaken for this tab's live ones;
//   - the server answers a report with the keys to send again (`auto`), and
//     the hook sends exactly those, once, flagged for the upload manager.
//
//   node --test test/js/upload_resume.test.cjs

const fs = require("fs");
const path = require("path");
const assert = require("node:assert");
const { test } = require("node:test");
const mediaBrowserDir = path.join(__dirname, "..", "..", "lib", "phoenix_kit_web", "components", "media_browser");
// The browser is split across modules (media_browser.ex, and its view,
// sections and helpers under media_browser/): read them all.
function mediaBrowserSource(ext) {
  const files = fs.readdirSync(mediaBrowserDir).filter((f) => f.endsWith(ext)).map((f) => path.join(mediaBrowserDir, f));
  if (ext === ".ex") files.unshift(path.join(mediaBrowserDir, "..", "media_browser.ex"));
  return files.map((f) => fs.readFileSync(f, "utf8")).join("\n");
}

const root = path.join(__dirname, "..", "..");
const src = fs.readFileSync(path.join(root, "priv", "static", "assets", "phoenix_kit.js"), "utf8");
const server = mediaBrowserSource(".ex");

function section() {
  const start = src.indexOf("// UploadResume — keep picked files until the server has them");
  const end = src.indexOf("// FolderDropUpload Hook");
  assert.ok(start !== -1 && end > start, "could not find the UploadResume section");
  return src.slice(start, end);
}

const hook = section();

function sliceFn(name) {
  const start = hook.indexOf("function " + name + "(");
  assert.ok(start !== -1, "could not find " + name);
  let i = hook.indexOf("{", start);
  let depth = 0;
  for (; i < hook.length; i++) {
    if (hook[i] === "{") depth++;
    else if (hook[i] === "}" && --depth === 0) return hook.slice(start, i + 1);
  }
  throw new Error("unclosed " + name);
}

test("the file key matches the server's client_key/1 field for field", () => {
  const key = new Function(sliceFn("uploadStashKey") + "\nreturn uploadStashKey;")();
  assert.strictEqual(key({ name: "a b.png", size: 1234, lastModified: 1700000000000 }),
    "a b.png|1234|1700000000000");
  assert.match(server,
    /def client_key\(entry\),\s*do: "#\{entry\.client_name\}\|#\{entry\.client_size\}\|#\{entry\.client_last_modified\}"/,
    "the server builds its key from the same three fields, in the same order");
});

test("every event the server pushes is one the hook handles, and vice versa", () => {
  for (const ev of ["phoenix_kit:upload-received", "phoenix_kit:upload-discard", "phoenix_kit:upload-resume"]) {
    assert.ok(hook.includes(`this.handleEvent("${ev}"`), `the hook handles ${ev}`);
    assert.ok(server.includes(`"${ev}"`), `the server pushes ${ev}`);
  }
  assert.ok(hook.includes('"upload_resume_available"'), "the hook reports leftovers");
  assert.ok(server.includes('def handle_event("upload_resume_available"'),
    "and the component handles the report");
});

test("files are captured before LiveView reads (and the drop hook replaces) them", () => {
  assert.match(hook, /addEventListener\("input", this\._onPick, true\)/,
    "capture phase on the browser root");
  assert.match(hook, /input\.hasAttribute\("data-phx-upload-ref"\)/,
    "only LiveView upload inputs — never some other file field on the page");
});

test("a reconnect turns this tab's in-flight files into leftovers", () => {
  assert.match(hook, /reconnected\(\) \{[\s\S]*?this\._reportLeftovers\(true\);/);
  const report = hook.slice(hook.indexOf("_reportLeftovers(mine) {"));
  assert.match(report, /if \(mine\) return row\.tab === self\._tab && self\._live\[row\.key\];/,
    "after a reconnect: this tab's own live records");
  assert.match(report, /if \(now - row\.touched > UPLOAD_STASH_STALE_MS\) return true;/,
    "otherwise: only other page loads' records nobody has touched lately");
});

test("a huge file keeps its name but not its bytes", () => {
  assert.match(hook, /var keep = file\.size <= UPLOAD_STASH_MAX_BYTES;/);
  assert.match(hook, /blob: keep \? file : null/);
  assert.match(hook, /blob: !!row\.blob/, "the server is told which leftovers can be resumed");
});

test("resume feeds files back through the input the way a drop does", () => {
  const resume = hook.slice(hook.indexOf("_resume(keys, auto) {"));
  assert.match(resume, /new File\(\[row\.blob\], row\.name, \{ type: row\.type, lastModified: row\.lastModified \}\)/,
    "same name and lastModified, so the re-sent file has the same key");
  assert.match(resume, /input\.files = dt\.files;\s*var ev = new Event\("input", \{ bubbles: true \}\);\s*ev\.__pkUploadResume = true;\s*input\.dispatchEvent\(ev\);/);
});

// ---------------------------------------------------------------------------
// The hook run for real, against a fake store and a fake clock.
// ---------------------------------------------------------------------------

function runHook({ rows, pathname = "/admin/media", search = "", user = "u1", browser, picker }) {
  let clock = 1_000_000;
  const timers = [];
  const store = { rows: rows || [], deleted: [], put: [] };
  const win = {
    PhoenixKitHooks: {},
    location: { pathname, search },
    addEventListener() {},
  };
  const code = hook
    .replace("function uploadStashAll()", "function uploadStashAllOrig()")
    .replace("function uploadStashRun(", "function uploadStashRunOrig(") +
    `
    function uploadStashAll() { return Promise.resolve(store.rows.slice()); }
    function uploadStashRun(mode, fn) {
      return Promise.resolve(fn({
        put: (r) => { store.put.push(r); store.rows.push(r); },
        delete: (id) => { store.deleted.push(id); },
        get: () => ({}),
      }));
    }
    return window.PhoenixKitHooks.UploadResume;`;
  const Hook = new Function("window", "store", "Date", "setTimeout", "clearTimeout",
    "setInterval", "clearInterval", "document", code)(
    win, store, { now: () => clock },
    (fn, ms) => { const t = { fn, ms, at: clock + ms }; timers.push(t); return t; },
    (t) => { if (t) t.cleared = true; },
    () => ({}), () => {}, {});
  const pushed = [];
  const ctx = Object.assign(Object.create(Hook), {
    el: { dataset: Object.assign({ user }, picker ? { browser, picker: "true" } : {}), parentElement: { addEventListener() {}, removeEventListener() {} } },
    handleEvent() {},
    pushEventTo: (_el, name, payload) => pushed.push({ name, payload }),
  });
  ctx._tab = "this-tab";
  ctx._user = user;
  ctx._browser = picker ? browser : "";
  ctx._picker = !!picker;
  ctx._scopes = {};
  ctx._live = {};
  ctx._fed = {};
  ctx._writing = 0;
  ctx._lookAfterWrite = false;
  return { ctx, win, store, timers, pushed, tick: (ms) => { clock += ms; }, now: () => clock };
}

const settle = () => new Promise((r) => setImmediate(r));

test("a quick refresh: a fresh record of the last page load is looked for again once it has gone stale", async () => {
  const h = runHook({});
  const scope = h.ctx._scopeNow();
  h.store.rows.push({ id: scope + "\0k", key: "k", scope, name: "a.jpg", size: 1,
                      blob: {}, tab: "old-tab", touched: h.now() - 1000 });

  h.ctx._reportLeftovers(false);
  await settle();
  assert.deepStrictEqual(h.pushed, [], "still fresh: the old page may be uploading it");
  const timer = h.timers.find((t) => !t.cleared && t.ms > 10000 && t.ms < 20000);
  assert.ok(timer, "…but a second look is scheduled for when it would be stale");

  h.tick(timer.ms);
  timer.fn();
  await settle();
  assert.strictEqual(h.pushed.length, 1, "nobody touched it since: it is a leftover");
  assert.strictEqual(h.pushed[0].name, "upload_resume_available");
  assert.strictEqual(h.pushed[0].payload.items[0].key, "k");
});

test("a library switch moves where new picks are stashed, not where old ones are acknowledged", async () => {
  const h = runHook({ pathname: "/admin/media/my/private" });
  const file = (name) => ({ name, size: 5, lastModified: 7, type: "image/png" });

  h.ctx._stash([file("one.png")]);
  const first = h.store.put[0].scope;
  assert.match(first, /^\/admin\/media\/my\/private\0/);

  // The same LiveView is patched to another library.
  h.win.location.pathname = "/admin/media";
  h.ctx._stash([file("two.png")]);
  const second = h.store.put[1].scope;
  assert.match(second, /^\/admin\/media\0/);
  assert.notStrictEqual(first, second, "picks after the switch belong to the new library");

  h.ctx._forget(["one.png|5|7"]);
  await settle();
  assert.deepStrictEqual(h.store.deleted, [first + "\0one.png|5|7"],
    "the acknowledgement names the record under the scope it was picked in");
});

test("a folder is part of the scope, and so is the user", () => {
  const a = runHook({ search: "?folder=f1", user: "u1" }).ctx._scopeNow();
  const b = runHook({ search: "?folder=f2", user: "u1" }).ctx._scopeNow();
  const c = runHook({ search: "?folder=f1", user: "u2" }).ctx._scopeNow();
  assert.notStrictEqual(a, b);
  assert.notStrictEqual(a, c);
});

test("a picker's stash and events are its own; the browser beside it keeps its scope", async () => {
  const plain = runHook({});
  const pickA = runHook({ browser: "pick-a", picker: true });
  const pickB = runHook({ browser: "pick-b", picker: true });

  assert.ok(!plain.ctx._scopeNow().includes("pick"), "a browser that is not a picker: the scope it always had");
  assert.notStrictEqual(pickA.ctx._scopeNow(), plain.ctx._scopeNow());
  assert.notStrictEqual(pickA.ctx._scopeNow(), pickB.ctx._scopeNow());

  // What the server pushes: a picker names itself, any other browser does not.
  assert.strictEqual(plain.ctx._mine({ keys: ["k"] }), true);
  assert.strictEqual(plain.ctx._mine({ browser: "pick-a", keys: ["k"] }), false);
  assert.strictEqual(pickA.ctx._mine({ browser: "pick-a", keys: ["k"] }), true);
  assert.strictEqual(pickA.ctx._mine({ browser: "pick-b", keys: ["k"] }), false);
  assert.strictEqual(pickA.ctx._mine({ keys: ["k"] }), false);
});

test("Resume in one browser feeds no file to the other, and leftovers go only to their owner", async () => {
  const plain = runHook({});
  const pick = runHook({ browser: "pick-a", picker: true });
  const shared = [];
  const row = (h, k) => ({ id: h.ctx._scopeNow() + "\0" + k, key: k, scope: h.ctx._scopeNow(),
                           name: k, size: 1, blob: {}, tab: "old", touched: 0 });
  shared.push(row(plain, "plain.png"), row(pick, "picked.png"));
  plain.store.rows.push(...shared);
  pick.store.rows.push(...shared);

  plain.ctx._reportLeftovers(false);
  pick.ctx._reportLeftovers(false);
  await settle();

  assert.deepStrictEqual(plain.pushed[0].payload.items.map((i) => i.key), ["plain.png"]);
  assert.deepStrictEqual(pick.pushed[0].payload.items.map((i) => i.key), ["picked.png"]);
});

// ---------------------------------------------------------------------------
// Sending leftovers again without a click: the server names the keys.
// ---------------------------------------------------------------------------

// The pieces of the browser `_resume` touches: a File that remembers what it
// was made from, a DataTransfer, and an Event.
class FakeFile {
  constructor(parts, name, opts) { this.parts = parts; this.name = name; this.type = opts.type; this.lastModified = opts.lastModified; }
}
class FakeTransfer {
  constructor() { this.list = []; this.items = { add: (f) => this.list.push(f) }; }
  get files() { return this.list; }
}

function withBrowser(fn) {
  const saved = { File: globalThis.File, DataTransfer: globalThis.DataTransfer };
  globalThis.File = FakeFile;
  globalThis.DataTransfer = FakeTransfer;
  return Promise.resolve(fn()).finally(() => {
    globalThis.File = saved.File;
    if (saved.DataTransfer === undefined) delete globalThis.DataTransfer; else globalThis.DataTransfer = saved.DataTransfer;
  });
}

function leftover(h, key, extra = {}) {
  const scope = h.ctx._scopeNow();
  const [name] = key.split("|");
  return Object.assign({ id: scope + "\0" + key, key, scope, name, type: "image/png", size: 5, lastModified: 7,
                         blob: { bytes: key }, tab: "old-tab", touched: 0 }, extra);
}

function withInput(h) {
  const input = { events: [], dispatchEvent(ev) { this.events.push(ev); }, files: null };
  h.ctx._root = { querySelector: () => input, addEventListener() {}, removeEventListener() {} };
  return input;
}

test("the server names the keys; the hook feeds those, flagged as a resume, and only those", async () => {
  await withBrowser(async () => {
    const h = runHook({});
    const input = withInput(h);
    h.store.rows.push(leftover(h, "a.png|5|7"), leftover(h, "b.png|5|7"), leftover(h, "c.png|5|7", { blob: null }));

    h.ctx._resume(["a.png|5|7", "c.png|5|7"], true);
    await settle();

    assert.deepStrictEqual(input.files.map((f) => f.name), ["a.png"], "b was not named; c has no bytes to send");
    assert.strictEqual(input.files[0].lastModified, 7, "the same key as before");
    assert.strictEqual(input.events.length, 1);
    assert.strictEqual(input.events[0].type, "input");
    assert.strictEqual(input.events[0].__pkUploadResume, true, "the upload manager is told it is a resume");
    assert.deepStrictEqual(h.pushed, [], "fed: nothing to hand back");
  });
});

test("the events the server pushes reach _resume with `auto` only when it says so", () => {
  const h = runHook({});
  const handlers = {};
  h.ctx.handleEvent = (name, fn) => { handlers[name] = fn; };
  h.ctx.mounted();
  const calls = [];
  h.ctx._resume = (keys, auto) => calls.push({ keys, auto });

  handlers["phoenix_kit:upload-resume"]({ keys: ["k"], auto: true });
  handlers["phoenix_kit:upload-resume"]({ keys: ["j"] });
  handlers["phoenix_kit:upload-resume"]({ keys: ["x"], auto: true, browser: "some-picker" });
  assert.deepStrictEqual(calls, [{ keys: ["k"], auto: true }, { keys: ["j"], auto: false }]);
});

test("a feed that cannot happen is handed back to the server for the Resume button", async () => {
  await withBrowser(async () => {
    const h = runHook({});
    h.ctx._root = { querySelector: () => null, addEventListener() {}, removeEventListener() {} };
    h.store.rows.push(leftover(h, "a.png|5|7"));

    h.ctx._resume(["a.png|5|7"], true);
    await settle();

    assert.strictEqual(h.pushed.length, 1);
    assert.strictEqual(h.pushed[0].name, "upload_resume_available");
    assert.deepStrictEqual(h.pushed[0].payload.items,
      [{ key: "a.png|5|7", name: "a.png", size: 5, blob: true, manual: true }]);
    assert.ok(!h.ctx._fed["a.png|5|7"], "nothing was fed");
  });
});

test("a click on Resume that cannot feed stays as quiet as it was", async () => {
  await withBrowser(async () => {
    const h = runHook({});
    h.ctx._root = { querySelector: () => null, addEventListener() {}, removeEventListener() {} };
    h.store.rows.push(leftover(h, "a.png|5|7"));
    h.ctx._resume(["a.png|5|7"], false);
    await settle();
    assert.deepStrictEqual(h.pushed, []);
  });
});

test("a file fed back is not offered again by a later look, until it is acknowledged", async () => {
  await withBrowser(async () => {
    const h = runHook({});
    withInput(h);
    h.store.rows.push(leftover(h, "a.png|5|7"));

    h.ctx._resume(["a.png|5|7"], true);
    await settle();
    // The record is still the old page load's (its rewrite has not landed).
    h.ctx._reportLeftovers(false);
    await settle();
    assert.deepStrictEqual(h.pushed, [], "it is on its way");

    h.ctx._forget(["a.png|5|7"]);
    h.store.rows.push(leftover(h, "a.png|5|7"));
    h.ctx._reportLeftovers(false);
    await settle();
    assert.strictEqual(h.pushed.length, 1, "after the acknowledgement it is an ordinary leftover again");
  });
});

test("a reconnect forgets what was fed: the transfer it started died with the socket", async () => {
  const h = runHook({});
  h.ctx._fed["a.png|5|7"] = true;
  h.ctx.reconnected();
  assert.deepStrictEqual(h.ctx._fed, {});
});

test("a pick written while the reconnect looked is looked for once the write is over — and an ordinary pick causes no look", async () => {
  const h = runHook({});
  const looks = [];
  h.ctx._reportLeftovers = (mine) => looks.push(mine);
  const file = (name) => ({ name, size: 5, lastModified: 7, type: "image/png" });

  h.ctx._stash([file("plain.png")]);
  await settle();
  assert.deepStrictEqual(looks, [], "no reconnect, no look: the page is sending it itself");

  h.ctx._stash([file("camera.png")]);
  h.ctx.reconnected();
  assert.deepStrictEqual(looks, [true], "the reconnect's own look");
  await settle();
  assert.deepStrictEqual(looks, [true, true], "and one more, once the write is done");

  h.ctx._stash([file("later.png")]);
  await settle();
  assert.deepStrictEqual(looks, [true, true], "only once");
});

test("a file cancelled in the upload manager is let go of", async () => {
  const h = runHook({});
  const listeners = {};
  h.ctx.handleEvent = () => {};
  h.ctx.el.parentElement = { addEventListener: (n, fn) => { listeners[n] = fn; }, removeEventListener() {} };
  h.ctx.mounted();
  h.ctx._tab = "this-tab";

  h.ctx._live["a.png|5|7"] = true;
  h.ctx._scopes["a.png|5|7"] = h.ctx._scopeNow();
  listeners["pk-upload:cancelled"]({ detail: { keys: ["a.png|5|7"] } });
  await settle();

  assert.deepStrictEqual(h.store.deleted, [h.ctx._scopeNow() + "\0a.png|5|7"]);
  assert.ok(!h.ctx._live["a.png|5|7"]);
});

test("the server and the hook agree on the new wire: auto resume, discard, manual hand-back", () => {
  assert.match(server, /push_resume_keys\("phoenix_kit:upload-resume", resend, %\{auto: true\}\)/);
  assert.match(server, /push_resume_keys\("phoenix_kit:upload-discard", taken\)/);
  assert.match(server, /&\(&1\["manual"\] == true\)/);
  assert.match(hook, /manual: true/);
});
