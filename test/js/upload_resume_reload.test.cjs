// A page reload with a file left in the browser's stash. Both UploadResume and
// UploadManager are admin hooks, so when the page mounts they are stubs: they
// ask for the admin bundle and wait. What follows has to hold whichever stub
// mounted first:
//
//   - the stash is read only by the real UploadResume, so nothing is read, sent
//     or deleted before the bundle (and nothing is lost when it never comes);
//   - once it is here, the leftover is reported, the server's answer is fed
//     back through the upload input, the manager takes it, and LiveView finds
//     the real chunked uploader when its preflight is answered, not the
//     stand-in the stub kept for files chosen before the bundle;
//   - a file the person chose before the bundle and the one resumed from the
//     stash both arrive whole;
//   - a connection that drops while the bundle is on its way costs the file
//     chosen meanwhile (its entry belongs to a process that is gone), not the
//     stash; and a bundle that arrives during the outage starts the manager
//     offline.
//
//   node --test test/js/upload_resume_reload.test.cjs

const assert = require("node:assert");
const { test } = require("node:test");
const { webcrypto } = require("node:crypto");
const { createEnv, makeHook } = require("./support/pk_env.cjs");

const FACTS = { admin: { file: "admin-3.0.0-cafebabe.js", cdn: null } };
const tick = () => new Promise((r) => setImmediate(r));
const until = async (fn, ms = 3000) => {
  const t = Date.now();
  while (!fn()) {
    if (Date.now() - t > ms) throw new Error("timed out");
    await tick();
  }
};

// The server of the chunked upload, one partial file per URL.
function chunkStore() {
  const files = {};
  class FakeXHR {
    constructor() { this.upload = {}; this.headers = {}; }
    open(method, url) {
      this.method = method;
      this.url = url;
      files[url] = files[url] || { held: 0, body: Buffer.alloc(0) };
    }
    setRequestHeader(k, v) { this.headers[k.toLowerCase()] = v; }
    getResponseHeader(k) { return k.toLowerCase() === "upload-offset" ? String(files[this.url].held) : null; }
    abort() {}
    send(body) {
      Promise.resolve().then(async () => {
        const f = files[this.url];
        this.status = 200;
        if (this.method === "PATCH") {
          if (parseInt(this.headers["upload-offset"], 10) !== f.held) this.status = 409;
          else {
            const buf = Buffer.from(await body.arrayBuffer());
            f.body = Buffer.concat([f.body, buf]);
            f.held += buf.length;
          }
        }
        this.onload && this.onload();
      });
    }
  }
  return { files, XHR: FakeXHR };
}

// IndexedDB as far as the stash uses it: one store, keyed by `id`.
function fakeIndexedDB() {
  const rows = new Map();
  const db = { transactions: 0, rows };
  db.indexedDB = {
    open() {
      const req = {};
      setImmediate(() => {
        req.result = {
          createObjectStore() {},
          close() {},
          transaction() {
            db.transactions += 1;
            const tx = {};
            tx.objectStore = () => ({
              getAll: () => ({ result: Array.from(rows.values()) }),
              put: (r) => { rows.set(r.id, r); },
              delete: (id) => { rows.delete(id); }
            });
            setImmediate(() => tx.oncomplete && tx.oncomplete());
            return tx;
          }
        };
        req.onsuccess && req.onsuccess();
      });
      return req;
    }
  };
  return db;
}

class FakeEvent {
  constructor(type, init) { this.type = type; this.bubbles = !!(init && init.bubbles); this.stopped = false; }
  stopImmediatePropagation() { this.stopped = true; }
  stopPropagation() {}
  preventDefault() {}
}

class FakeDataTransfer {
  constructor() { this._files = []; this.items = { add: (f) => this._files.push(f) }; }
  get files() { return this._files; }
}

function node(parent) {
  const n = { parentElement: parent || null, listeners: [] };
  n.addEventListener = (type, fn, capture) => n.listeners.push({ type, fn, capture: !!capture });
  n.removeEventListener = (type, fn, capture) => {
    n.listeners = n.listeners.filter((l) => !(l.type === type && l.fn === fn && l.capture === !!capture));
  };
  return n;
}

