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
const { webcrypto } = require("node:crypto");
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
  // The stub names the manager's global and its uploader (`holdChunkedUploader`), so only code is pinned.
  for (const marker of ["function UploadQueue(", "function ChunkJob(", "function chunkedUploader(", "pk-um:"]) {
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
    assert.deepStrictEqual(Array.from(env.warnings), []);
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
    assert.deepStrictEqual(Array.from(env.warnings), [], "the real hook on the page is the one the bundle defines: nothing to warn about");
  } finally {
    hook.destroyed();
  }
});

test("a page that ran the standalone file before phoenix_kit.js keeps its hook, and the bundle warns of nothing", () => {
  const env = createEnv({ facts: FACTS });
  env.load("phoenix_kit_upload_manager.js");
  const first = env.window.PhoenixKitUploadManager;
  env.load("phoenix_kit.js");
  assert.strictEqual(env.window.PhoenixKitHooks.UploadManager, first.hook, "the public file does not stub over a hook that is there");

  env.load("phoenix_kit_admin.js");
  assert.strictEqual(env.window.PhoenixKitUploadManager, first, "the copy in the bundle stood down");
  assert.strictEqual(env.window.PhoenixKitAdminHooks.UploadManager, first.hook);
  assert.strictEqual(env.window.PhoenixKitHooks.UploadManager, first.hook);
  assert.deepStrictEqual(Array.from(env.warnings), []);
});

test("a page that ran the standalone file between phoenix_kit.js and LiveSocket gets the real hook, and the bundle warns of nothing", () => {
  const env = createEnv({ facts: FACTS });
  env.load("phoenix_kit.js");
  env.load("phoenix_kit_upload_manager.js");
  const first = env.window.PhoenixKitUploadManager;
  assert.strictEqual(env.window.PhoenixKitHooks.UploadManager, first.hook, "LiveSocket would be built from the real hook");

  env.load("phoenix_kit_admin.js");
  assert.strictEqual(env.window.PhoenixKitUploadManager, first);
  assert.strictEqual(env.window.PhoenixKitAdminHooks.UploadManager, first.hook);
  assert.deepStrictEqual(Array.from(env.warnings), []);
});

test("a hook of the admin bundle that nothing stubs still draws the warning", () => {
  const env = createEnv({ facts: FACTS });
  env.load("phoenix_kit.js");
  delete env.window.PhoenixKitHooks.UploadManager;
  env.load("phoenix_kit_admin.js");
  assert.deepStrictEqual(Array.from(env.warnings), [
    "[PhoenixKit] The admin hook UploadManager has no stub in phoenix_kit.js, so no page can mount it."
  ]);
});

// ── Files chosen before the bundle has arrived ─────────────────────────────
//
// LiveView preflights a file at once and, when the server answers, looks the
// entry's uploader up in `liveSocket.uploaders` and calls it with
// (entries, onError, resp, liveSocket). The manager registers `PkChunked`
// there when it starts, which for a stub is after the bundle has arrived.

// The server of the chunked upload: it keeps the bytes it was given.
function chunkServer() {
  const server = { held: 0, body: Buffer.alloc(0), token: "tok" };
  server.XHR = class FakeXHR {
    constructor() { this.upload = {}; this.headers = {}; }
    open(method) { this.method = method; }
    setRequestHeader(k, v) { this.headers[k.toLowerCase()] = v; }
    getResponseHeader(k) { return k.toLowerCase() === "upload-offset" ? String(server.held) : null; }
    abort() {}
    send(body) {
      Promise.resolve().then(async () => {
        this.status = 200;
        if (this.method === "PATCH") {
          if (parseInt(this.headers["upload-offset"], 10) !== server.held) this.status = 409;
          else {
            const buf = Buffer.from(await body.arrayBuffer());
            server.body = Buffer.concat([server.body, buf]);
            server.held += buf.length;
          }
        }
        this.onload && this.onload();
      });
    }
  };
  return server;
}

function chosenEntry(bytes) {
  return {
    ref: "e1", file: new File([bytes], "f.bin"),
    meta: { url: "/u/x", token: "tok", chunk_size: 65536, uploader: "PkChunked" },
    pct: [], err: null,
    progress(p) { this.pct.push(p); },
    error(r) { this.err = r; },
    onCancel() {}
  };
}

const until = async (fn, ms = 2000) => {
  const t = Date.now();
  while (!fn()) {
    if (Date.now() - t > ms) throw new Error("timed out");
    await new Promise((r) => setImmediate(r));
  }
};

function stubbedPanel(opts) {
  const env = createEnv({ facts: FACTS });
  env.load("phoenix_kit.js");
  const { el } = panel(env);
  if (opts && opts.dataset) Object.assign(el.dataset, opts.dataset);
  const hook = makeHook(env.window.PhoenixKitHooks.UploadManager, el);
  hook.liveSocket = { uploaders: (opts && opts.uploaders) || {} };
  return { env, hook, el };
}

