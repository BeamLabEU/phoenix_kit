"use strict";

// Unit tests for PkUploadEdit in priv/static/assets/phoenix_kit.js — the
// photo editor of `<.file_upload edit_images>`: which files it edits, the
// canvas transform for turns and flips, the crop in pixels; and the hook
// taking a selection before LiveView and handing the result back through
// `upload(name, files)`.
//
// Run: mix test.js  (node --test needs the explicit file on Node 25)
const test = require("node:test");
const assert = require("node:assert/strict");

const noop = () => {};

function stubElement() {
  return {
    style: {}, dataset: {},
    classList: { add: noop, remove: noop, toggle: noop, contains: () => false },
    setAttribute: noop, getAttribute: () => null, removeAttribute: noop,
    appendChild: noop, remove: noop, addEventListener: noop, removeEventListener: noop,
    querySelector: () => null, querySelectorAll: () => [],
  };
}

global.document = {
  documentElement: stubElement(), head: stubElement(), body: stubElement(),
  createElement: stubElement, createTextNode: () => ({}),
  getElementById: () => null, querySelector: () => null, querySelectorAll: () => [],
  addEventListener: noop, removeEventListener: noop, cookie: "",
};
const storage = { getItem: () => null, setItem: noop, removeItem: noop };
global.window = {
  addEventListener: noop, removeEventListener: noop,
  matchMedia: () => ({ matches: false, addEventListener: noop, removeEventListener: noop }),
  localStorage: storage, sessionStorage: storage,
  location: { href: "http://localhost/", reload: noop },
  navigator: { userAgent: "node" }, document: global.document, setTimeout, clearTimeout,
};
global.localStorage = storage;
global.sessionStorage = storage;

const pk = require("../../priv/static/assets/phoenix_kit.js");
const u = pk.uploadEdit;
const Hook = global.window.PhoenixKitHooks.PkUploadEdit;

// Where the matrix [a, b, c, d, e, f] sends the source point (x, y).
function apply(m, x, y) {
  return [m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]];
}

test("only pictures the browser can redraw are edited", () => {
  assert.equal(u.editable({ type: "image/jpeg" }), true);
  assert.equal(u.editable({ type: "image/PNG" }), true);
  assert.equal(u.editable({ type: "image/webp" }), true);
  assert.equal(u.editable({ type: "image/gif" }), false, "an animation would lose its frames");
  assert.equal(u.editable({ type: "image/heic" }), false);
  assert.equal(u.editable({ type: "application/pdf" }), false);
  assert.equal(u.editable(null), false);
});

test("quarter turns wrap and swap the size", () => {
  assert.equal(u.rotate(0, 90), 90);
  assert.equal(u.rotate(270, 90), 0);
  assert.equal(u.rotate(0, -90), 270);
  assert.deepEqual(u.dims(400, 300, 90), [300, 400]);
  assert.deepEqual(u.dims(400, 300, 180), [400, 300]);
});

test("the transform puts the source's corners where a turn and a flip put them", () => {
  const w = 400, h = 300;
  // Clockwise quarter turn: the top-left corner goes to the top right.
  assert.deepEqual(apply(u.matrix(w, h, 90, false, 1, 0, 0), 0, 0), [300, 0]);
  assert.deepEqual(apply(u.matrix(w, h, 90, false, 1, 0, 0), w, h), [0, 400]);
  assert.deepEqual(apply(u.matrix(w, h, 180, false, 1, 0, 0), 0, 0), [400, 300]);
  assert.deepEqual(apply(u.matrix(w, h, 270, false, 1, 0, 0), 0, 0), [0, 400]);
  // Mirrored, unturned: the top-left corner goes to the top right.
  assert.deepEqual(apply(u.matrix(w, h, 0, true, 1, 0, 0), 0, 0), [400, 0]);
  // Every corner lands inside the turned frame.
  for (const r of [0, 90, 180, 270]) {
    for (const flip of [false, true]) {
      const [W, H] = u.dims(w, h, r);
      for (const [x, y] of [[0, 0], [w, 0], [0, h], [w, h]]) {
        const [px, py] = apply(u.matrix(w, h, r, flip, 1, 0, 0), x, y);
        assert.ok(px >= 0 && px <= W && py >= 0 && py <= H, `${r} ${flip} ${x},${y} -> ${px},${py}`);
      }
    }
  }
  // Scaled for the preview and shifted by a crop.
  assert.deepEqual(apply(u.matrix(w, h, 0, false, 0.5, 100, 50), 100, 50), [0, 0]);
  assert.deepEqual(apply(u.matrix(w, h, 0, false, 0.5, 0, 0), w, h), [200, 150]);
});

