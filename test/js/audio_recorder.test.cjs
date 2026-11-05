"use strict";

// The pure logic of the AudioRecorder hook in priv/static/assets/phoenix_kit.js,
// and the races a browser run cannot be trusted to hit. The bundle is browser code
// (IIFEs that assign onto `window`), so the globals it touches at load are stubbed.
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

const storage = { getItem: () => null, setItem: noop, removeItem: noop, key: () => null, length: 0 };

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
  encodeWav,
  clock,
  meterLevel,
  extensionFor,
  errorReason,
  canRecord,
} = require("../../priv/static/assets/phoenix_kit.js");

const hook = window.PhoenixKitHooks.AudioRecorder;

// `encodeWav` and the component's `clip/3` must agree byte for byte: the component
// matches this exact header, so a change here that is not made there ends every
// clip as `:unreadable`.
test("encodeWav writes the header the component reads", () => {
  const view = new DataView(encodeWav(new Float32Array(16000), 16000));
  const text = (at, n) =>
    String.fromCharCode(...Array.from({ length: n }, (_, i) => view.getUint8(at + i)));

  assert.equal(view.byteLength, 44 + 32000);
  assert.equal(text(0, 4), "RIFF");
  assert.equal(view.getUint32(4, true), 36 + 32000);
  assert.equal(text(8, 4), "WAVE");
  assert.equal(text(12, 4), "fmt ");
  assert.equal(view.getUint32(16, true), 16, "fmt chunk size");
  assert.equal(view.getUint16(20, true), 1, "PCM");
  assert.equal(view.getUint16(22, true), 1, "mono");
  assert.equal(view.getUint32(24, true), 16000, "sample rate");
  assert.equal(view.getUint32(28, true), 32000, "bytes a second");
  assert.equal(view.getUint16(32, true), 2, "block align");
  assert.equal(view.getUint16(34, true), 16, "bits a sample");
  assert.equal(text(36, 4), "data");
  assert.equal(view.getUint32(40, true), 32000);
});

test("encodeWav scales samples to 16 bits and clips what is out of range", () => {
  const view = new DataView(encodeWav(Float32Array.from([0, 1, -1, 2, -2, 0.5]), 16000));
  const sample = (i) => view.getInt16(44 + i * 2, true);

  assert.equal(sample(0), 0);
  assert.equal(sample(1), 32767);
  assert.equal(sample(2), -32768);
  assert.equal(sample(3), 32767, "over full scale clips, it does not wrap");
  assert.equal(sample(4), -32768);
  assert.equal(sample(5), 16383);
});

test("clock counts minutes and seconds", () => {
  assert.equal(clock(0), "0:00");
  assert.equal(clock(9), "0:09");
  assert.equal(clock(60), "1:00");
  assert.equal(clock(185), "3:05");
});

test("meterLevel reads silence as nothing and caps at 100", () => {
  assert.equal(meterLevel(Uint8Array.from([128, 128, 128])), 0);
  assert.equal(meterLevel(Uint8Array.from([128, 160, 128])), 50);
  assert.equal(meterLevel(Uint8Array.from([0, 255])), 100);
});

test("extensionFor names the file so the upload's accept takes it", () => {
  assert.equal(extensionFor("audio/webm"), "webm");
  assert.equal(extensionFor("audio/ogg"), "ogg");
  assert.equal(extensionFor("audio/mp4"), "mp4");
  assert.equal(extensionFor("audio/aac"), "mp4");
  assert.equal(extensionFor(""), "webm");
  assert.equal(extensionFor(undefined), "webm");
});

test("errorReason tells a refusal from a missing microphone", () => {
  assert.equal(errorReason({ name: "NotAllowedError" }), "denied");
  assert.equal(errorReason({ name: "SecurityError" }), "denied");
  assert.equal(errorReason({ name: "NotFoundError" }), "unavailable");
  assert.equal(errorReason({ name: "NotReadableError" }), "unavailable");
  assert.equal(errorReason(undefined), "unavailable");
});

test("canRecord needs a secure context, the microphone and, for a WAV, Web Audio", () => {
  const full = () => ({
    isSecureContext: true,
    navigator: { mediaDevices: { getUserMedia: noop } },
    MediaRecorder: noop,
    AudioContext: noop,
    OfflineAudioContext: noop,
  });

  assert.equal(canRecord(full(), "wav_16k"), true);
  assert.equal(canRecord({ ...full(), isSecureContext: false }, "wav_16k"), false);
  assert.equal(canRecord({ ...full(), navigator: {} }, "wav_16k"), false);
  assert.equal(canRecord({ ...full(), MediaRecorder: undefined }, "native"), false);

  const noWebAudio = { ...full(), AudioContext: undefined, OfflineAudioContext: undefined };
  assert.equal(canRecord(noWebAudio, "wav_16k"), false);
  assert.equal(canRecord(noWebAudio, "native"), true, "a native clip is not converted");

  const safari = { ...full(), AudioContext: undefined, webkitAudioContext: noop };
  assert.equal(canRecord(safari, "wav_16k"), true);
});

