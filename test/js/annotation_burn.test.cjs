// The burn hook must not ask the server to overwrite the editor's ladder.
//
// The viewer opens on `small` and climbs `medium` → `large` → `original`,
// then draws the live shapes on top. Burning those slots draws every
// annotation a second time the next time the picture is opened. List rows
// read `thumbnail`; grid cards read `burned` (card-sized); the viewer opens
// on `burned_large`.
//
//   node --test test/js/annotation_burn.test.cjs

const fs = require("fs");
const path = require("path");
const assert = require("node:assert");
const { test } = require("node:test");

const SOURCE = path.join(__dirname, "..", "..", "priv", "static", "assets", "phoenix_kit.js");
const src = fs.readFileSync(SOURCE, "utf8");

function burnSection() {
  const start = src.indexOf("// AnnotationBurn —");
  const end = src.indexOf("// EtcherTooltipActions");
  assert.ok(start !== -1 && end > start, "could not find the AnnotationBurn section");
  return src.slice(start, end);
}

const section = burnSection();

// Whole slot names, not substrings: `burned_large` is a burn slot, not the
// ladder's `large`.
function defaultSlots() {
  const m = section.match(/dataset\.burnVariants \|\| "([^"]*)"/);
  assert.ok(m, "could not find the default burnVariants");
  return m[1].split(",");
}

test("the default slots are the burn slots, not the viewer ladder", () => {
  assert.deepStrictEqual(defaultSlots(), ["thumbnail", "burned", "burned_large"]);
  for (const rung of ["small", "medium", "large", "original"]) {
    assert.ok(!defaultSlots().includes(rung), `the default must not burn \`${rung}\``);
  }
});

test("a stored burn is announced by slot, never by a client-built URL", () => {
  // The viewer reads the stored instance itself; the hook must not hand it a
  // URL or size to trust.
  const push = section.slice(section.indexOf('"burn_stored"'));
  const payload = push.slice(0, push.indexOf("});"));
  assert.match(payload, /variant: made\.variant/);
  assert.doesNotMatch(payload, /url:|width:|height:/);
});

test("the burn is composed from this picture, and names the original it used", () => {
  assert.match(section, /body\.append\("source_version", sourceVersion\)/);
  assert.doesNotMatch(section, /document\.querySelector\('\[phx-hook="FrescoCanvas"\]'\)/);
  assert.doesNotMatch(section, /document\.querySelector\("\[data-sources\]"\)/);
});

test("a session-end during an in-flight burn keeps the plan taken while the overlay is still there", () => {
  assert.match(section, /if \(this\._running\) \{\s*this\._pending = pending;/);
  assert.match(section, /var next = self\._pending;\s*self\._pending = null;\s*if \(next\) self\._start\(next\);/);
});

// Review of #848: closing the viewer called burnIfChanged whatever the viewer
// was allowed to do, so a readonly MediaBrowser (can_annotate: false) still
// composed and POSTed a burn on the way out.
test("a viewer that cannot draw never burns", () => {
  const start = section.indexOf("burnIfChanged() {");
  assert.ok(start !== -1, "could not find burnIfChanged");
  const body = section.slice(start, section.indexOf("var now = this._signature();", start));
  assert.match(body, /dataset\.canAnnotate !== "true"\) return;/);
});

function sliceFn(name) {
  const start = src.indexOf("function " + name + "(");
  assert.ok(start !== -1, "could not find " + name);
  let i = src.indexOf("{", start);
  let depth = 0;
  for (; i < src.length; i++) {
    if (src[i] === "{") depth++;
    else if (src[i] === "}") {
      depth--;
      if (depth === 0) return src.slice(start, i + 1);
    }
  }
  throw new Error("unclosed " + name);
}

const affine = new Function(
  sliceFn("burnViewAffine") + "\n" +
  sliceFn("burnSvgMatrix") + "\n" +
  "return { burnViewAffine, burnSvgMatrix };"
)();