// Where a picture `W` × `H` on screen sends (x, y) when turned a quarter
// clockwise (dir 90) or counterclockwise (-90).
function turnShown([x, y], W, H, dir) {
  return dir === 90 ? [H - y, x] : [y, W - x];
}

test("Rotate right after Flip still turns what is shown clockwise", () => {
  const w = 400, h = 300;
  // A mark at the top, left of centre: the asymmetric case.
  const mark = [100, 0];
  // Flipped: the mark is at the top, right of centre.
  assert.deepEqual(apply(u.matrix(w, h, 0, true, 1, 0, 0), ...mark), [300, 0]);
  // Rotate right: top-right goes to the right edge, low down.
  const r = u.turn(0, true, 90);
  assert.deepEqual(apply(u.matrix(w, h, r, true, 1, 0, 0), ...mark), [300, 300]);
  assert.notDeepEqual(apply(u.matrix(w, h, u.rotate(0, 90), true, 1, 0, 0), ...mark), [300, 300],
    "the plain stored turn would have gone counterclockwise");

  // Every state, both buttons: the new picture is the old one turned on screen.
  for (const rot of [0, 90, 180, 270]) {
    for (const flip of [false, true]) {
      for (const dir of [90, -90]) {
        const [W, H] = u.dims(w, h, rot);
        const next = u.turn(rot, flip, dir);
        for (const p of [[0, 0], [w, 0], [0, h], [100, 0], [w, h]]) {
          const before = apply(u.matrix(w, h, rot, flip, 1, 0, 0), ...p);
          const after = apply(u.matrix(w, h, next, flip, 1, 0, 0), ...p);
          assert.deepEqual(after, turnShown(before, W, H, dir), `${rot} ${flip} ${dir} ${p}`);
        }
      }
    }
  }
});

test("the uploaded photo is drawn with the preview's transform", () => {
  const w = 400, h = 300;
  for (const rot of [0, 90, 180, 270]) {
    for (const flip of [false, true]) {
      const scale = 0.5;
      const preview = u.matrix(w, h, rot, flip, scale, 0, 0);
      const full = u.matrix(w, h, rot, flip, 1, 0, 0);
      for (const p of [[0, 0], [100, 0], [w, h]]) {
        const a = apply(preview, ...p), b = apply(full, ...p);
        assert.deepEqual([a[0] / scale, a[1] / scale], b);
      }
    }
  }
});

test("a crop in percent becomes whole pixels inside the frame", () => {
  assert.deepEqual(u.cropPixels({ x: 10, y: 20, w: 50, h: 50 }, 1000, 500), { x: 100, y: 100, w: 500, h: 250 });
  assert.deepEqual(u.cropPixels(null, 1000, 500), { x: 0, y: 0, w: 1000, h: 500 });
  assert.deepEqual(u.cropPixels({ x: 5, y: 5, w: 0.1, h: 30 }, 1000, 500), { x: 0, y: 0, w: 1000, h: 500 }, "a click is no crop");
  const edge = u.cropPixels({ x: 99.99, y: 0, w: 5, h: 100 }, 1000, 500);
  assert.ok(edge.x + edge.w <= 1000 && edge.w >= 1);
});

test("an aspect picks the largest centred crop", () => {
  assert.deepEqual(u.aspect("16/9"), [16, 9]);
  assert.equal(u.aspect(""), null);
  assert.equal(u.aspect("x/0"), null);
  const sq = u.centeredCrop([1, 1], 400, 200);
  assert.deepEqual(sq, { x: 25, y: 0, w: 50, h: 100 });
  const wide = u.centeredCrop([4, 1], 400, 200);
  assert.deepEqual(wide, { x: 0, y: 25, w: 100, h: 50 });
  assert.equal(u.centeredCrop(null, 400, 200), null);
});

test("an unchanged photo is no edit", () => {
  assert.equal(u.changed({ rotation: 0, flip: false, crop: null }), false);
  assert.equal(u.changed({ rotation: 90, flip: false, crop: null }), true);
  assert.equal(u.changed({ rotation: 0, flip: true, crop: null }), true);
  assert.equal(u.changed({ rotation: 0, flip: false, crop: { x: 0, y: 0, w: 20, h: 20 } }), true);
});

test("the admin ImageEditor and the upload editor share one crop geometry", () => {
  const PK = global.window.PhoenixKitInternals;
  assert.equal(PK.imageEditorRect, pk.imageEditorRect);
  const r = pk.imageEditorRect({ x: 10, y: 10 }, { x: 50, y: 90 }, [1, 1], [200, 100]);
  // 1:1 in a 2:1 frame: 40% across is 80px, so 80% down; only 80% left below.
  assert.ok(Math.abs(r.w * 2 - r.h) < 1e-9);
});

// ── The hook ─────────────────────────────────────────────────────────────

