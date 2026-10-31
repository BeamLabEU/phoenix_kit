"use strict";

// The first moments of a media browser box select (#991 + the split).
//
// The box select is admin code. A press on the media browser's content column
// that happens before phoenix_kit_admin.js has run must not become a text
// selection; the public file keeps the press and refuses the selection, and the
// admin file takes the press over when it arrives. Both shipped files run in one
// fake page (support/pk_env.cjs).
//
//   node --test test/js/media_early_box.test.cjs

const test = require("node:test");
const assert = require("node:assert/strict");
const { createEnv, makeHook } = require("./support/pk_env.cjs");

const FACTS = { admin: { file: "admin-3.0.0-cafebabe.js", cdn: null } };
const tick = () => new Promise((r) => setTimeout(r, 0));
const plain = (v) => JSON.parse(JSON.stringify(v));

// A media browser with three cards in a column, a content area around them and
// the root element that carries the hook.
function page() {
  const env = createEnv({ facts: FACTS });
  env.window.PointerEvent = function PointerEvent(type, init) {
    Object.assign(this, init);
    this.type = type;
    this.preventDefault = () => { this.defaultPrevented = true; };
    this.stopPropagation = () => {};
  };
  env.load("phoenix_kit.js", { src: "https://app.test/assets/vendor/phoenix_kit.js" });
  const area = {
    scrollTop: 0,
    querySelectorAll: () => cards,
    getBoundingClientRect: () => ({ left: 0, top: 0, right: 300, bottom: 300 }),
  };
  const root = {
    id: "media", dataset: {}, contains: () => true, querySelector: () => null, querySelectorAll: () => [],
    addEventListener() {}, removeEventListener() {}, classList: { add() {}, remove() {}, contains: () => false },
  };
  const cards = ["a", "b", "c"].map((uuid, i) => ({
    dataset: { draggableFile: uuid },
    style: {},
    offsetParent: area,
    contains: () => false,
    closest: (sel) => (sel === "[data-box-area]" ? area : null),
    getBoundingClientRect: () => ({ left: 20, right: 80, top: 20 + i * 80, bottom: 70 + i * 80 }),
  }));
  const emptySpace = {
    closest: (sel) => (sel === "[data-box-area]" ? area : sel.includes("phx-hook") ? root : null),
  };
  const elsewhere = { closest: () => null };
  const hook = makeHook(env.window.PhoenixKitHooks.MediaDragDrop, root);
  const pushed = [];
  hook.pushEventTo = (_el, event, payload) => pushed.push({ event, payload: plain(payload) });
  const ev = (extra) => Object.assign({
    button: 0, pointerType: "mouse", pointerId: 1, clientX: 10, clientY: 10, shiftKey: false, metaKey: false, ctrlKey: false,
    preventDefault() { this.defaultPrevented = true; }, stopPropagation() {},
  }, extra);
  return {
    env, area, root, cards, hook, pushed, emptySpace, elsewhere,
    press: (target, extra) => { const e = ev(Object.assign({ type: "pointerdown", target }, extra)); env.fireDocument("pointerdown", e); return e; },
    onWindow: (type, extra) => env.window.dispatchEvent(ev(Object.assign({ type }, extra))),
    select: () => { const e = ev({ type: "selectstart" }); env.fireDocument("selectstart", e); return e; },
    arrive: async () => { env.load("phoenix_kit_admin.js"); if (env.scripts.length) env.loaded(0); await tick(); },
  };
}

test("on a page without a media browser the public file does nothing", () => {
  const p = page();
  const e = p.press(p.elsewhere);
  assert.equal(e.defaultPrevented, undefined);
  assert.equal(p.env.window.__pkEarlyPress, undefined);
  assert.equal(p.env.listenerCount("document", "selectstart"), 0);
  assert.equal(p.env.listenerCount("window", "pointerup"), 0);
  assert.equal(p.select().defaultPrevented, undefined);
});

test("a touch press and a right button are left alone", () => {
  const p = page();
  p.press(p.emptySpace, { pointerType: "touch" });
  p.press(p.emptySpace, { button: 2 });
  assert.equal(p.env.window.__pkEarlyPress, undefined);
});