test("a quarter turn still produces an affine, and the matrix carries the rotation", () => {
  // 90°: image +X points down the screen. The old X-only delta was 0 and
  // burnCapturePlan returned null, so a rotated picture never burned.
  const rect = { left: 10, top: 20 };
  const p0 = { x: 50, y: 80 };
  const ax = affine.burnViewAffine(p0, { x: 50, y: 1080 }, { x: -950, y: 80 }, rect);
  assert.ok(ax, "a 90° view must still burn");
  assert.ok(Math.abs(ax.s - 1) < 1e-9);
  assert.ok(Math.abs(ax.cos) < 1e-9);
  assert.ok(Math.abs(ax.sin - 1) < 1e-9);
  assert.deepStrictEqual(
    affine.burnSvgMatrix(ax, 1, 0, 0).map((n) => Math.round(n * 1e6) / 1e6),
    [0, -1, 1, 0, -60, 40]
  );
});

test("an unrotated view keeps the axis-aligned matrix", () => {
  const ax = affine.burnViewAffine(
    { x: 0, y: 0 }, { x: 1000, y: 0 }, { x: 0, y: 1000 }, { left: 0, top: 0 }
  );
  assert.deepStrictEqual(
    affine.burnSvgMatrix(ax, 2, 0, 0).map((n) => n === 0 ? 0 : n),
    [2, 0, 0, 2, 0, 0]
  );
});

test("stepping to the next file burns while the overlay is still mounted", () => {
  assert.match(section, /phx-click="step_viewer"/);
  assert.match(section, /e\.key === "ArrowLeft" \|\| e\.key === "ArrowRight"/);
  assert.match(section, /if \(closing \|\| stepping\) self\.burnIfChanged\(\)/);
});

// The canvas is the picture plus the ink the copy keeps. Measured by shape
// groups, a dimension's label group reached up to the overlay's origin (its
// 0×0 leader sits there), and burning in live mode returned a landscape photo
// as a portrait, squeezed under a blank band as tall as the viewer's margin.
// Chrome — handles, a shape still being drawn — is cut from the copy, so it
// must not stretch the canvas either.
const bounds = new Function(
  "BURN_CHROME",
  sliceFn("burnIsChrome") + "\n" +
  sliceFn("burnInkBounds") + "\n" +
  "return { burnIsChrome, burnInkBounds };"
)([".etcher-handle", ".is-draft"]);

// A stand-in element: `classes` is its own class list plus its ancestors'.
function fakeEl(box, classes, hasChildren) {
  return {
    firstElementChild: hasChildren ? {} : null,
    closest: (sel) => classes.includes(sel.slice(1)) ? {} : null,
    getBoundingClientRect: () => ({
      left: box[0], top: box[1], right: box[2], bottom: box[3],
      width: box[2] - box[0], height: box[3] - box[1]
    })
  };
}

const same = (x, y) => ({ x, y });

test("a label group reaching the overlay's origin through an empty leader does not stretch the canvas", () => {
  // Viewer 783×649 over a 783×427 picture: the overlay's origin is 111px above it.
  const toImage = (x, y) => ({ x, y: y - 111 });
  const labelGroup = fakeEl([0, 0, 522, 535], ["etcher-shape"], true);
  const emptyLeader = fakeEl([0, 0, 0, 0], ["etcher-shape"]);
  const labelText = fakeEl([400, 300, 460, 330], ["etcher-shape"]);
  assert.deepStrictEqual(
    bounds.burnInkBounds([labelGroup, emptyLeader, labelText], toImage, 783, 427),
    { minX: 0, minY: 0, maxX: 783, maxY: 427 }
  );
});

test("a shape still being drawn does not stretch the canvas", () => {
  const draftAbove = fakeEl([100, -1200, 300, -1100], ["etcher-shape", "is-draft"]);
  assert.deepStrictEqual(
    bounds.burnInkBounds([draftAbove], same, 1408, 768),
    { minX: 0, minY: 0, maxX: 1408, maxY: 768 }
  );
});

test("handles inside a shape do not stretch the canvas, and a group is measured by its leaves", () => {
  const group = fakeEl([-500, -500, 2000, 2000], ["etcher-shape"], true);
  const handle = fakeEl([1400, 760, 1500, 900], ["etcher-handle", "etcher-shape"]);
  const stroke = fakeEl([10, 10, 200, 20], ["etcher-shape"]);
  assert.deepStrictEqual(
    bounds.burnInkBounds([group, handle, stroke], same, 1408, 768),
    { minX: 0, minY: 0, maxX: 1408, maxY: 768 }
  );
});