function fakeHook({ multiple = true } = {}) {
  const listeners = {};
  const input = {
    type: "file", files: [], value: "x",
    hasAttribute: (k) => (k === "multiple" ? multiple : false),
  };
  const el = {
    dataset: { uploadName: "photos" },
    addEventListener(t, fn) { (listeners[t] = listeners[t] || []).push(fn); },
    removeEventListener: noop,
    contains: (x) => x === input,
    querySelector: (s) => (s === 'input[type="file"]' ? input : null),
  };
  const uploads = [];
  const hook = Object.assign(Object.create(Hook), { el, upload: (name, files) => uploads.push([name, files]) });
  hook.mounted();
  const fire = (type, ev) => (listeners[type] || []).forEach((fn) => fn(ev));
  return { hook, input, uploads, fire };
}

test("files the editor does not handle go straight through, once", () => {
  const { input, uploads, fire } = fakeHook();
  const pdf = { name: "a.pdf", type: "application/pdf" };
  const gif = { name: "b.gif", type: "image/gif" };
  input.files = [pdf, gif];
  let stopped = 0;
  const ev = { target: input, stopPropagation: () => stopped++ };
  fire("input", ev);
  input.files = [];
  fire("change", ev);
  assert.equal(stopped, 2, "LiveView never sees the raw selection");
  assert.equal(input.value, "");
  assert.deepEqual(uploads, [["photos", [pdf, gif]]]);
});

test("a photo waits for the editor; the hand-over is not taken again", () => {
  const { hook, input, uploads, fire } = fakeHook();
  const jpg = { name: "c.jpg", type: "image/jpeg" };
  const pdf = { name: "a.pdf", type: "application/pdf" };
  input.files = [jpg, pdf];
  fire("input", { target: input, stopPropagation: noop });
  // No dialog in this fake: the editor cannot open, so the photo goes up as it was.
  assert.deepEqual(uploads, [["photos", [jpg, pdf]]]);

  // While handing over, LiveView's own input event passes untouched.
  let stopped = false;
  hook._passing = true;
  fire("input", { target: input, stopPropagation: () => { stopped = true; } });
  hook._passing = false;
  assert.equal(stopped, false);
});

test("several files on a single-file input all reach LiveView, unedited, for its max_entries error", () => {
  const { hook, input, uploads, fire } = fakeHook({ multiple: false });
  const a = { name: "a.jpg", type: "image/jpeg" };
  const b = { name: "b.pdf", type: "application/pdf" };
  let edited = 0;
  hook._edit = () => { edited++; };
  fire("drop", {
    target: { closest: () => ({ classList: { remove: noop } }) },
    dataTransfer: { files: [a, b] },
    preventDefault: noop, stopPropagation: noop,
  });
  assert.deepEqual(uploads, [["photos", [a, b]]], "nothing silently dropped");
  assert.equal(edited, 0, "no editor for a drop LiveView will refuse");
  // One file on the same input still goes through the editor.
  input.files = [a];
  fire("input", { target: input, stopPropagation: noop });
  assert.equal(edited, 1);
});

test("a drop on the drop zone is taken before LiveView tracks it", () => {
  const { uploads, fire } = fakeHook();
  const pdf = { name: "a.pdf", type: "application/pdf" };
  const removed = [];
  const zone = { classList: { remove: (c) => removed.push(c) } };
  let prevented = 0;
  fire("drop", {
    target: { closest: () => zone },
    dataTransfer: { files: [pdf] },
    preventDefault: () => prevented++,
    stopPropagation: () => prevented++,
  });
  assert.equal(prevented, 2);
  assert.deepEqual(removed, ["phx-drop-target-active"]);
  assert.deepEqual(uploads, [["photos", [pdf]]]);
});

// ── The editor dialog, against a fake DOM ───────────────────────────────

const images = [];
global.Image = class {
  constructor() { this.naturalWidth = 400; this.naturalHeight = 300; images.push(this); }
};
global.URL = { createObjectURL: (f) => "blob:" + f.name, revokeObjectURL: noop };

// The canvas the edited photo is drawn on; `encode` answers its toBlob.
let encode = (type) => ({ type, size: 10 });
const realCreate = global.document.createElement;
global.document.createElement = (tag) => (tag === "canvas" ? fakeCanvas() : realCreate(tag));
function fakeCanvas() {
  const ctx = { setTransform: noop, clearRect: noop, drawImage: noop };
  return {
    width: 0, height: 0, getContext: () => ctx,
    toBlob(cb, type) { cb(encode(type)); },
  };
}

function button(attr, value) {
  return {
    attr, disabled: false, attrs: { [attr]: value == null ? "" : value },
    hasAttribute(k) { return k in this.attrs; },
    getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; },
    setAttribute(k, v) { this.attrs[k] = String(v); },
  };
}