// Capture phase from the top down, then the target; an event that bubbles goes
// up from the target afterwards.
function dispatch(target, ev) {
  ev.target = ev.target || target;
  const path = [];
  for (let n = target; n; n = n.parentElement) path.unshift(n);
  for (const n of path.slice(0, -1)) {
    for (const l of n.listeners.slice()) {
      if (l.type === ev.type && l.capture) l.fn(ev);
      if (ev.stopped) return true;
    }
  }
  for (const l of target.listeners.slice()) {
    if (l.type === ev.type) l.fn(ev);
    if (ev.stopped) return true;
  }
  if (ev.bubbles) {
    for (const n of path.slice(0, -1).reverse()) {
      for (const l of n.listeners.slice()) {
        if (l.type === ev.type && !l.capture) l.fn(ev);
      }
    }
  }
  return true;
}

// The page of a reload: the browser's root, the upload input, the resume hook's
// element and the manager's panel, LiveView's own input listener, and the
// server that answers the resume hook's report.
function reloadedPage({ order }) {
  const env = createEnv({ facts: FACTS });
  const store = chunkStore();
  const idb = fakeIndexedDB();
  const w = env.window;
  w.XMLHttpRequest = store.XHR;
  w.crypto = webcrypto;
  w.indexedDB = idb.indexedDB;
  w.File = File;
  w.Event = FakeEvent;
  w.DataTransfer = FakeDataTransfer;
  w.location.pathname = "/admin/media";
  // The resume hook looks for what an earlier page left 1.5 s after it mounts;
  // the test says when.
  const timers = { scan: null, set: [] };
  w.setTimeout = (fn, ms) => {
    if (ms === 1500) { timers.scan = fn; return 0; }
    const t = setTimeout(fn, ms);
    timers.set.push({ ms, t, cleared: false });
    return t;
  };
  w.clearTimeout = (t) => {
    clearTimeout(t);
    timers.set.forEach((x) => { if (x.t === t) x.cleared = true; });
  };
  env.load("phoenix_kit.js");

  const root = node(null);
  root.querySelector = (sel) => (/data-phx-upload-ref/.test(sel) && !/folder-drop/.test(sel) ? input : null);
  const input = Object.assign(node(root), {
    tagName: "INPUT", type: "file", files: [], value: "",
    attrs: { "data-phx-upload-ref": "phx-F1" },
    getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; },
    hasAttribute(k) { return k in this.attrs; },
    dispatchEvent(ev) { return dispatch(input, ev); }
  });
  env.document.querySelector = (sel) => (/data-phx-upload-ref="phx-F1"/.test(sel) ? input : null);

  const resumeEl = Object.assign(env.makeEl("div"), node(root));
  resumeEl.dataset.user = "u1";
  const panelEl = Object.assign(env.makeEl("div"), node(root));
  Object.assign(panelEl.dataset, {
    uploadRef: "phx-F1", uploadName: "photos", entries: "photos-entries",
    max: "3", resumable: "true", remember: "false", labels: "{}"
  });
  panelEl.contains = () => false;
  panelEl.dispatchEvent = (ev) => dispatch(panelEl, ev);

  const liveSocket = { uploaders: {} };
  const resume = makeHook(w.PhoenixKitHooks.UploadResume, resumeEl);
  const manager = makeHook(w.PhoenixKitHooks.UploadManager, panelEl);
  resume.liveSocket = liveSocket;
  manager.liveSocket = liveSocket;

  // LiveView: a file in the input is preflighted, and when the server's answer
  // comes the uploader the entry names is looked up on the socket.
  const lv = { entries: [], lookups: [], errors: [], onErrorCallbacks: [] };
  const onError = (callback) => lv.onErrorCallbacks.push(callback);
  input.addEventListener("input", () => {
    const files = Array.from(input.files);
    const entries = files.map((file, i) => ({
      ref: "e" + (lv.entries.length + i + 1), file,
      meta: { url: "/u/" + file.name, token: "tok", chunk_size: 65536, uploader: "PkChunked" },
      pct: [], err: null,
      progress(p) { this.pct.push(p); },
      error(r) { this.err = r; },
      onCancel() {}
    }));
    lv.entries.push(...entries);
    setImmediate(() => {
      const uploader = liveSocket.uploaders.PkChunked;
      lv.lookups.push(typeof uploader === "function" ? uploader.name : String(uploader));
      if (typeof uploader !== "function") {
        lv.errors.push("no uploader configured for PkChunked");
        return;
      }
      uploader(entries, onError, {}, liveSocket);
    });
  });

  // The server's side of the resume hook's report: everything it is told of is
  // asked for again, without a click.
  const reports = [];
  resume.pushEventTo = (_target, name, payload) => {
    reports.push({ name, payload });
    if (name === "upload_resume_available") {
      setImmediate(() => resume.handlers["phoenix_kit:upload-resume"]({
        keys: payload.items.map((i) => i.key), auto: true
      }));
    }
  };

  const hooks = { resume, manager };
  for (const name of order) hooks[name].mounted();

  const page = {
    env, store, idb, lv, reports, resume, manager, input, timers,
    // The person chooses a file: LiveView sees the input event first, as nothing has hooked it yet.
    choose(file) {
      input.files = [file];
      input.dispatchEvent(new FakeEvent("input", { bubbles: true }));
    },
    // What an earlier page load left in the browser.
    stash(file, ageMs) {
      const scope = resume._scopeNow();
      const key = file.name + "|" + file.size + "|" + file.lastModified;
      const old = env.window.Date.now() - (ageMs === undefined ? 60000 : ageMs);
      idb.rows.set(scope + "\u0000" + key, {
        id: scope + "\u0000" + key, key, scope, name: file.name, size: file.size, type: file.type,
        lastModified: file.lastModified, blob: file, tab: "an-earlier-page", picked: old, touched: old
      });
      return key;
    },
    async bundleArrives() {
      env.load("phoenix_kit_admin.js");
      env.loaded(0);
      await tick();
      // The panel's markup is the component's; what is tested here is the
      // queue and the hand-over, not the rows.
      manager.render = () => {};
    },
    // The socket drops: LiveView's own handler for the channel's error is the first one registered and
    // tells the page, then the uploads' callbacks run; the page is told it is back later.
    dropConnection() {
      manager.disconnected();
      lv.onErrorCallbacks.splice(0).forEach((callback) => callback());
    },
    restoreConnection() { manager.reconnected(); },
    destroy() { resume.destroyed(); manager.destroyed(); }
  };
  return page;
}