test("ink drawn past the edge of the picture still widens the canvas", () => {
  const arrowInFromTheMargin = fakeEl([-80, 300, 40, 320], ["etcher-shape"]);
  const noteBelow = fakeEl([200, 760, 400, 840], ["etcher-shape"]);
  assert.deepStrictEqual(
    bounds.burnInkBounds([arrowInFromTheMargin, noteBelow], same, 1408, 768),
    { minX: -80, minY: 0, maxX: 1408, maxY: 840 }
  );
});

test("a straight line — one side 0, the other not — is ink and widens the canvas", () => {
  // Only a true point (0×0) is skipped: a vertical dimension line has no
  // width and a horizontal one no height, and both are drawn.
  const verticalLineAbove = fakeEl([300, -200, 300, -40], ["etcher-shape"]);
  const horizontalLineRight = fakeEl([1450, 500, 1600, 500], ["etcher-shape"]);
  assert.deepStrictEqual(
    bounds.burnInkBounds([verticalLineAbove, horizontalLineRight], same, 1408, 768),
    { minX: 0, minY: -200, maxX: 1600, maxY: 768 }
  );
});

test("burnCapturePlan sizes the canvas with burnInkBounds over shapes and their descendants", () => {
  const plan = sliceFn("burnCapturePlan");
  assert.match(plan, /burnInkBounds\(\s*svg\.querySelectorAll\("\.etcher-shape, \.etcher-shape \*"\)/);
  assert.doesNotMatch(plan, /svg\.querySelectorAll\("\.etcher-shape"\)\.forEach/);
});

// ── what counts as a change ───────────────────────────────────────────────
//
// Reported from the field: draw on a clean picture and it burns; come
// back, rub the shape out, leave, and nothing is burned at all — the copy
// on file keeps the markup and the card keeps showing it. An empty board
// signs as `""`, which is falsy, and the guard for "Etcher has not
// hydrated yet" tested truthiness — so the one edit that empties a board
// was read as the layer not being there, and the rule that decides what
// an empty board means could never be reached.

function lift(head, tail) {
  const start = src.indexOf(head);
  assert.ok(start !== -1, `could not find ${head}`);
  const end = src.indexOf(tail, start);
  assert.ok(end > start, `could not find the end of ${head}`);
  return src.slice(start, end + tail.length);
}

// The method under test, with the two module-scope helpers it reaches for:
// the real hash (so an empty board's fingerprint is the real one) and a
// stub plan, because there is no picture here to compose.
function burnHook(state) {
  const planned = { taken: 0 };
  // eslint-disable-next-line no-unused-vars
  const burnCapturePlan = () => { planned.taken += 1; return { stub: true }; };
  // eslint-disable-next-line no-unused-vars
  const burnHashSrc = lift("  function burnHash(str) {", "\n  }");
  eval(burnHashSrc);

  const body = lift("    burnIfChanged() {", "\n    },");
  // `burnIfChanged() { … },` → `function () { … }`
  const fn = eval("(function " + body.slice("    burnIfChanged".length, -1) + ")");

  const started = [];
  const hook = Object.assign({
    _uuid: "file-1",
    _burned: null,
    _running: false,
    _pending: null,
    // `canAnnotate` because a viewer that cannot draw never burns (//848);
    // these cases are all about a viewer that can.
    el: { dataset: { sourceVersion: "v1", canAnnotate: "true" } },
    _host() { return { stub: "canvas" }; },
    _signature() { return state.signature; },
    _start(pending) { started.push(pending); },
    burnIfChanged: fn
  }, state.hook || {});

  hook.burnIfChanged();
  return { started, planned };
}

test("rubbing out the last shape is a change, and burns a clean copy", () => {
  const { started } = burnHook({ signature: "", hook: { _burned: "a1b2c3" } });

  assert.strictEqual(started.length, 1,
    "an empty board with a burn on file must render the clean picture");
  assert.match(started[0].fingerprint, /^[0-9a-f]+$/,
    "and the empty board gets a real fingerprint of its own, so the next " +
    "visit knows the stored copy is already clean");
  assert.notStrictEqual(started[0].fingerprint, "a1b2c3");
});

test("a picture with no markup, opened and closed, burns nothing", () => {
  const { started, planned } = burnHook({ signature: "", hook: { _burned: null } });

  assert.strictEqual(started.length, 0);
  assert.strictEqual(planned.taken, 0, "and it does not even compose one");
});

test("a board that has not hydrated yet is not an empty board", () => {
  // `null` from `_signature` means the layer is not there to ask. Burning
  // on it would render a picture whose shapes have not loaded.
  assert.strictEqual(burnHook({ signature: null, hook: { _burned: "a1" } }).started.length, 0);
});

test("a drawing that matches the copy on file is left alone", () => {
  const sig = "[\"u1\",\"rect\"]";
  const { started } = burnHook({ signature: sig, hook: { _burned: null } });
  const fingerprint = started[0].fingerprint;

  assert.strictEqual(
    burnHook({ signature: sig, hook: { _burned: fingerprint } }).started.length, 0,
    "same drawing, same fingerprint, nothing to do");
  assert.strictEqual(
    burnHook({ signature: sig + "more", hook: { _burned: fingerprint } }).started.length, 1,
    "…and a drawing that differs by anything at all is burned");
});

// ── the eye ───────────────────────────────────────────────────────────────
//
// Hide the etchings and see the clean original. The burned picture IS the
// markup — baked into the bitmap — so the eye cannot be a client-side
// visibility flip there: it asks the server to swap the canvas instead.

test("the burned view carries an eye, offered to every viewer, not only to drawers", () => {
  // Gated on `burned` alone — no canAnnotate in sight: seeing the picture
  // under the markup is a viewing affordance, not an editing one.
  assert.match(section, /if \(burned\) \{\s*this\._eyeButton = handle\.appendNavButton\(/);
});

test("the eye asks the server to swap the picture, and reads its state from the assigns", () => {
  const start = section.indexOf("this._eyeButton = handle.appendNavButton(");
  assert.ok(start !== -1, "could not find the eye button");
  const call = section.slice(start, section.indexOf(");", start));

  assert.match(call, /hidden \? eyeSlash : eye/);
  assert.match(call, /hidden \? "Show annotations" : "Hide annotations"/);
  assert.match(call, /"toggle_etchings"/);

  // `hidden` comes from the server's assign, pushed back down — the state
  // lives in the LiveComponent for the length of the open and nowhere else.
  assert.match(section, /var hidden = this\.el\.dataset\.etchingsHidden === "true";/);
  assert.doesNotMatch(section, /localStorage|sessionStorage/,
    "the eye must never be persisted — every open starts with the markup showing");
});

test("the eye is cleaned up with the pencil when the rail is replaced, and on teardown", () => {
  assert.match(section, /if \(this\._eyeButton\) \{\s*try \{ this\._eyeButton\(\); \} catch \(_\) \{\}\s*this\._eyeButton = null;/);
  assert.match(section, /\[this\._modeButton, this\._pencilButton, this\._eyeButton\]\.forEach/);
});

test("the same drawing is not burned twice over one session end", () => {
  // Turning Etcher off ends the session once, but the canvas swap that
  // follows tears the layer down, and a teardown turns the mode off
  // again. That second end arrives before the upload has answered, while
  // `_burned` still names the old copy — and it composed and uploaded the
  // whole picture a second time.
  const sig = "[\"u1\",\"rect\"]";
  const first = burnHook({ signature: sig, hook: { _burned: null } });
  assert.strictEqual(first.started.length, 1);

  const again = burnHook({
    signature: sig,
    hook: { _burned: null, _running: true, _inFlight: first.started[0].fingerprint }
  });
  assert.strictEqual(again.started.length, 0, "the one on the wire counts as done");
  assert.strictEqual(again.planned.taken, 0, "and nothing is composed for it");

  // A drawing that changed WHILE a burn was uploading is still queued —
  // that is what the queue is for.
  const changed = burnHook({
    signature: sig + "more",
    hook: { _burned: null, _running: true, _inFlight: first.started[0].fingerprint,
            _start(p) { this.queued = p; } }
  });
  assert.strictEqual(changed.planned.taken, 1, "it takes the plan while the overlay is there");
});