test("a press on the content column refuses the text selection until it is released", () => {
  const p = page();
  p.press(p.emptySpace);
  assert.ok(p.env.window.__pkEarlyPress, "kept for the admin file");
  assert.equal(p.select().defaultPrevented, true, "the page cannot start selecting text");
  p.onWindow("pointerup", { clientX: 90, clientY: 90 });
  assert.equal(p.select().defaultPrevented, undefined, "selection is the browser's again");
  assert.equal(p.env.listenerCount("document", "selectstart"), 0);
  assert.equal(p.env.listenerCount("window", "pointerup"), 0);
  assert.equal(p.env.listenerCount("window", "pointercancel"), 0);
});

test("another pointer cannot release the press", () => {
  const p = page();
  p.press(p.emptySpace);
  p.onWindow("pointerup", { pointerId: 2 });
  assert.equal(p.select().defaultPrevented, true);
  assert.equal(p.env.window.__pkEarlyPress.end, null);
});

test("Shift + press on a card does not extend the text selection", () => {
  const p = page();
  const card = { closest: (sel) => (sel === "[data-box-area]" ? p.area : sel.includes("data-draggable") ? card : null) };
  const e = p.press(card, { shiftKey: true });
  assert.equal(e.defaultPrevented, true);
  assert.equal(p.env.window.__pkEarlyPress, undefined, "nothing to hand over: a Shift-click needs the hook");
});

test("a box released before the admin bundle arrives is applied once the hook is mounted", async () => {
  const p = page();
  p.hook.mounted(); // the stub asks for the bundle
  assert.equal(p.env.scripts.length, 1);
  p.press(p.emptySpace);
  p.onWindow("pointerup", { clientX: 90, clientY: 90 });
  assert.deepEqual(p.pushed, [], "nothing is sent from the public file");

  await p.arrive();

  assert.deepEqual(p.pushed, [{ event: "box_select", payload: { files: ["a"], folders: [], additive: false } }]);
  assert.equal(p.env.window.__pkPendingBox, null);
  assert.equal(p.env.window.__pkEarlyPress, null);
  assert.deepEqual(plain(p.env.errors), []);
});

test("a box released before the bundle and before the hook waits for the hook", async () => {
  const p = page();
  p.press(p.emptySpace, { shiftKey: true });
  p.onWindow("pointerup", { clientX: 90, clientY: 90 });
  p.env.load("phoenix_kit_admin.js"); // some other stub's request brought it
  const pending = p.env.window.__pkPendingBox;
  assert.ok(pending, "kept for the hook");
  assert.deepEqual(plain(pending.payload), { files: ["a"], folders: [], additive: true });
  assert.equal(pending.root, "media");
});

test("a box still held when the bundle arrives carries on from the next move", async () => {
  const p = page();
  p.hook.mounted();
  p.press(p.emptySpace);
  p.onWindow("pointermove", { clientX: 50, clientY: 50 }); // nobody listens yet
  await p.arrive();
  assert.deepEqual(p.pushed, [], "not finished yet");
  assert.equal(p.env.listenerCount("window", "pointerup"), 1, "the admin file listens now; the public file's is gone");

  p.onWindow("pointermove", { clientX: 90, clientY: 90 });
  p.onWindow("pointerup", { clientX: 90, clientY: 90 });
  assert.deepEqual(p.pushed, [{ event: "box_select", payload: { files: ["a"], folders: [], additive: false } }]);
  assert.equal(p.env.listenerCount("window", "pointerup"), 0);
  assert.equal(p.select().defaultPrevented, undefined, "text selection is back");
});

test("a click, a cancelled press and a press that is not on a media browser select nothing", async () => {
  for (const act of [
    (p) => { p.press(p.emptySpace); p.onWindow("pointerup", { clientX: 12, clientY: 12 }); },
    (p) => { p.press(p.emptySpace); p.onWindow("pointercancel"); },
    (p) => { p.press({ closest: (sel) => (sel === "[data-box-area]" ? p.area : null) }); p.onWindow("pointerup", { clientX: 90, clientY: 90 }); },
  ]) {
    const p = page();
    act(p);
    await p.arrive();
    assert.equal(p.env.window.__pkPendingBox, undefined);
    assert.deepEqual(p.pushed, []);
    assert.equal(p.env.listenerCount("window", "pointermove"), 0);
    assert.equal(p.env.listenerCount("document", "selectstart"), 0);
  }
});

