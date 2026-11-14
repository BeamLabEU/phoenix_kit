// Pins the OS drag-drop upload's input lookup.
//
// A file dropped on the media browser is injected into the LiveView
// upload input ([data-phx-upload-ref]). The lookup must WALK outward to
// the nearest scope that contains one: it used to be a hard
// closest(".flex-1") hop, which silently broke when a second flex-1
// wrapper landed between the drop area and the hidden upload form —
// closest() resolved to the inner wrapper, found no input, and every OS
// drop no-opped after the retry loop gave up.
//
//   node --test test/js/folder_drop_upload.test.cjs

const fs = require("fs");
const path = require("path");
const assert = require("node:assert");
const { test } = require("node:test");

const SOURCE = path.join(__dirname, "..", "..", "priv", "static", "assets", "phoenix_kit_admin.js");
const src = fs.readFileSync(SOURCE, "utf8");

function loadHook() {
  const start = src.indexOf("  window.PhoenixKitAdminHooks.FolderDropUpload = {");
  assert.notStrictEqual(start, -1, "could not find FolderDropUpload");
  const end = src.indexOf("\n  };", start) + "\n  };".length;
  function FakeDataTransfer() {
    const files = [];
    this.items = { add: (f) => files.push(f) };
    this.files = files;
  }
  const fn = new Function(
    "window", "document", "setTimeout", "DataTransfer", "Event",
    "window.PhoenixKitAdminHooks = window.PhoenixKitAdminHooks || {};" +
      src.slice(start, end) + "; return window.PhoenixKitAdminHooks.FolderDropUpload;"
  );
  return fn({}, {}, (cb) => cb(), FakeDataTransfer,
    function E(name, opts) { this.type = name; this.bubbles = opts && opts.bubbles; });
}

function node(queryAnswer, parent) {
  return {
    querySelector: () => queryAnswer || null,
    parentElement: parent || null,
  };
}

test("the inject walks OUT of a flex-1 wrapper that lacks the input", () => {
  const hook = loadHook();
  const events = [];
  const input = {
    files: null,
    dispatchEvent: (e) => events.push(e.type),
  };
  // dropEl -> innerWrapper (no input inside) -> outer scope (has the input).
  // closest(".flex-1") stopped at the inner wrapper and gave up; the walk
  // must keep going.
  const outer = node(input, null);
  const inner = node(null, outer);
  const ctx = { el: node(null, inner), _pendingFiles: [{ name: "a.png" }, { name: "b.png" }] };
  ctx.el.parentElement = inner;

  hook._injectFiles.call(ctx);

  assert.ok(input.files, "the dropped files must reach the upload input");
  assert.strictEqual(input.files.length, 2);
  assert.deepStrictEqual(events, ["input"], "…announced so LiveView starts the transfer");
  assert.strictEqual(ctx._pendingFiles, null, "consumed, not re-injected on the next drop");
});

test("nothing to find: the retry loop gives up without throwing", () => {
  const hook = loadHook();
  const ctx = { el: node(null, null), _pendingFiles: [{ name: "a.png" }] };
  hook._injectFiles.call(ctx); // setTimeout stub recurses to maxAttempts
  assert.deepStrictEqual(ctx._pendingFiles, [{ name: "a.png" }],
    "no input on the page (no buckets) — the drop is simply not consumed");
});