const bytes = (n, seed) => Buffer.from(Array.from({ length: n }, (_, i) => (i * seed) % 251));
const leftover = (data) => new File([data], "left.bin", { type: "application/octet-stream", lastModified: 1700000000000 });

for (const order of [["resume", "manager"], ["manager", "resume"]]) {
  test("after a reload the stashed file is sent by the real uploader, with the stubs mounted " + order.join(" then "), async () => {
    const page = reloadedPage({ order });
    const data = bytes(150000, 7);
    try {
      assert.strictEqual(page.env.scripts.length, 1, "one request for the bundle, whichever stub asked first");
      assert.strictEqual(typeof page.manager.liveSocket.uploaders.PkChunked, "function", "the stub keeps a stand-in under the uploader's name");
      assert.strictEqual(page.idb.transactions, 0, "the stash has not been looked at");

      await page.bundleArrives();
      assert.strictEqual(page.manager.liveSocket.uploaders.PkChunked.name, "chunkedUploader", "the real uploader replaced the stand-in with the bundle");
      assert.ok(page.timers.scan, "the real resume hook is waiting to look at the stash");

      const key = page.stash(leftover(data));
      page.timers.scan();
      await until(() => page.lv.entries[0] && (page.lv.entries[0].pct.at(-1) === 100 || page.lv.entries[0].err));

      const entry = page.lv.entries[0];
      assert.strictEqual(page.reports.filter((r) => r.name === "upload_resume_available").length, 1, "reported once");
      assert.strictEqual(page.reports[0].payload.items[0].key, key);
      assert.strictEqual(page.lv.entries.length, 1, "LiveView was handed the file once");
      assert.deepStrictEqual(page.lv.lookups, ["chunkedUploader"], "LiveView found the real uploader, not the stand-in");
      assert.deepStrictEqual(page.lv.errors, []);
      assert.strictEqual(entry.err, null);
      assert.ok(page.store.files["/u/left.bin"].body.equals(data), "every byte of the stashed file arrived");
      assert.strictEqual(page.manager.queue.items.length, 1, "the manager queued it once");
      assert.deepStrictEqual(Array.from(page.env.errors), []);
      assert.deepStrictEqual(Array.from(page.env.warnings), []);
    } finally {
      page.destroy();
    }
  });
}