test("once the admin file has run the public listener stays out of the way and nothing is doubled", async () => {
  const p = page();
  await p.arrive();
  const downs = p.env.listenerCount("document", "pointerdown");
  const e = p.press(p.emptySpace);
  assert.equal(p.env.window.__pkEarlyPress, null, "no press is kept: the admin file's own listener has it");
  assert.equal(p.env.listenerCount("document", "selectstart"), 0);
  p.onWindow("pointerup");
  p.env.load("phoenix_kit_admin.js"); // a second execution is ignored
  assert.equal(p.env.listenerCount("document", "pointerdown"), downs);
});

test("a box held still while the bundle arrives is applied when it is released", async () => {
  const p = page();
  p.hook.mounted();
  p.press(p.emptySpace);
  p.onWindow("pointermove", { clientX: 90, clientY: 90 });
  await p.arrive(); // the last move the catcher saw is replayed: the box is there at once
  p.onWindow("pointerup", { clientX: 90, clientY: 90 });
  assert.deepEqual(p.pushed, [{ event: "box_select", payload: { files: ["a"], folders: [], additive: false } }]);
});

test("a press on a card or a button is not replayed as a box", async () => {
  const p = page();
  const seen = [];
  p.env.window.addEventListener("pointermove", (ev) => seen.push(ev.type));
  const onCard = {
    closest: (sel) => (sel === "[data-box-area]" ? p.area : sel.includes("phx-hook") ? p.root
      : sel.startsWith("[data-draggable-file]") ? p.cards[0] : null),
  };
  p.press(onCard);
  p.onWindow("pointerup", { clientX: 90, clientY: 90 });
  seen.length = 0;
  await p.arrive();
  assert.deepEqual(seen, [], "no synthetic event reaches the host's window listeners");
  assert.equal(p.env.window.__pkPendingBox, undefined);
});

test("a press older than a few seconds, or on a page that has gone, is dropped", async () => {
  const stale = page();
  stale.press(stale.emptySpace);
  stale.onWindow("pointerup", { clientX: 90, clientY: 90 });
  stale.env.advance(11000);
  await stale.arrive();
  assert.equal(stale.env.window.__pkPendingBox, undefined);

  const gone = page();
  gone.root.isConnected = false;
  gone.press(gone.emptySpace);
  gone.onWindow("pointerup", { clientX: 90, clientY: 90 });
  await gone.arrive();
  assert.equal(gone.env.window.__pkPendingBox, undefined);
});

test("a press the admin file cannot make sense of does not cost it its hooks", async () => {
  const p = page();
  p.env.window.__pkEarlyPress = { e: { target: null }, t: Date.now() };
  await p.arrive();
  assert.equal(p.env.window.PhoenixKitAdminLoaded, true);
  assert.ok(p.env.window.PhoenixKitAdminHooks.RowMenu, "the hooks after the takeover are defined");
  assert.deepEqual(plain(p.env.errors), []);
});

test("a press whose release never came ends with the next press of that pointer", () => {
  const p = page();
  p.press(p.emptySpace);
  assert.equal(p.env.listenerCount("document", "selectstart"), 1);
  p.press(p.elsewhere); // the next press, outside the media browser
  assert.equal(p.env.window.__pkEarlyPress, null);
  assert.equal(p.env.listenerCount("document", "selectstart"), 0);
  assert.equal(p.env.listenerCount("window", "pointerup"), 0);
  assert.equal(p.env.listenerCount("window", "pointermove"), 0);
  assert.equal(p.select().defaultPrevented, undefined, "selection is the browser's again");
});

test("a finished press stays for the admin file when another press follows elsewhere", async () => {
  const p = page();
  p.press(p.emptySpace);
  p.onWindow("pointerup", { clientX: 90, clientY: 90 });
  p.press(p.elsewhere);
  assert.ok(p.env.window.__pkEarlyPress, "the released box is still waiting");
  p.onWindow("pointerup");
  await p.arrive();
  assert.ok(p.env.window.__pkPendingBox);
});

test("a second press replaces the first one", () => {
  const p = page();
  p.press(p.emptySpace);
  const first = p.env.window.__pkEarlyPress;
  p.press(p.emptySpace, { clientX: 15 });
  assert.notEqual(p.env.window.__pkEarlyPress, first);
  assert.equal(p.env.listenerCount("window", "pointerup"), 1, "the first press let go of its listeners");
  assert.equal(p.env.listenerCount("document", "selectstart"), 1);
});
