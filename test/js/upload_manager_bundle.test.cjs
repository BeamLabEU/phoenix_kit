// The upload manager ships twice: as its own file (for projects that take just
// that) and inside `phoenix_kit.js`, the bundle PhoenixKit's own pages load.
// The bundle's copy must be the file, verbatim.
//
// To refresh the bundle after editing the standalone file, replace what is
// between the two marker comments at the end of phoenix_kit.js with the file.
//
//   node --test test/js/upload_manager_bundle.test.cjs

const fs = require("fs");
const path = require("path");
const assert = require("node:assert");
const { test } = require("node:test");

const dir = path.join(__dirname, "..", "..", "priv", "static", "assets");
const standalone = fs.readFileSync(path.join(dir, "phoenix_kit_upload_manager.js"), "utf8");
const bundle = fs.readFileSync(path.join(dir, "phoenix_kit.js"), "utf8");

const BEGIN = "// >>> phoenix_kit_upload_manager.js >>>";
const END = "// <<< phoenix_kit_upload_manager.js <<<";

test("the bundle carries the standalone file, verbatim", () => {
  const start = bundle.indexOf(BEGIN);
  assert.notStrictEqual(start, -1, "the bundle has no copy of the upload manager");
  const from = bundle.indexOf("\n", start) + 1;
  const to = bundle.indexOf(END, from);
  assert.notStrictEqual(to, -1);

  assert.strictEqual(
    bundle.slice(from, to).trimEnd(),
    standalone.trimEnd(),
    "phoenix_kit.js's copy of the upload manager is out of date: copy " +
      "priv/static/assets/phoenix_kit_upload_manager.js between the markers at its end"
  );
});

test("the bundle registers the hook once", () => {
  assert.strictEqual(bundle.split("window.PhoenixKitHooks.UploadManager =").length - 1, 1);
});