test("a file chosen before the bundle and one resumed from the stash both arrive whole", async () => {
  const page = reloadedPage({ order: ["resume", "manager"] });
  const early = bytes(120000, 3);
  const stashed = bytes(90000, 5);
  try {
    page.choose(new File([early], "early.bin", { lastModified: 1700000000001 }));
    await until(() => page.lv.lookups.length === 1);
    assert.strictEqual(page.lv.lookups[0], "standIn", "chosen before the bundle: it went to the stand-in");
    assert.deepStrictEqual(page.lv.entries[0].pct, [], "and waits for the bundle");

    await page.bundleArrives();
    page.stash(leftover(stashed));
    page.timers.scan();
    await until(() => page.lv.entries.length === 2 && page.lv.entries.every((e) => e.pct.at(-1) === 100 || e.err));

    assert.deepStrictEqual(page.lv.errors, []);
    assert.deepStrictEqual(page.lv.entries.map((e) => e.err), [null, null]);
    assert.ok(page.store.files["/u/early.bin"].body.equals(early), "the file chosen before the bundle arrived whole");
    assert.ok(page.store.files["/u/left.bin"].body.equals(stashed), "and so did the stashed one");
    assert.strictEqual(page.lv.lookups[1], "chunkedUploader", "the resumed file went to the real uploader");
    assert.deepStrictEqual(Array.from(page.env.errors), []);
  } finally {
    page.destroy();
  }
});

test("a rejoin while the bundle is on its way drops the file chosen meanwhile, and the stash is still resumed", async () => {
  const page = reloadedPage({ order: ["manager", "resume"] });
  const early = bytes(60000, 3);
  const stashed = bytes(80000, 5);
  try {
    page.choose(new File([early], "early.bin", { lastModified: 1700000000001 }));
    await until(() => page.lv.lookups.length === 1);
    // LiveView rejoined: the entry above belongs to a process that is gone.
    page.dropConnection();
    page.restoreConnection();

    await page.bundleArrives();
    page.stash(leftover(stashed));
    page.timers.scan();
    await until(() => page.lv.entries[1] && (page.lv.entries[1].pct.at(-1) === 100 || page.lv.entries[1].err));

    assert.deepStrictEqual(page.lv.entries[0].pct, [], "nothing was pushed about the dropped entry");
    assert.strictEqual(page.lv.entries[0].err, null);
    assert.strictEqual(page.store.files["/u/early.bin"], undefined, "and none of its bytes were sent");
    assert.ok(page.store.files["/u/left.bin"].body.equals(stashed), "the stashed file of the earlier page arrived whole");
    assert.strictEqual(page.lv.lookups[1], "chunkedUploader");
    assert.ok(Array.from(page.env.warnings).some((m) => /reconnected/.test(m)), "the console says why the first one went");
    assert.deepStrictEqual(Array.from(page.env.errors), []);
  } finally {
    page.destroy();
  }
});

