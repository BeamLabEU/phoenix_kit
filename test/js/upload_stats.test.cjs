"use strict";

// Unit tests for the pure math behind the UploadStats hook in
// priv/static/assets/phoenix_kit.js — the live "3.2 MB / 12.4 MB · 2.8 MB/s ·
// 4s left" line under upload progress bars, and its "Processing on server…"
// phase once the transfer hits 100%. The bundle is browser code (IIFEs that
// assign onto `window`), so stub the globals it touches at load time; the
// DOM-using parts themselves are not invoked here.
//
// Run: mix test.js  (node --test needs the explicit file on Node 25)

const test = require("node:test");
const assert = require("node:assert/strict");

const noop = () => {};

function stubElement() {
  return {
    style: {},
    dataset: {},
    classList: { add: noop, remove: noop, toggle: noop, contains: () => false },
    setAttribute: noop,
    getAttribute: () => null,
    removeAttribute: noop,
    appendChild: noop,
    remove: noop,
    addEventListener: noop,
    removeEventListener: noop,
    querySelector: () => null,
    querySelectorAll: () => [],
  };
}

global.document = {
  documentElement: stubElement(),
  head: stubElement(),
  body: stubElement(),
  createElement: stubElement,
  createTextNode: () => ({}),
  getElementById: () => null,
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener: noop,
  removeEventListener: noop,
  readyState: "complete",
};

const storage = {
  getItem: () => null,
  setItem: noop,
  removeItem: noop,
  key: () => null,
  length: 0,
};

global.window = {
  PhoenixKitHooks: {},
  addEventListener: noop,
  removeEventListener: noop,
  matchMedia: () => ({ matches: false, addEventListener: noop, removeEventListener: noop }),
  localStorage: storage,
  sessionStorage: storage,
  location: { href: "http://localhost/", reload: noop },
  navigator: { userAgent: "node" },
  document: global.document,
  setTimeout,
  clearTimeout,
};

global.localStorage = storage;
global.sessionStorage = storage;

const {
  formatBytes,
  formatDuration,
  windowSpeed,
  uploadStatsText,
} = require("../../priv/static/assets/phoenix_kit.js");

// ── formatBytes ─────────────────────────────────────────────────────────────
// Decimal units (base 1000), matching the Elixir-side Format.bytes calls.

test("formatBytes: bytes below 1000 stay in B, rounded", () => {
  assert.equal(formatBytes(0), "0 B");
  assert.equal(formatBytes(999), "999 B");
  assert.equal(formatBytes(512.6), "513 B");
});

test("formatBytes: one decimal under 100, none above", () => {
  assert.equal(formatBytes(1000), "1.0 KB");
  assert.equal(formatBytes(12_400_000), "12.4 MB");
  assert.equal(formatBytes(104_000_000), "104 MB");
  assert.equal(formatBytes(1_200_000_000), "1.2 GB");
});

test("formatBytes: garbage becomes 0 B, huge stays TB", () => {
  assert.equal(formatBytes(NaN), "0 B");
  assert.equal(formatBytes(-5), "0 B");
  assert.equal(formatBytes(2.5e12), "2.5 TB");
  assert.equal(formatBytes(2.5e15), "2500 TB");
});

// ── formatDuration ──────────────────────────────────────────────────────────

test("formatDuration: seconds, minutes, hours", () => {
  assert.equal(formatDuration(0), "0s");
  assert.equal(formatDuration(3400), "3s");
  assert.equal(formatDuration(59_400), "59s");
  assert.equal(formatDuration(72_000), "1m 12s");
  assert.equal(formatDuration(3_840_000), "1h 4m");
});

test("formatDuration: negative clamps to 0s", () => {
  assert.equal(formatDuration(-100), "0s");
});

// ── windowSpeed ─────────────────────────────────────────────────────────────

test("windowSpeed: steady transfer measures bytes over the sampled span", () => {
  // 1 MB/s: 0 bytes at t=0, 2 MB at t=2000, asked at t=2000.
  const samples = [
    { t: 0, bytes: 0 },
    { t: 1000, bytes: 1_000_000 },
    { t: 2000, bytes: 2_000_000 },
  ];
  assert.equal(windowSpeed(samples, 2000), 1_000_000);
});

test("windowSpeed: a stall decays the speed instead of freezing it", () => {
  // Same transfer, but 8s have passed with no new bytes; the denominator
  // runs to `now`, so 2 MB over 10s → 200 KB/s, falling as time passes.
  const samples = [
    { t: 0, bytes: 0 },
    { t: 2000, bytes: 2_000_000 },
  ];
  assert.equal(windowSpeed(samples, 10_000), 200_000);
  assert.ok(windowSpeed(samples, 20_000) < windowSpeed(samples, 10_000));
});

test("windowSpeed: baseline anchors just outside the sliding window", () => {
  // Window is 5s. At now=6000 the t=0 sample is outside, but it is the
  // newest sample older than the cutoff, so it still anchors the span:
  // 6 MB over 6s = 1 MB/s (not 5 MB over 5s).
  const samples = [
    { t: 0, bytes: 0 },
    { t: 2000, bytes: 2_000_000 },
    { t: 6000, bytes: 6_000_000 },
  ];
  assert.equal(windowSpeed(samples, 6000), 1_000_000);
});

test("windowSpeed: fewer than two samples reads 0", () => {
  assert.equal(windowSpeed([], 1000), 0);
  assert.equal(windowSpeed([{ t: 0, bytes: 500 }], 1000), 0);
  assert.equal(windowSpeed(null, 1000), 0);
});

test("windowSpeed: never returns a negative rate", () => {
  const samples = [
    { t: 0, bytes: 1000 },
    { t: 1000, bytes: 0 },
  ];
  assert.equal(windowSpeed(samples, 1000), 0);
});

// ── uploadStatsText ─────────────────────────────────────────────────────────

test("uploadStatsText: transfer line carries size, speed, and ETA", () => {
  // 2 MB of 12 MB done, 1 MB/s → 10s left.
  const samples = [
    { t: 0, bytes: 0 },
    { t: 2000, bytes: 2_000_000 },
  ];
  const line = uploadStatsText({
    size: 12_000_000,
    bytes: 2_000_000,
    samples,
    now: 2000,
    doneAt: null,
    labels: { left: "left" },
  });
  assert.equal(line, "2.0 MB / 12.0 MB · 1.0 MB/s · 10s left");
});

test("uploadStatsText: no measurable speed yet → size progress only", () => {
  const line = uploadStatsText({
    size: 12_000_000,
    bytes: 0,
    samples: [{ t: 0, bytes: 0 }],
    now: 100,
    doneAt: null,
    labels: {},
  });
  assert.equal(line, "0 B / 12.0 MB");
});

test("uploadStatsText: processing phase shows total and a running clock", () => {
  const line = uploadStatsText({
    size: 12_000_000,
    bytes: 12_000_000,
    samples: [],
    now: 7400,
    doneAt: 4000,
    labels: { processing: "Processing on server…" },
  });
  assert.equal(line, "12.0 MB · Processing on server… 3s");
});

test("uploadStatsText: labels fall back to English when not passed", () => {
  const processing = uploadStatsText({
    size: 1000, bytes: 1000, samples: [], now: 1000, doneAt: 0,
  });
  assert.ok(processing.includes("Processing on server…"));

  const samples = [
    { t: 0, bytes: 0 },
    { t: 1000, bytes: 500 },
  ];
  const uploading = uploadStatsText({
    size: 1000, bytes: 500, samples, now: 1000, doneAt: null,
  });
  assert.ok(uploading.endsWith("left"));
});
