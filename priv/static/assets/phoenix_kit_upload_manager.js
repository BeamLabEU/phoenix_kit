// ============================================================================
// UploadManager — a queue, a speed readout and per-file controls for any
// Phoenix LiveView upload
// ============================================================================
//
// LiveView's own uploader starts every picked file at once, each on a channel
// of its own. A hundred files is a hundred simultaneous transfers: slower for
// all of them, heavy on the server, and with nothing to pause, reorder or
// skip. This hook sits in front of the upload's file input instead. Files
// picked or dropped are held here and handed to LiveView a few at a time:
//
//   * AUTO concurrency. One file goes first, alone, as a speed probe. The
//     queue then adds a transfer at a time for as long as the total speed
//     keeps rising, up to the cap the page names (`data-max`), and backs off
//     when an extra transfer stops paying for itself.
//   * A panel with the number in flight, the live total speed, how many are
//     done, and a list of every file with what it is doing.
//   * Per-file controls: pause / resume, skip / restore, move to the front
//     (prioritise), cancel, retry a failure; and pause all / cancel all.
//
// It knows nothing about the page it is on. Everything it learns about an
// upload it reads from the rows `PhoenixKitWeb.Components.Core.UploadManager`
// renders (one element per LiveView upload entry, with its ref, key, size,
// progress and errors), and it cancels an entry by pushing one event, whose
// name and target the component names. Take the component and this file to
// another project and they work there.
//
// Pausing: LiveView's upload channel cannot resume, so pausing a file that is
// already sending stops it and sends it again from the start when resumed.
// A file still waiting is simply held.
//
// SETUP (outside PhoenixKit's own bundle, which already includes this file):
//
//   import "../../deps/phoenix_kit/priv/static/assets/phoenix_kit_upload_manager.js"
//   let liveSocket = new LiveSocket("/live", Socket, {
//     hooks: { ...window.PhoenixKitHooks, ... }
//   })
// ----------------------------------------------------------------------------
(function() {
  "use strict";

  if (window.PhoenixKitUploadManager) return;

  var HARD_CAP = 20;
  // A file handed to LiveView whose row never shows up was refused (or lost)
  // somewhere between the browser and the server; say so instead of waiting.
  var UNSEEN_GRACE_MS = 8000;
  // Files are handed to LiveView one batch at a time: the next goes only once
  // the last has started to move. Preflights that overlap can leave an entry
  // registered on the server that the browser never starts sending — it sits
  // at 0% for good. A batch that has not started within this long is judged
  // stalled (see `START_WAIT_MS` use in `observe`).
  var START_WAIT_MS = 6000;
  // A file that has shown no progress at all for this long is stalled too: a
  // dead connection, a server that stopped reading.
  var STALL_MS = 20000;
  // A stalled file is sent again by itself this many times before it is
  // reported as failed.
  var AUTO_RETRIES = 1;
  var TICK_MS = 250;
  // How long one concurrency level is measured before deciding about the next.
  var TUNE_WINDOW_MS = 3000;
  // An extra transfer has to add at least this much total speed to be kept.
  var TUNE_GAIN = 1.15;
  // The probe ends after this long even if its file has not finished, and
  // once at least this many bytes have moved (enough to read a speed from).
  var PROBE_MIN_MS = 2500;
  var PROBE_MIN_BYTES = 128 * 1000;
  var PROBE_MAX_MS = 6000;
  // Re-test whether one more transfer would help, every so often, once the
  // level has settled: the connection or the server's load may have changed.
  var RETUNE_MS = 20000;
  var SPEED_WINDOW_MS = 5000;
  // A stale entry is cancelled once, and again if it is still there this long
  // after (the cancel may not have landed).
  var GHOST_RETRY_MS = 1500;
  var GHOST_TRIES = 4;

  function clamp(n, lo, hi) {
    n = parseInt(n, 10);
    if (!isFinite(n)) return lo;
    return Math.max(lo, Math.min(hi, n));
  }

  // The same three things LiveView sends and the server's `client_key/1`
  // reads off an entry.
  function fileKey(file) {
    return file.name + "|" + file.size + "|" + file.lastModified;
  }

  var ACTIVE = { queued: 1, uploading: 1, paused: 1 };

  // --------------------------------------------------------------------------
  // The queue: pure state and policy, no DOM. Everything time-dependent takes
  // `now`, so the policy can be run in a test as fast as the test likes.
  // --------------------------------------------------------------------------
  function UploadQueue(opts) {
    opts = opts || {};
    this.cap = clamp(opts.cap == null ? 5 : opts.cap, 1, HARD_CAP);
    this.items = [];
    this.nextId = 1;
    this.paused = false;
    this.samples = [];
    this.ghosts = {};
    this.stale = {};
    this.doneBytes = 0;
    this.tune = {
      phase: this.cap > 1 ? "probe" : "hold",
      target: 1,
      level: {},
      windowStart: null,
      windowAt: null,
      settledAt: null,
      probeStart: null
    };
  }

  UploadQueue.prototype.add = function(files) {
    var added = [];
    for (var i = 0; i < files.length; i++) {
      var f = files[i];
      var item = {
        id: this.nextId++,
        key: fileKey(f),
        name: f.name,
        size: f.size || 0,
        file: f,
        state: "queued",
        bytes: 0,
        ref: null,
        fedAt: null,
        seen: false,
        started: false,
        progressAt: null,
        attempts: 0,
        error: null
      };
      this.items.push(item);
      added.push(item);
    }
    return added;
  };

  UploadQueue.prototype.get = function(id) {
    for (var i = 0; i < this.items.length; i++) if (this.items[i].id === id) return this.items[i];
    return null;
  };

  UploadQueue.prototype.count = function(state) {
    var n = 0;
    for (var i = 0; i < this.items.length; i++) if (this.items[i].state === state) n++;
    return n;
  };

  // The files to hand to LiveView now: as many as the current level has room
  // for, in queue order. Marks them as sent.
  UploadQueue.prototype.next = function(now) {
    if (this.paused) return [];
    // One batch at a time: wait for the last one to start moving.
    for (var j = 0; j < this.items.length; j++) {
      var f = this.items[j];
      if (f.state === "uploading" && !f.started && now - f.fedAt < START_WAIT_MS) return [];
    }
    var room = this.tune.target - this.count("uploading");
    var out = [];
    for (var i = 0; i < this.items.length && out.length < room; i++) {
      var it = this.items[i];
      if (it.state !== "queued") continue;
      it.state = "uploading";
      it.attempts += 1;
      it.fedAt = now;
      it.seen = false;
      it.started = false;
      it.progressAt = now;
      it.ref = null;
      it.bytes = 0;
      out.push(it);
    }
    if (out.length && this.tune.probeStart == null) this.tune.probeStart = now;
    return out;
  };

  // Reconcile what LiveView reports (`rows`, one per upload entry it holds:
  // {ref, key, size, progress, done, error}) with what was handed to it.
  // Returns the refs of entries that must be cancelled on the server.
  UploadQueue.prototype.observe = function(rows, now) {
    var cancel = [];
    var pool = {};
    var i;
    for (i = 0; i < rows.length; i++) {
      (pool[rows[i].key] = pool[rows[i].key] || []).push(rows[i]);
    }

    var sending = this.items.filter(function(it) { return it.state === "uploading"; });
    sending.sort(function(a, b) { return a.fedAt - b.fedAt; });

    // Items that already know their entry claim it first, so two files with
    // the same name, size and date cannot swap rows.
    var matched = {};
    sending.forEach(function(it) {
      if (!it.ref) return;
      var list = pool[it.key] || [];
      for (var j = 0; j < list.length; j++) {
        if (list[j].ref === it.ref) { matched[it.id] = list.splice(j, 1)[0]; break; }
      }
    });
    sending.forEach(function(it) {
      if (matched[it.id] || it.ref) return;
      var list = pool[it.key] || [];
      if (list.length) matched[it.id] = list.shift();
    });

    for (i = 0; i < sending.length; i++) {
      var item = sending[i];
      var row = matched[item.id];

      if (row) {
        item.seen = true;
        item.ref = row.ref;
        if (row.error) {
          item.state = "failed";
          item.error = row.error;
          cancel.push(row.ref);
        } else if (row.done) {
          this._finish(item);
        } else {
          var bytes = Math.min(item.size, Math.round(item.size * (row.progress || 0) / 100));
          if (bytes > item.bytes) item.progressAt = now;
          item.bytes = bytes;
          // Moving means bytes have gone: a registered entry at 0% is not.
          item.started = bytes > 0;
          // Sent in full and waiting for the host: not a stall of ours.
          if (row.progress >= 100) item.progressAt = now;
        }
      } else if (item.seen) {
        // It was there and now it is not: the host consumed it. Done.
        this._finish(item);
      } else if (now - item.fedAt > UNSEEN_GRACE_MS) {
        item.state = "failed";
        item.error = "not_accepted";
      }

      if (item.state === "uploading") {
        var waited = now - item.progressAt;
        var limit = item.bytes > 0 ? STALL_MS : START_WAIT_MS;
        if (item.seen && waited > limit) {
          if (item.ref) cancel.push(item.ref);
          this._stalled(item);
        }
      }
    }

    // An entry that belongs to a file this queue is finished with, or stopped,
    // should not be on the server. LiveView can put one back after the fact:
    // the browser's form-change message listing the file was built before the
    // server's reply that dropped it (consumed, or cancelled), and the server
    // adds any entry it is told of and does not know. The re-added one sits at
    // 0% for good, holds one of the upload's `max_entries` slots and keeps the
    // file "active" in the browser; over a hundred-file batch those add up to
    // the limit. A cancel can also land while the entry's transfer is only
    // starting, and not take. Either way: cancel it again, a few times.
    var finished = {};
    for (i = 0; i < this.items.length; i++) {
      if (this.items[i].state === "done" && this.items[i].ref) finished[this.items[i].ref] = true;
    }
    for (i = 0; i < rows.length; i++) {
      var r = rows[i];
      if (r.done || !(finished[r.ref] || this.stale[r.ref])) continue;
      var seen = this.ghosts[r.ref] || { at: null, tries: 0 };
      if (seen.tries >= GHOST_TRIES) continue;
      if (seen.at == null || now - seen.at > GHOST_RETRY_MS) {
        this.ghosts[r.ref] = { at: now, tries: seen.tries + 1 };
        cancel.push(r.ref);
      }
    }

    this._sample(now);
    // Once each, however many reasons there were.
    return cancel.filter(function(ref, at) { return cancel.indexOf(ref) === at; });
  };

  // A file that has not moved: sent again by itself, then reported.
  UploadQueue.prototype._stalled = function(item) {
    if (item.ref) this.stale[item.ref] = true;
    item.ref = null;
    item.seen = false;
    item.started = false;
    item.bytes = 0;
    if (item.attempts <= AUTO_RETRIES) {
      item.state = "queued";
    } else {
      item.state = "failed";
      item.error = "stalled";
    }
  };

  UploadQueue.prototype._finish = function(item) {
    item.state = "done";
    item.bytes = item.size;
    this.doneBytes += item.size;
  };

  // Bytes moved so far, over every file in the batch: finished ones in full,
  // sending ones as far as they have got.
  UploadQueue.prototype.movedBytes = function() {
    var b = this.doneBytes;
    for (var i = 0; i < this.items.length; i++) {
      if (this.items[i].state === "uploading") b += this.items[i].bytes;
    }
    return b;
  };

  UploadQueue.prototype._sample = function(now) {
    var last = this.samples[this.samples.length - 1];
    var bytes = this.movedBytes();
    if (last && last.t === now) { last.bytes = bytes; return; }
    this.samples.push({ t: now, bytes: bytes });
    var cutoff = now - 3 * SPEED_WINDOW_MS;
    while (this.samples.length > 2 && this.samples[1].t < cutoff) this.samples.shift();
  };

  // Bytes per second over the trailing window. The window ends at `now`, so a
  // stall decays toward zero instead of holding its last good figure.
  UploadQueue.prototype.speed = function(now, windowMs) {
    windowMs = windowMs || SPEED_WINDOW_MS;
    var s = this.samples;
    if (s.length < 2) return 0;
    var latest = s[s.length - 1];
    var cutoff = now - windowMs;
    var base = latest;
    for (var i = s.length - 2; i >= 0; i--) {
      base = s[i];
      if (s[i].t < cutoff) break;
    }
    if (base === latest) return 0;
    var seconds = (now - base.t) / 1000;
    return seconds > 0 ? Math.max(0, (latest.bytes - base.bytes) / seconds) : 0;
  };

  // Decide how many transfers to run: probe with one, then add one at a time
  // while the total speed keeps rising by TUNE_GAIN, and settle where adding
  // another stopped helping.
  UploadQueue.prototype.autoTune = function(now) {
    var t = this.tune;
    var waiting = this.count("queued") + this.count("uploading");

    // Nothing sending: restart the measurement from this level next time.
    if (this.count("uploading") === 0) { t.windowStart = null; return; }
    if (t.phase === "hold" && t.settledAt == null) t.settledAt = now;

    if (t.phase === "probe") {
      var elapsed = now - (t.probeStart == null ? now : t.probeStart);
      var moved = this.movedBytes();
      var probeFileDone = this.doneBytes > 0;
      if (probeFileDone || (elapsed >= PROBE_MIN_MS && moved >= PROBE_MIN_BYTES) || elapsed >= PROBE_MAX_MS) {
        t.level[1] = this.speed(now, Math.max(1000, Math.min(elapsed, SPEED_WINDOW_MS)));
        t.phase = "ramp";
        t.windowStart = now;
        t.windowAt = this.movedBytes();
        this._grow(now);
      }
      return;
    }

    if (t.phase === "ramp") {
      if (t.windowStart == null) { t.windowStart = now; t.windowAt = this.movedBytes(); return; }
      if (now - t.windowStart < TUNE_WINDOW_MS) return;

      var rate = (this.movedBytes() - t.windowAt) / ((now - t.windowStart) / 1000);
      t.level[t.target] = rate;
      var prev = t.level[t.target - 1];
      t.windowStart = now;
      t.windowAt = this.movedBytes();

      if (prev != null && prev > 0 && rate < prev * TUNE_GAIN) {
        // The extra transfer did not pay for itself.
        t.target = Math.max(1, t.target - 1);
        this._settle(now);
      } else if (t.target >= this.cap || waiting <= t.target) {
        this._settle(now);
      } else {
        this._grow(now);
      }
      return;
    }

    // hold: look again now and then.
    if (t.phase === "hold" && this.cap > 1 && waiting > t.target && now - t.settledAt >= RETUNE_MS) {
      t.phase = "ramp";
      t.level[t.target] = this.speed(now, TUNE_WINDOW_MS);
      t.windowStart = now;
      t.windowAt = this.movedBytes();
      this._grow(now);
    }
  };

  UploadQueue.prototype._grow = function(now) {
    var t = this.tune;
    if (t.target >= this.cap) { this._settle(now); return; }
    t.target += 1;
    t.windowStart = now;
    t.windowAt = this.movedBytes();
  };

  UploadQueue.prototype._settle = function(now) {
    this.tune.phase = "hold";
    this.tune.settledAt = now;
  };

  // --- Controls. Each returns the entry ref to cancel on the server, if one
  // --- is in flight, else null.

  UploadQueue.prototype.pause = function(id) {
    var it = this.get(id);
    if (!it) return null;
    if (it.state === "queued") { it.state = "paused"; return null; }
    if (it.state === "uploading") { return this._stop(it, "paused"); }
    return null;
  };

  UploadQueue.prototype.resume = function(id) {
    var it = this.get(id);
    if (it && it.state === "paused") it.state = "queued";
    return null;
  };

  UploadQueue.prototype.skip = function(id) {
    var it = this.get(id);
    if (!it || !ACTIVE[it.state]) return null;
    return this._stop(it, "skipped");
  };

  UploadQueue.prototype.restore = function(id) {
    var it = this.get(id);
    if (it && it.state === "skipped") it.state = "queued";
    return null;
  };

  UploadQueue.prototype.cancel = function(id) {
    var it = this.get(id);
    if (!it || !(ACTIVE[it.state] || it.state === "skipped" || it.state === "failed")) return null;
    return this._stop(it, "cancelled");
  };

  UploadQueue.prototype.retry = function(id) {
    var it = this.get(id);
    if (it && it.state === "failed") { it.state = "queued"; it.error = null; it.bytes = 0; it.seen = false; it.started = false; it.ref = null; it.attempts = 0; }
    return null;
  };

  // Moves a waiting file to the front of the line.
  UploadQueue.prototype.prioritize = function(id) {
    var it = this.get(id);
    if (!it || (it.state !== "queued" && it.state !== "paused")) return null;
    it.state = "queued";
    var from = this.items.indexOf(it);
    this.items.splice(from, 1);
    var at = 0;
    while (at < this.items.length && this.items[at].state !== "queued") at++;
    this.items.splice(at, 0, it);
    return null;
  };

  UploadQueue.prototype._stop = function(it, state) {
    var ref = it.state === "uploading" ? it.ref : null;
    if (ref) this.stale[ref] = true;
    it.state = state;
    it.bytes = 0;
    it.seen = false;
    it.started = false;
    it.ref = null;
    return ref;
  };

  // Hold everything (files already sending carry on); resume lets the queue
  // run again.
  UploadQueue.prototype.pauseAll = function() { this.paused = true; };
  UploadQueue.prototype.resumeAll = function() { this.paused = false; };

  UploadQueue.prototype.cancelAll = function() {
    var refs = [];
    for (var i = 0; i < this.items.length; i++) {
      var it = this.items[i];
      if (ACTIVE[it.state] || it.state === "skipped") {
        var ref = this._stop(it, "cancelled");
        if (ref) refs.push(ref);
      }
    }
    this.paused = false;
    return refs;
  };

  UploadQueue.prototype.retryFailed = function() {
    for (var i = 0; i < this.items.length; i++) this.retry(this.items[i].id);
  };

  // Drops what is over and done with from the list.
  UploadQueue.prototype.clearFinished = function() {
    this.items = this.items.filter(function(it) {
      return it.state !== "done" && it.state !== "cancelled";
    });
    if (!this.items.length) this.reset();
  };

  UploadQueue.prototype.reset = function() {
    this.samples = [];
    this.ghosts = {};
    this.stale = {};
    this.doneBytes = 0;
    this.paused = false;
    this.tune = {
      phase: this.cap > 1 ? "probe" : "hold",
      target: 1,
      level: {},
      windowStart: null,
      windowAt: null,
      settledAt: null,
      probeStart: null
    };
  };

  // Anything still to do or in progress.
  UploadQueue.prototype.busy = function() {
    for (var i = 0; i < this.items.length; i++) {
      var s = this.items[i].state;
      if (s === "queued" || s === "uploading") return true;
    }
    return false;
  };

  UploadQueue.prototype.stats = function(now) {
    var total = 0;
    var remaining = 0;
    var counts = { queued: 0, uploading: 0, paused: 0, skipped: 0, done: 0, failed: 0, cancelled: 0 };
    for (var i = 0; i < this.items.length; i++) {
      var it = this.items[i];
      counts[it.state]++;
      if (it.state !== "cancelled" && it.state !== "skipped") {
        total += it.size;
        remaining += it.size - (it.state === "done" ? it.size : it.bytes);
      }
    }
    var speed = this.speed(now);
    return {
      counts: counts,
      total: this.items.length,
      active: counts.uploading,
      target: this.tune.target,
      cap: this.cap,
      phase: this.tune.phase,
      speed: speed,
      bytesTotal: total,
      bytesLeft: remaining,
      eta: speed > 1000 ? remaining / speed * 1000 : null,
      paused: this.paused
    };
  };

  // --------------------------------------------------------------------------
  // Formatting
  // --------------------------------------------------------------------------
  function formatBytes(n) {
    if (!isFinite(n) || n < 0) n = 0;
    if (n < 1000) return Math.round(n) + " B";
    var units = ["KB", "MB", "GB", "TB"];
    var v = n;
    for (var i = 0; i < units.length; i++) {
      v = v / 1000;
      if (v < 1000 || i === units.length - 1) return (v >= 100 ? String(Math.round(v)) : v.toFixed(1)) + " " + units[i];
    }
  }

  function formatDuration(ms) {
    var s = Math.max(0, Math.round(ms / 1000));
    if (s < 60) return s + "s";
    var m = Math.floor(s / 60);
    if (m < 60) return m + "m " + (s % 60) + "s";
    return Math.floor(m / 60) + "h " + (m % 60) + "m";
  }

  function fill(template, vars) {
    return String(template).replace(/%\{(\w+)\}/g, function(_, k) {
      return vars[k] == null ? "" : vars[k];
    });
  }

  // --------------------------------------------------------------------------
  // The hook: the page side of it.
  // --------------------------------------------------------------------------
  var UploadManagerHook = {
    mounted: function() {
      var self = this;
      var d = this.el.dataset;
      this.uploadRef = d.uploadRef;
      this.uploadName = d.uploadName || "";
      this.entriesId = d.entries;
      this.cancelEvent = d.cancelEvent || "pk_upload_cancel";
      this.cancelTarget = d.cancelTarget || null;
      try { this.labels = JSON.parse(d.labels || "{}"); } catch (_e) { this.labels = {}; }
      this.queue = new UploadQueue({ cap: d.max });
      this.rowTemplate = this.el.querySelector('[data-role="row"]');
      this.list = this.el.querySelector('[data-role="list"]');
      this.rowEls = {};
      this.collapsed = false;

      // Files are caught where they arrive, on the element that holds the
      // upload's input: the component's own wrapper ("self", the default, for
      // a manager that renders the drop zone), the element the component sits
      // in ("parent", for a page with an input of its own), or whatever a CSS
      // selector names.
      var wrapper = this.el.parentElement;
      var scope = d.scope === "parent"
        ? wrapper && wrapper.parentElement
        : (!d.scope || d.scope === "self" ? wrapper : document.querySelector(d.scope));
      this.scope = scope || wrapper || document;

      this.onPick = function(e) { self._onPick(e); };
      this.scope.addEventListener("input", this.onPick, true);
      this.scope.addEventListener("change", this.onPick, true);

      this.onClick = function(e) { self._onClick(e); };
      this.el.addEventListener("click", this.onClick);

      this.onUnload = function(e) {
        if (self.queue.busy()) { e.preventDefault(); e.returnValue = ""; return ""; }
      };
      window.addEventListener("beforeunload", this.onUnload);

      var entries = document.getElementById(this.entriesId);
      if (entries && typeof MutationObserver === "function") {
        this.observer = new MutationObserver(function() { self.sync(); });
        this.observer.observe(entries, { childList: true, subtree: true, attributes: true });
      }

      this.timer = setInterval(function() { if (self.queue.items.length) self.sync(); }, TICK_MS);
      this.render();
    },

    // LiveView rebinding or a re-mount of the page under this hook: nothing
    // to do, the queue lives in this object.
    updated: function() {},

    destroyed: function() {
      clearInterval(this.timer);
      if (this.observer) this.observer.disconnect();
      this.scope.removeEventListener("input", this.onPick, true);
      this.scope.removeEventListener("change", this.onPick, true);
      this.el.removeEventListener("click", this.onClick);
      window.removeEventListener("beforeunload", this.onUnload);
    },

    _input: function() {
      return document.querySelector('input[type="file"][data-phx-upload-ref="' + this.uploadRef + '"]');
    },

    // Files arriving at LiveView's input (a click on the picker, a drop that
    // injected them) are taken here and handed over later, a few at a time.
    // What this hook hands over itself is flagged and passes.
    _onPick: function(e) {
      var input = e.target;
      if (!input || input.tagName !== "INPUT" || input.type !== "file") return;
      if (input.getAttribute("data-phx-upload-ref") !== this.uploadRef) return;
      if (e.__pkUploadManagerFeed) return;

      var files = input.files ? Array.prototype.slice.call(input.files) : [];
      e.stopImmediatePropagation();
      if (!files.length) return;
      try { input.value = ""; } catch (_e) { /* a read-only input is not ours to clear */ }

      this.queue.add(files);
      this.sync();
    },

    _rows: function() {
      var host = document.getElementById(this.entriesId);
      if (!host) return [];
      var out = [];
      var nodes = host.querySelectorAll("[data-pk-upload-entry]");
      for (var i = 0; i < nodes.length; i++) {
        var d = nodes[i].dataset;
        out.push({
          ref: d.ref,
          key: d.key,
          size: parseInt(d.size, 10) || 0,
          progress: parseInt(d.progress, 10) || 0,
          done: d.done === "true",
          error: d.error || ""
        });
      }
      return out;
    },

    sync: function() {
      var now = Date.now();
      var cancels = this.queue.observe(this._rows(), now);
      for (var i = 0; i < cancels.length; i++) this._cancelEntry(cancels[i]);

      this.queue.autoTune(now);
      var feed = this.queue.next(now);
      if (feed.length) this._feed(feed);

      this.render(now);
    },

    _feed: function(items) {
      var input = this._input();
      if (!input || typeof DataTransfer === "undefined") {
        items.forEach(function(it) { it.state = "failed"; it.error = "no_input"; });
        return;
      }
      var dt = new DataTransfer();
      items.forEach(function(it) {
        // LiveView stamps the File objects it has handled. One that was
        // cancelled and is being sent again (a resume, a retry) is given as a
        // fresh object over the same bytes, so it cannot be mistaken for the
        // transfer that was stopped.
        var file = it.file;
        if (it.attempts > 1 && typeof File === "function") {
          file = new File([file], file.name, { type: file.type, lastModified: file.lastModified });
          it.file = file;
        }
        dt.items.add(file);
      });
      input.files = dt.files;
      var ev = new Event("input", { bubbles: true });
      ev.__pkUploadManagerFeed = true;
      input.dispatchEvent(ev);
    },

    _cancelEntry: function(ref) {
      if (!ref) return;
      var payload = { ref: ref, name: this.uploadName };
      if (this.cancelTarget) this.pushEventTo(this.cancelTarget, this.cancelEvent, payload);
      else this.pushEvent(this.cancelEvent, payload);
    },

    _onClick: function(e) {
      var btn = e.target && e.target.closest ? e.target.closest("[data-act]") : null;
      if (!btn || !this.el.contains(btn)) return;
      var act = btn.dataset.act;
      var li = btn.closest("[data-item]");
      var id = li ? parseInt(li.dataset.item, 10) : null;
      var q = this.queue;
      var ref = null;

      switch (act) {
        case "pause": ref = q.pause(id); break;
        case "resume": q.resume(id); break;
        case "skip": ref = q.skip(id); break;
        case "restore": q.restore(id); break;
        case "cancel": ref = q.cancel(id); break;
        case "retry": q.retry(id); break;
        case "prioritize": q.prioritize(id); break;
        case "pause-all": q.pauseAll(); break;
        case "resume-all": q.resumeAll(); break;
        case "cancel-all": q.cancelAll().forEach(this._cancelEntry.bind(this)); break;
        case "retry-failed": q.retryFailed(); break;
        case "clear": q.clearFinished(); break;
        case "collapse": this.collapsed = !this.collapsed; break;
        default: return;
      }
      if (ref) this._cancelEntry(ref);
      e.preventDefault();
      this.sync();
    },

    _t: function(key, vars) {
      return fill(this.labels[key] || key, vars || {});
    },

    // --- Drawing. Text only goes in through textContent: file names are
    // --- whatever the user's disk holds.
    render: function(now) {
      now = now || Date.now();
      var q = this.queue;
      var s = q.stats(now);
      var el = this.el;

      if (!q.items.length) { el.hidden = true; return; }
      el.hidden = false;

      var setText = function(role, text) {
        var n = el.querySelector('[data-role="' + role + '"]');
        if (n && n.textContent !== text) n.textContent = text;
      };

      var finished = s.counts.done;
      var live = s.counts.uploading + s.counts.queued + s.counts.paused;
      var head = live
        ? this._t("summary_active", { done: finished, total: s.total })
        : this._t("summary_finished", { done: finished, total: s.total });
      setText("summary", head);

      var detail = [];
      if (s.counts.uploading) {
        detail.push(this._t("at_once", { count: s.counts.uploading }));
        detail.push(formatBytes(s.speed) + "/s");
        if (s.eta != null && s.counts.uploading + s.counts.queued > 0) detail.push(this._t("eta", { time: formatDuration(s.eta) }));
      }
      if (s.phase === "probe" && s.counts.uploading) detail.push(this._t("measuring"));
      else if (s.cap > 1 && s.counts.uploading) detail.push(this._t("auto", { max: s.cap }));
      if (s.paused) detail.push(this._t("paused_all"));
      if (s.counts.failed) detail.push(this._t("failed_count", { count: s.counts.failed }));
      setText("detail", detail.join(" · "));

      this._show("pause-all", !s.paused && (s.counts.queued || s.counts.uploading));
      this._show("resume-all", s.paused);
      this._show("cancel-all", live || s.counts.skipped);
      this._show("retry-failed", s.counts.failed > 0);
      this._show("clear", !live && (s.counts.done || s.counts.cancelled));

      var bar = el.querySelector('[data-role="total"]');
      if (bar) {
        bar.max = Math.max(1, s.bytesTotal);
        bar.value = s.bytesTotal - s.bytesLeft;
      }

      this.list.hidden = this.collapsed;
      var toggle = el.querySelector('[data-act="collapse"]');
      if (toggle) toggle.setAttribute("aria-expanded", this.collapsed ? "false" : "true");

      if (!this.collapsed) this._renderRows();
    },

    _show: function(act, on) {
      var n = this.el.querySelector('[data-act="' + act + '"]');
      if (n) n.hidden = !on;
    },

    _renderRows: function() {
      var self = this;
      var seen = {};
      var anchor = null;

      // What needs attention or is moving goes first; what is over goes last.
      var rank = { failed: 0, uploading: 1, paused: 2, queued: 3, skipped: 4, done: 5, cancelled: 6 };
      var ordered = this.queue.items
        .map(function(it, at) { return { it: it, at: at }; })
        .sort(function(a, b) { return (rank[a.it.state] - rank[b.it.state]) || (a.at - b.at); })
        .map(function(x) { return x.it; });

      ordered.forEach(function(it) {
        seen[it.id] = true;
        var li = self.rowEls[it.id];
        if (!li) {
          li = self.rowTemplate.content.firstElementChild.cloneNode(true);
          li.dataset.item = String(it.id);
          li.querySelector('[data-role="name"]').textContent = it.name;
          li.querySelector('[data-role="name"]').title = it.name;
          self.rowEls[it.id] = li;
        }
        // Keep the list in queue order.
        var want = anchor ? anchor.nextSibling : self.list.firstChild;
        if (li !== want) self.list.insertBefore(li, want);
        anchor = li;

        li.dataset.state = it.state;
        var pct = it.size > 0 ? Math.min(100, Math.round(it.bytes / it.size * 100)) : (it.state === "done" ? 100 : 0);

        var status;
        switch (it.state) {
          case "queued": status = self._t("st_queued"); break;
          case "uploading": status = pct + "% · " + formatBytes(it.size); break;
          case "paused": status = self._t("st_paused"); break;
          case "skipped": status = self._t("st_skipped"); break;
          case "done": status = self._t("st_done") + " · " + formatBytes(it.size); break;
          case "cancelled": status = self._t("st_cancelled"); break;
          case "failed": status = self._t("err_" + it.error) !== "err_" + it.error ? self._t("err_" + it.error) : (it.error || self._t("st_failed")); break;
        }
        var st = li.querySelector('[data-role="status"]');
        if (st.textContent !== status) st.textContent = status;

        var prog = li.querySelector('[data-role="progress"]');
        prog.hidden = !(it.state === "uploading" || it.state === "done");
        prog.value = pct;

        var allowed = {
          prioritize: it.state === "queued" || it.state === "paused",
          pause: it.state === "queued" || it.state === "uploading",
          resume: it.state === "paused",
          skip: it.state === "queued" || it.state === "paused" || it.state === "uploading",
          restore: it.state === "skipped",
          retry: it.state === "failed",
          cancel: it.state === "queued" || it.state === "paused" || it.state === "uploading" || it.state === "skipped" || it.state === "failed"
        };
        Object.keys(allowed).forEach(function(act) {
          var b = li.querySelector('[data-act="' + act + '"]');
          if (b) b.hidden = !allowed[act];
        });
      });

      Object.keys(this.rowEls).forEach(function(id) {
        if (!seen[id]) { self.rowEls[id].remove(); delete self.rowEls[id]; }
      });
    }
  };

  window.PhoenixKitUploadManager = {
    UploadQueue: UploadQueue,
    fileKey: fileKey,
    formatBytes: formatBytes,
    formatDuration: formatDuration,
    hook: UploadManagerHook
  };

  window.PhoenixKitHooks = window.PhoenixKitHooks || {};
  window.PhoenixKitHooks.UploadManager = UploadManagerHook;
})();