test("a file chosen before the bundle arrives is sent once it has, and the stand-in is gone", async () => {
  const { env, hook } = stubbedPanel();
  const server = chunkServer();
  env.window.XMLHttpRequest = server.XHR;
  env.window.crypto = webcrypto;
  hook.mounted();

  const standIn = hook.liveSocket.uploaders.PkChunked;
  assert.strictEqual(typeof standIn, "function", "LiveView finds an uploader when the server answers");

  // The server's answer reaches LiveView while the bundle is still on its way.
  const data = Buffer.from(Array.from({ length: 150000 }, (_, i) => i % 251));
  const entry = chosenEntry(data);
  const running = standIn([entry], () => {}, {}, hook.liveSocket);
  assert.deepStrictEqual(entry.pct, [], "nothing is sent yet");

  env.load("phoenix_kit_admin.js");
  env.loaded(0);
  await running;
  await until(() => entry.pct[entry.pct.length - 1] === 100 || entry.err);

  try {
    assert.strictEqual(entry.err, null);
    assert.ok(server.body.equals(data), "every byte arrived, in order");
    assert.strictEqual(entry.pct[entry.pct.length - 1], 100);
    assert.notStrictEqual(hook.liveSocket.uploaders.PkChunked, standIn, "the real uploader took the stand-in's place");
    assert.strictEqual(hook.liveSocket.uploaders.PkChunked.name, "chunkedUploader");
    assert.strictEqual(hook.queue.resumable, true, "the manager started on the same instance");
    assert.deepStrictEqual(Array.from(env.errors), []);
  } finally {
    hook.destroyed();
  }
});

test("the stand-in is replaced by the real uploader when the bundle arrives, whether or not a file came", async () => {
  const { env, hook } = stubbedPanel();
  hook.mounted();
  const standIn = hook.liveSocket.uploaders.PkChunked;
  env.load("phoenix_kit_admin.js");
  env.loaded(0);
  await tick();
  try {
    assert.notStrictEqual(hook.liveSocket.uploaders.PkChunked, standIn);
    assert.strictEqual(hook.liveSocket.uploaders.PkChunked.name, "chunkedUploader");
  } finally {
    hook.destroyed();
  }
});

test("no stand-in for a panel that is not resumable, and none over an uploader that is there", () => {
  const plain = stubbedPanel({ dataset: { resumable: "false" } });
  plain.hook.mounted();
  assert.strictEqual(plain.hook.liveSocket.uploaders.PkChunked, undefined);

  const mine = () => {};
  const taken = stubbedPanel({ uploaders: { PkChunked: mine } });
  taken.hook.mounted();
  assert.strictEqual(taken.hook.liveSocket.uploaders.PkChunked, mine);
});

test("when the bundle cannot be loaded a file chosen before it is failed, not left at 0%", async () => {
  const { env, hook } = stubbedPanel();
  hook.mounted();
  const entry = chosenEntry(Buffer.from("abc"));
  const running = hook.liveSocket.uploaders.PkChunked([entry], () => {}, {}, hook.liveSocket);

  env.failed(0);
  await running;

  assert.strictEqual(entry.err, "failed");
  assert.deepStrictEqual(entry.pct, []);
  assert.ok(Array.from(env.errors).some((m) => /could not be sent/.test(m)), "the console says so");
});

test("a page that ran the standalone file after building LiveSocket gets the real uploader at once, whether or not the bundle comes", async () => {
  const env = createEnv({ facts: FACTS });
  env.load("phoenix_kit.js");
  const built = Object.assign({}, env.window.PhoenixKitHooks); // what LiveSocket was given
  env.load("phoenix_kit_upload_manager.js");
  const server = chunkServer();
  env.window.XMLHttpRequest = server.XHR;
  env.window.crypto = webcrypto;
  const { el } = panel(env);
  const hook = makeHook(built.UploadManager, el);
  hook.liveSocket = { uploaders: {} };
  hook.mounted();

  const uploader = hook.liveSocket.uploaders.PkChunked;
  assert.strictEqual(uploader.name, "chunkedUploader", "no stand-in: the script is here");

  env.failed(0);
  await tick();
  const data = Buffer.from(Array.from({ length: 90000 }, (_, i) => i % 251));
  const entry = chosenEntry(data);
  uploader([entry], () => {}, {}, hook.liveSocket);
  await until(() => entry.pct[entry.pct.length - 1] === 100 || entry.err);

  assert.strictEqual(entry.err, null);
  assert.ok(server.body.equals(data), "the file was sent although the bundle never arrived");
  assert.strictEqual(hook.liveSocket.uploaders.PkChunked, uploader);
  hook.destroyed();
});
