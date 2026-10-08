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
//     never mistaken for this tab's live ones.
//
//   node --test test/js/upload_resume.test.cjs

const fs = require("fs");
const path = require("path");
const assert = require("node:assert");
const { test } = require("node:test");

const root = path.join(__dirname, "..", "..");
const src = fs.readFileSync(path.join(root, "priv", "static", "assets", "phoenix_kit.js"), "utf8");
const server = fs.readFileSync(
  path.join(root, "lib", "phoenix_kit_web", "components", "media_browser.ex"), "utf8");

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
  assert.match(hook, /reconnected\(\) \{\s*this\._reportLeftovers\(true\);/);
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
  const resume = hook.slice(hook.indexOf("_resume(keys) {"));
  assert.match(resume, /new File\(\[row\.blob\], row\.name, \{ type: row\.type, lastModified: row\.lastModified \}\)/,
    "same name and lastModified, so the re-sent file has the same key");
  assert.match(resume, /input\.files = dt\.files;\s*input\.dispatchEvent\(new Event\("input", \{ bubbles: true \}\)\);/);
});

// ---------------------------------------------------------------------------
// The hook run for real, against a fake store and a fake clock.
// ---------------------------------------------------------------------------

function runHook({ rows, pathname = "/admin/media", search = "", user = "u1" }) {
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
    el: { dataset: { user }, parentElement: { addEventListener() {}, removeEventListener() {} } },
    handleEvent() {},
    pushEventTo: (_el, name, payload) => pushed.push({ name, payload }),
  });
  ctx._tab = "this-tab";
  ctx._user = user;
  ctx._scopes = {};
  ctx._live = {};
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