function fakeEditor({ multiple = true, accept = null } = {}) {
  const listeners = {};
  const dlgListeners = {};
  const input = {
    type: "file", files: [], value: "x",
    hasAttribute: (k) => (k === "multiple" ? multiple : k === "accept" ? accept != null : false),
    getAttribute: (k) => (k === "accept" ? accept : null),
  };
  const buttons = {
    rotR: button("data-pk-edit-rotate", "90"), rotL: button("data-pk-edit-rotate", "-90"),
    flip: button("data-pk-edit-flip"), reset: button("data-pk-edit-reset"),
    skip: button("data-pk-edit-skip"), original: button("data-pk-edit-original"),
    apply: button("data-pk-edit-apply"),
  };
  const message = { hidden: true, textContent: "" };
  const parts = {
    "[data-pk-edit-canvas]": fakeCanvas(),
    "[data-pk-edit-crop]": { hidden: true, style: {} },
    "[data-pk-edit-name]": { textContent: "" },
    "[data-pk-edit-progress]": { textContent: "" },
    "[data-pk-edit-error]": message,
    "[data-pk-edit-frame]": { addEventListener: noop, setAttribute: noop },
  };
  const dialog = {
    open: false,
    showModal() { this.open = true; },
    close() { this.open = false; },
    addEventListener(t, fn) { dlgListeners[t] = fn; },
    querySelector: (s) => parts[s] || null,
    querySelectorAll: (s) => Object.values(buttons).filter((b) => s.split(",").includes("[" + b.attr + "]")),
  };
  const el = {
    dataset: { uploadName: "photos" },
    addEventListener(t, fn) { (listeners[t] = listeners[t] || []).push(fn); },
    removeEventListener: noop,
    contains: (x) => x === input,
    querySelector: (s) => (s === 'input[type="file"]' ? input : s === "[data-pk-edit-dialog]" ? dialog : null),
  };
  const uploads = [];
  const hook = Object.assign(Object.create(Hook), { el, upload: (name, files) => uploads.push([name, files]) });
  hook.mounted();
  const pick = (...files) => {
    input.files = files;
    (listeners.input || []).forEach((fn) => fn({ target: input, stopPropagation: noop }));
  };
  const press = (b) => { if (!b.disabled) dlgListeners.click({ target: { closest: () => b }, preventDefault: noop }); };
  // Clicking a disabled button does nothing in a browser; the hook must also
  // refuse it when a click gets through (a stale event, a script).
  const forcePress = (b) => dlgListeners.click({ target: { closest: () => b }, preventDefault: noop });
  return { hook, input, uploads, pick, press, forcePress, buttons, dialog, message };
}

test("the next photo cannot be confirmed before its preview has loaded", () => {
  images.length = 0;
  const e = fakeEditor();
  const a = { name: "a.jpg", type: "image/jpeg" };
  const b = { name: "b.jpg", type: "image/jpeg" };
  e.pick(a, b);
  assert.equal(e.buttons.apply.disabled, true, "nothing to confirm while a decodes");
  images[0].onload();
  assert.equal(e.dialog.open, true);
  assert.equal(e.buttons.apply.disabled, false);
  e.press(e.buttons.rotR);
  e.press(e.buttons.apply);
  // b is decoding; the dialog still shows a.
  assert.equal(images.length, 2);
  assert.equal(e.buttons.apply.disabled, true);
  assert.equal(e.buttons.original.disabled, true);
  assert.equal(e.buttons.rotR.disabled, true);
  assert.equal(e.buttons.skip.disabled, false, "Remove still works");
  e.forcePress(e.buttons.apply);
  e.forcePress(e.buttons.original);
  assert.deepEqual(e.uploads, [], "b is not accepted unseen");
  images[1].onload();
  assert.equal(e.hook._state.rotation, 0, "a's turn is not carried to b");
  e.press(e.buttons.apply);
  assert.equal(e.uploads.length, 1);
  const [edA, sentB] = e.uploads[0][1];
  assert.equal(edA.name, "a.jpg");
  assert.notEqual(edA, a, "a was edited");
  assert.equal(sentB, b, "b, unchanged, goes up as it was");
});

test("in the dialog, Flip then Rotate right stores the turn that looks clockwise", () => {
  images.length = 0;
  const e = fakeEditor();
  e.pick({ name: "a.jpg", type: "image/jpeg" });
  images[0].onload();
  e.press(e.buttons.flip);
  e.press(e.buttons.rotR);
  assert.equal(e.hook._state.rotation, u.turn(0, true, 90));
  assert.equal(e.hook._state.rotation, 270);
  e.press(e.buttons.skip);
});