test("the bundle arriving during an outage: a file picked then waits for the reconnect, and is sent after it", async () => {
  const page = reloadedPage({ order: ["resume", "manager"] });
  const data = bytes(70000, 11);
  try {
    page.dropConnection();
    await page.bundleArrives();
    assert.strictEqual(page.manager.queue.offline, true, "the manager knows the socket is down");

    page.choose(new File([data], "waiting.bin", { lastModified: 1700000000002 }));
    await tick();
    await tick();
    assert.strictEqual(page.manager.queue.items.length, 1, "the manager took the file");
    assert.deepStrictEqual(page.lv.entries, [], "and fed nothing to the dead socket");

    page.restoreConnection();
    await until(() => page.lv.entries[0] && (page.lv.entries[0].pct.at(-1) === 100 || page.lv.entries[0].err));
    assert.strictEqual(page.lv.entries[0].err, null);
    assert.ok(page.store.files["/u/waiting.bin"].body.equals(data), "it arrived whole once the socket was back");
    assert.deepStrictEqual(page.lv.errors, []);
  } finally {
    page.destroy();
  }
});

test("an UploadResume stub destroyed before the bundle never starts the real hook: the stash is not read, nothing is scheduled", async () => {
  const page = reloadedPage({ order: ["resume", "manager"] });
  try {
    page.resume.destroyed(); // LiveView removed the element while the bundle was on its way
    await page.bundleArrives();
    assert.strictEqual(page.timers.scan, null, "no look at the stash was ever scheduled");
    assert.strictEqual(page.idb.transactions, 0, "and the stash was not opened");
    assert.deepStrictEqual(page.reports, []);
    assert.strictEqual(typeof page.manager.queue, "object", "the manager beside it mounted all the same");
  } finally {
    page.destroy();
  }
});

test("a hook destroyed while its look at the stash is running reports nothing and schedules nothing", async () => {
  const page = reloadedPage({ order: ["manager", "resume"] });
  try {
    await page.bundleArrives();
    page.stash(leftover(bytes(1000, 3))); // left by an earlier page: would be reported
    page.stash(new File([bytes(500, 7)], "fresh.bin", { lastModified: 1700000000003 }), 1000); // still touched: would be looked at again
    const before = page.timers.set.length;

    page.timers.scan(); // the look starts: it reads the stash asynchronously
    page.resume.destroyed();
    await tick();
    await tick();
    await tick();

    assert.deepStrictEqual(page.reports, [], "nobody is left to tell");
    assert.deepStrictEqual(page.timers.set.slice(before).filter((t) => !t.cleared && t.ms >= 1000), [],
      "and no timer set now would be cleared by anything");
  } finally {
    page.destroy();
  }
});

test("a hook destroyed while the look after a reconnect is running reports nothing", async () => {
  const page = reloadedPage({ order: ["resume", "manager"] });
  try {
    await page.bundleArrives();
    // A file this page picked itself: its record is this tab's, and a reconnect makes it a leftover.
    page.resume._stash([leftover(bytes(1000, 3))]);
    await tick();
    await tick();
    assert.strictEqual(page.idb.rows.size, 1, "the pick was written to the stash");

    page.resume.reconnected(); // the look begins
    page.resume.destroyed();
    await tick();
    await tick();
    await tick();

    assert.deepStrictEqual(page.reports, [], "the page is gone: nobody is told");
  } finally {
    page.destroy();
  }
});

test("when the bundle never comes the stash is left as it was and nothing is sent", async () => {
  const page = reloadedPage({ order: ["resume", "manager"] });
  try {
    page.idb.rows.set("s\u0000k", { id: "s\u0000k", key: "k", scope: "s", name: "left.bin", size: 1000, blob: {}, tab: "an-earlier-page", touched: 0 });
    page.env.failed(0);
    await tick();
    await tick();
    assert.strictEqual(page.idb.transactions, 0, "no hook that reads the stash was ever started");
    assert.strictEqual(page.idb.rows.size, 1, "the record of the earlier page is still there");
    assert.strictEqual(page.timers.scan, null);
    assert.deepStrictEqual(page.reports, []);
    assert.deepStrictEqual(page.lv.entries, []);
  } finally {
    page.destroy();
  }
});