// `navigator` is a read-only getter on Node's global.
function microphone(getUserMedia) {
  Object.defineProperty(globalThis, "navigator", {
    value: { mediaDevices: { getUserMedia } },
    configurable: true,
    writable: true,
  });
}

function fakeTracks() {
  const track = { stopped: false, stop() { this.stopped = true; } };
  return { track, stream: { getTracks: () => [track] } };
}

function fakeHook(overrides = {}) {
  const pushes = [];
  return Object.assign(Object.create(hook), {
    el: { dataset: {} },
    state: "idle",
    chunks: [],
    pushes,
    pushEventTo: (_el, event, payload) => pushes.push([event, payload]),
    show: noop,
    part: () => ({ focus: noop }),
    ...overrides,
  });
}

// The permission prompt can outlive the page. A stream that arrives after that still
// holds the microphone, and nothing else will ever stop it.
test("a stream granted after the recorder is gone is stopped at once", async () => {
  const { track, stream } = fakeTracks();
  let grant;
  microphone(() => new Promise((r) => (grant = r)));

  const recorder = fakeHook();
  const started = recorder.start();
  recorder.gone = true;
  grant(stream);
  await started;

  assert.equal(track.stopped, true);
  assert.equal(recorder.stream, undefined);
  assert.deepEqual(recorder.pushes, []);
});

test("a refusal after the recorder is gone pushes nothing", async () => {
  let refuse;
  microphone(() => new Promise((_r, reject) => (refuse = reject)));

  const recorder = fakeHook();
  const started = recorder.start();
  recorder.gone = true;
  refuse({ name: "NotAllowedError" });
  await started;

  assert.deepEqual(recorder.pushes, []);
});

test("a second press while the browser is asking starts nothing", async () => {
  let asked = 0;
  microphone(() => (asked++, new Promise(noop)));

  const recorder = fakeHook();
  recorder.start();
  await recorder.start();

  assert.equal(asked, 1);
});

test("busy stops a recording from starting", async () => {
  let asked = 0;
  microphone(() => (asked++, new Promise(noop)));

  await fakeHook({ el: { dataset: { busy: "true" } } }).start();

  assert.equal(asked, 0);
});

test("a recording that captured nothing is reported, not sent", async () => {
  const backToIdle = [];
  const recorder = fakeHook({
    sending: true,
    recorder: { mimeType: "audio/webm" },
    backToIdle: () => backToIdle.push(true),
  });

  await recorder.finish();

  assert.deepEqual(recorder.pushes, [["recorder_error", { reason: "unreadable" }]]);
  assert.equal(backToIdle.length, 1);
});

test("a settled event for another recorder leaves this one preparing", () => {
  let handler;
  const originalCanRecord = window.isSecureContext;
  Object.assign(window, {
    isSecureContext: true,
    MediaRecorder: noop,
    navigator: { mediaDevices: { getUserMedia: noop } },
  });

  const settled = [];
  const recorder = fakeHook({
    el: { dataset: { recorder: "mine", format: "native" }, addEventListener: noop, hidden: true },
    handleEvent: (_name, fn) => (handler = fn),
    settle: () => settled.push(true),
  });
  recorder.mounted();
  recorder.state = "preparing";

  handler({ id: "theirs" });
  assert.equal(settled.length, 0);

  handler({ id: "mine" });
  assert.equal(settled.length, 1);

  window.isSecureContext = originalCanRecord;
});

test("reconnecting during an upload ends it and says so", () => {
  const settled = [];
  const recorder = fakeHook({ state: "preparing", settle: () => settled.push(true) });

  recorder.reconnected();

  assert.equal(settled.length, 1);
  assert.deepEqual(recorder.pushes, [["recorder_error", { reason: "failed" }]]);
});

test("reconnecting while idle or recording does nothing", () => {
  for (const state of ["idle", "recording"]) {
    const recorder = fakeHook({ state, settle: () => assert.fail("settled") });
    recorder.reconnected();
    assert.deepEqual(recorder.pushes, []);
  }
});
