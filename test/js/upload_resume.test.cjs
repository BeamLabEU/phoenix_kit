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
  assert.match(report, /return row\.tab !== self\._tab && now - row\.touched > UPLOAD_STASH_STALE_MS;/,
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
