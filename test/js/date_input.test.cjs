"use strict";

// Unit tests for the pure parts of PkDateInput in priv/static/assets/phoenix_kit.js:
// the site date-format parser and formatter behind <.date_input>. The hook's
// DOM behaviour (events, focus, showPicker) is checked live, not here.
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
  cookie: "",
};

const storage = { getItem: () => null, setItem: noop, removeItem: noop };

global.window = {
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

const { parseDateText, checkDateText, formatDateIso, dateOrder, popupPlacement } = require("../../priv/static/assets/phoenix_kit.js");

const FORMATS = ["Y-m-d", "m/d/Y", "d/m/Y", "d.m.Y", "d-m-Y", "F j, Y"];

test("formatter renders all six formats; F is the English month, day unpadded", () => {
  const want = {
    "Y-m-d": "2026-01-05",
    "m/d/Y": "01/05/2026",
    "d/m/Y": "05/01/2026",
    "d.m.Y": "05.01.2026",
    "d-m-Y": "05-01-2026",
    "F j, Y": "January 5, 2026",
  };
  for (const f of FORMATS) assert.equal(formatDateIso("2026-01-05", f), want[f], f);
  assert.equal(formatDateIso("2026-10-16", "F j, Y"), "October 16, 2026");
});

test("an unknown format falls back to Y-m-d like the server", () => {
  assert.equal(formatDateIso("2026-10-16", "d.m"), "2026-10-16");
  assert.equal(dateOrder("d.m"), "ymd");
});

test("formatter gives empty text for anything that is not ISO", () => {
  assert.equal(formatDateIso("", "d.m.Y"), "");
  assert.equal(formatDateIso(null, "d.m.Y"), "");
  assert.equal(formatDateIso("garbage", "d.m.Y"), "");
});

test("every format parses its own output back", () => {
  for (const f of FORMATS) {
    for (const iso of ["2026-01-05", "2026-10-16", "2024-02-29", "1999-12-31"]) {
      assert.equal(parseDateText(formatDateIso(iso, f), f), iso, `${f} ${iso}`);
    }
  }
});

test("field order follows the format", () => {
  assert.equal(parseDateText("16.10.2026", "d.m.Y"), "2026-10-16");
  assert.equal(parseDateText("10/16/2026", "m/d/Y"), "2026-10-16");
  assert.equal(parseDateText("16/10/2026", "d/m/Y"), "2026-10-16");
  assert.equal(parseDateText("2026-10-16", "Y-m-d"), "2026-10-16");
  // Ambiguous text reads in the site's order.
  assert.equal(parseDateText("03.04.2026", "d.m.Y"), "2026-04-03");
  assert.equal(parseDateText("03/04/2026", "m/d/Y"), "2026-03-04");
});

test("ISO is always accepted, whatever the format", () => {
  for (const f of FORMATS) assert.equal(parseDateText("2026-10-16", f), "2026-10-16", f);
});

test("any separator, 1-2 digit day and month", () => {
  assert.equal(parseDateText("1.2.2026", "d.m.Y"), "2026-02-01");
  assert.equal(parseDateText("1/2/2026", "d.m.Y"), "2026-02-01");
  assert.equal(parseDateText("1 2 2026", "d.m.Y"), "2026-02-01");
  assert.equal(parseDateText("1,2,2026", "d.m.Y"), "2026-02-01");
  assert.equal(parseDateText("  16-10-2026  ", "d.m.Y"), "2026-10-16");
});

const TODAY = "2026-10-16";

test("two-digit year takes the century nearest today (-50 .. +49 years)", () => {
  assert.equal(parseDateText("1.2.26", "d.m.Y", null, null, TODAY), "2026-02-01");
  assert.equal(parseDateText("02/01/26", "m/d/Y", null, null, TODAY), "2026-02-01");
  assert.equal(parseDateText("26-02-01", "Y-m-d", null, null, TODAY), "2026-02-01");
  assert.equal(parseDateText("12.05.85", "d.m.Y", null, null, TODAY), "1985-05-12");
  assert.equal(parseDateText("31.12.99", "d.m.Y", null, null, TODAY), "1999-12-31");
  assert.equal(parseDateText("01.01.30", "d.m.Y", null, null, TODAY), "2030-01-01");
  // 2026 + 49 = 2075 is the last future year, 2026 - 50 = 1976 the first past one.
  assert.equal(parseDateText("01.01.75", "d.m.Y", null, null, TODAY), "2075-01-01");
  assert.equal(parseDateText("01.01.76", "d.m.Y", null, null, TODAY), "1976-01-01");
  assert.equal(parseDateText("010175", "d.m.Y", null, null, TODAY), "2075-01-01");
  // The window moves with today.
  assert.equal(parseDateText("01.01.85", "d.m.Y", null, null, "2060-01-01"), "2085-01-01");
});

test("a three-digit or five-digit year is not a date", () => {
  assert.equal(parseDateText("1.2.202", "d.m.Y"), null);
  assert.equal(parseDateText("1.2.20266", "d.m.Y"), null);
});

test("digits only, in the format's order", () => {
  assert.equal(parseDateText("16102026", "d.m.Y"), "2026-10-16");
  assert.equal(parseDateText("161026", "d.m.Y"), "2026-10-16");
  assert.equal(parseDateText("10162026", "m/d/Y"), "2026-10-16");
  assert.equal(parseDateText("20261016", "Y-m-d"), "2026-10-16");
  assert.equal(parseDateText("261016", "Y-m-d"), "2026-10-16");
  assert.equal(parseDateText("1610202", "d.m.Y"), null);
  assert.equal(parseDateText("16102", "d.m.Y"), null);
});

test("F j, Y takes an English month name, full or three letters", () => {
  assert.equal(parseDateText("October 16, 2026", "F j, Y"), "2026-10-16");
  assert.equal(parseDateText("oct 16 2026", "F j, Y"), "2026-10-16");
  assert.equal(parseDateText("OCT 16, 26", "F j, Y"), "2026-10-16");
  assert.equal(parseDateText("10/16/2026", "F j, Y"), "2026-10-16");
  assert.equal(parseDateText("Octember 16, 2026", "F j, Y"), null);
  // Month names are only for that format.
  assert.equal(parseDateText("October 16, 2026", "d.m.Y"), null);
});

test("impossible dates are rejected", () => {
  assert.equal(parseDateText("31.02.2026", "d.m.Y"), null);
  assert.equal(parseDateText("29.02.2026", "d.m.Y"), null);
  assert.equal(parseDateText("29.02.2024", "d.m.Y"), "2024-02-29");
  assert.equal(parseDateText("00.10.2026", "d.m.Y"), null);
  assert.equal(parseDateText("16.13.2026", "d.m.Y"), null);
  assert.equal(parseDateText("32.01.2026", "d.m.Y"), null);
  assert.equal(parseDateText("31.04.2026", "d.m.Y"), null);
});

test("partial or junk text is rejected", () => {
  for (const t of ["", "  ", "16", "16.1", "16.10", "16.10.", "a.b.c", "16.10.2026.1", "16..", "1-2-3-4"]) {
    assert.equal(parseDateText(t, "d.m.Y"), null, JSON.stringify(t));
  }
  assert.equal(parseDateText(null, "d.m.Y"), null);
  assert.equal(parseDateText(undefined, "d.m.Y"), null);
});

test("min and max bound the result (inclusive, ISO strings)", () => {
  assert.equal(parseDateText("16.10.2026", "d.m.Y", "2026-10-16", "2026-10-16"), "2026-10-16");
  assert.equal(parseDateText("15.10.2026", "d.m.Y", "2026-10-16", null), null);
  assert.equal(parseDateText("17.10.2026", "d.m.Y", null, "2026-10-16"), null);
  assert.equal(parseDateText("17.10.2026", "d.m.Y", "", ""), "2026-10-17");
  assert.equal(parseDateText("17.10.2026", "d.m.Y", undefined, undefined), "2026-10-17");
});

test("the popup opens under the field, left-aligned with it", () => {
  const anchor = { top: 100, bottom: 132, left: 40 };
  assert.deepEqual(popupPlacement(anchor, { width: 280, height: 320 }, { width: 1200, height: 800 }), {
    top: 136,
    left: 40,
  });
});

test("it flips above when there is no room below and room above", () => {
  const anchor = { top: 600, bottom: 632, left: 40 };
  assert.deepEqual(popupPlacement(anchor, { width: 280, height: 320 }, { width: 1200, height: 800 }), {
    top: 600 - 4 - 320,
    left: 40,
  });
});

test("with no room either side it keeps as much on screen as fits", () => {
  const anchor = { top: 100, bottom: 132, left: 40 };
  assert.equal(popupPlacement(anchor, { width: 280, height: 320 }, { width: 1200, height: 300 }).top, 4);
  assert.equal(popupPlacement(anchor, { width: 280, height: 320 }, { width: 1200, height: 400 }).top, 76);
});

test("it is kept inside the viewport sideways", () => {
  const size = { width: 280, height: 320 };
  const view = { width: 400, height: 800 };
  assert.equal(popupPlacement({ top: 0, bottom: 30, left: 300 }, size, view).left, 400 - 280 - 4);
  assert.equal(popupPlacement({ top: 0, bottom: 30, left: -50 }, size, view).left, 4);
});

// ---------------------------------------------------------------------------
// The hook's state machine, on fake elements (no DOM here): what stays checked
// live is events, focus and the browser pickers.
// ---------------------------------------------------------------------------
const hookDef = window.PhoenixKitHooks.PkDateInput;

function fakeClassList() {
  const set = new Set();
  return {
    add: (c) => set.add(c),
    remove: (c) => set.delete(c),
    toggle: (c, on) => (on ? set.add(c) : set.delete(c)),
    contains: (c) => set.has(c),
  };
}

function makeHook({ iso = "", text, format = "d.m.Y", required = false, submitForm = false, extra = {} } = {}) {
  const attrs = {};
  const textEl = {
    value: text === undefined ? (iso ? formatDateIso(iso, format) : "") : text,
    defaultValue: "",
    required,
    classList: fakeClassList(),
    validity: "",
    setCustomValidity(m) { this.validity = m; },
    setAttribute(k, v) { attrs[k] = v; },
    removeAttribute(k) { delete attrs[k]; },
    hasAttribute(k) { return k in attrs || (extra.attrs && k in extra.attrs); },
    focus() { global.document.activeElement = textEl; },
  };
  textEl.defaultValue = extra.defaultText !== undefined ? extra.defaultText : textEl.value;
  const form = { hasAttribute: (k) => submitForm && k === "phx-submit", addEventListener() {}, removeEventListener() {} };
  const events = [];
  const valueEl = {
    value: iso,
    disabled: false,
    form,
    dispatchEvent(e) { events.push([e.type, this.value]); },
    showPicker() { this.picked = true; },
  };
  const clearBtn = { classList: fakeClassList() };
  const el = {
    dataset: { format, today: TODAY, expected: "Expected 16.10.2026", ...(extra.dataset || {}) },
    addEventListener() {},
    contains: () => false,
    isConnected: true,
    querySelector(sel) {
      return { "[data-date-text]": textEl, "[data-date-value]": valueEl, "[data-clear]": clearBtn }[sel] || null;
    },
  };
  const hook = Object.assign(Object.create(hookDef), { el });
  global.document.activeElement = null;
  hook.mounted();
  return { hook, textEl, valueEl, clearBtn, events, attrs };
}

const keydown = (key) => ({ key, isComposing: false, prevented: false, preventDefault() { this.prevented = true; } });

test("typed text is committed on blur: one input event, text normalised", () => {
  const h = makeHook({ iso: "2026-10-16" });
  h.hook.baseText = "16.10.2026";
  h.textEl.value = "1.2.26";
  h.hook.onTextBlur();
  assert.deepEqual(h.events, [["input", "2026-02-01"]]);
  assert.equal(h.textEl.value, "01.02.2026");
});

test("an unchanged text commits nothing on blur", () => {
  const h = makeHook({ iso: "2026-10-16" });
  h.hook.onTextBlur();
  assert.deepEqual(h.events, []);
});

test("rejected text: value unchanged, marked, and put back after a patch", () => {
  const h = makeHook({ iso: "2026-10-16" });
  h.textEl.value = "16.1";
  assert.equal(h.hook.commit(), false);
  assert.deepEqual(h.events, []);
  assert.equal(h.valueEl.value, "2026-10-16");
  assert.ok(h.textEl.classList.contains("input-error"));
  assert.equal(h.attrs["aria-invalid"], "true");
  assert.equal(h.textEl.validity, "Expected 16.10.2026");

  // A form patch rewrites the field from the server's unchanged date and
  // strips what the server did not render.
  h.textEl.value = "16.10.2026";
  h.textEl.classList.remove("input-error");
  delete h.attrs["aria-invalid"];
  h.textEl.setCustomValidity("");
  h.hook.updated();
  assert.equal(h.textEl.value, "16.1");
  assert.ok(h.textEl.classList.contains("input-error"));
  assert.equal(h.attrs["aria-invalid"], "true");
  assert.equal(h.textEl.validity, "Expected 16.10.2026");
});

test("a rejected mark survives a patch while the field is focused again", () => {
  const h = makeHook({ iso: "2026-10-16" });
  h.textEl.value = "16.1";
  h.hook.commit();
  global.document.activeElement = h.textEl;
  h.hook.updated();
  assert.equal(h.textEl.value, "16.1", "the user's text is not touched while focused");
  assert.ok(h.textEl.classList.contains("input-error"));
});

test("a server change of the date beats rejected text", () => {
  const h = makeHook({ iso: "2026-10-16" });
  h.textEl.value = "16.1";
  h.hook.commit();
  h.valueEl.value = "2026-11-01";
  h.textEl.value = "garbage from the patch";
  h.hook.updated();
  assert.equal(h.textEl.value, "01.11.2026");
  assert.ok(!h.textEl.classList.contains("input-error"));
  assert.equal(h.hook.rejected, null);
});

test("a server change while focused is synced on blur, not lost", () => {
  const h = makeHook({ iso: "2026-10-16" });
  global.document.activeElement = h.textEl;
  h.valueEl.value = "2026-10-20";
  h.hook.updated();
  assert.equal(h.textEl.value, "16.10.2026", "not touched while focused");
  h.hook.onTextBlur();
  assert.equal(h.textEl.value, "20.10.2026");
  assert.deepEqual(h.events, [], "the server's value is not sent back");
});

test("Enter after a server change while focused does not overwrite the server's date", () => {
  const h = makeHook({ iso: "2026-10-16" });
  global.document.activeElement = h.textEl;
  h.valueEl.value = "2026-10-20";
  h.hook.updated();
  assert.equal(h.hook.commit(), true);
  assert.equal(h.valueEl.value, "2026-10-20");
  assert.deepEqual(h.events, []);
});

test("text typed before connect: committed when the field is not focused", () => {
  const h = makeHook({ iso: "2026-10-16", text: "20.10.2026", extra: { defaultText: "16.10.2026" } });
  assert.deepEqual(h.events, [["input", "2026-10-20"]]);
});

test("text typed before connect is left to blur/Enter while the user is still typing", () => {
  const h = makeHook({ iso: "2026-10-16", text: "16.10.20", extra: { defaultText: "16.10.2026" } });
  // makeHook mounted unfocused and committed; redo it focused on the same field.
  const el = h.hook.el;
  const text = el.querySelector("[data-date-text]");
  const value = el.querySelector("[data-date-value]");
  value.value = "2026-10-16";
  h.events.length = 0;
  text.value = "16.10.20";
  global.document.activeElement = text;
  const hook2 = Object.assign(Object.create(hookDef), { el });
  hook2.mounted();
  assert.deepEqual(h.events, []);
  assert.equal(value.value, "2026-10-16");
  assert.equal(text.value, "16.10.20");
  assert.equal(hook2.baseText, "16.10.2026", "blur will commit what was typed");
});

test("opening the calendar commits pending text first", () => {
  const h = makeHook({ iso: "2026-10-16" });
  global.window.matchMedia = () => ({ matches: true });
  h.textEl.value = "20.10.2026";
  h.hook.open();
  global.window.matchMedia = () => ({ matches: false });
  assert.deepEqual(h.events, [["input", "2026-10-20"]]);
  assert.ok(h.valueEl.picked, "the phone path opens the native picker");
});

test("emptying a required field keeps the date and marks the field", () => {
  const h = makeHook({ iso: "2026-10-16", required: true });
  h.textEl.value = "";
  assert.equal(h.hook.commit(), false);
  assert.equal(h.valueEl.value, "2026-10-16");
  assert.deepEqual(h.events, []);
  assert.ok(h.textEl.classList.contains("input-error"));
});

test("emptying an optional field clears the value", () => {
  const h = makeHook({ iso: "2026-10-16" });
  h.textEl.value = "";
  assert.equal(h.hook.commit(), true);
  assert.deepEqual(h.events, [["input", ""]]);
});

test("Enter: prevented for invalid text and for a phx-change-only form, not for a valid phx-submit form", () => {
  let h = makeHook({ iso: "2026-10-16", submitForm: true });
  h.textEl.value = "16.1";
  let e = keydown("Enter");
  h.hook.onTextKeydown(e);
  assert.ok(e.prevented);

  h = makeHook({ iso: "2026-10-16", submitForm: true });
  h.textEl.value = "20.10.2026";
  e = keydown("Enter");
  h.hook.onTextKeydown(e);
  assert.ok(!e.prevented);
  assert.deepEqual(h.events, [["input", "2026-10-20"]], "committed before the submit");

  h = makeHook({ iso: "2026-10-16", submitForm: false });
  e = keydown("Enter");
  h.hook.onTextKeydown(e);
  assert.ok(e.prevented);
});

test("clearing forgets a refusal and leaves no mark", () => {
  const h = makeHook({ iso: "2026-10-16" });
  h.textEl.value = "16.1";
  h.hook.commit();
  h.hook.clear();
  assert.equal(h.hook.rejected, null);
  assert.ok(!h.textEl.classList.contains("input-error"));
  assert.deepEqual(h.events, [["input", ""]]);
});

test("the clear button follows the text", () => {
  const h = makeHook({ iso: "" });
  assert.ok(h.clearBtn.classList.contains("hidden"));
  h.textEl.value = "1";
  h.hook.toggleClear();
  assert.ok(!h.clearBtn.classList.contains("hidden"));
});

test("checkDateText tells a bad format from a date outside min/max", () => {
  assert.deepEqual(checkDateText("16.10.2026", "d.m.Y"), { iso: "2026-10-16" });
  assert.deepEqual(checkDateText("16.1", "d.m.Y"), { error: "format" });
  assert.deepEqual(checkDateText("31.02.2026", "d.m.Y"), { error: "format" });
  assert.deepEqual(checkDateText("", "d.m.Y"), { error: "format" });
  assert.deepEqual(checkDateText("15.10.2026", "d.m.Y", "2026-10-16", null), { error: "range" });
  assert.deepEqual(checkDateText("17.10.2026", "d.m.Y", null, "2026-10-16"), { error: "range" });
});

test("a date outside min/max is refused with the range message, bad text with the format hint", () => {
  const dataset = { min: "2026-10-01", max: "2026-10-31", rangeMessage: "Pick a date between 01.10.2026 and 31.10.2026" };
  let h = makeHook({ iso: "2026-10-16", extra: { dataset } });
  h.textEl.value = "05.11.2026";
  assert.equal(h.hook.commit(), false);
  assert.equal(h.textEl.validity, "Pick a date between 01.10.2026 and 31.10.2026");
  assert.equal(h.attrs.title, "Pick a date between 01.10.2026 and 31.10.2026");

  h = makeHook({ iso: "2026-10-16", extra: { dataset } });
  h.textEl.value = "5.11";
  assert.equal(h.hook.commit(), false);
  assert.equal(h.textEl.validity, "Expected 16.10.2026");
});

test("no showPicker: the calendar opens; with no calendar either, the text keeps the focus", () => {
  const h = makeHook({ iso: "2026-10-16" });
  delete h.valueEl.showPicker;
  let popups = 0;
  h.hook.popupEl = () => ({ showPopover() {} });
  h.hook.openPopup = (nativeOnFail) => { popups += 1; assert.equal(nativeOnFail, false); };
  h.hook.open();
  assert.equal(popups, 1);

  const g = makeHook({ iso: "2026-10-16" });
  delete g.valueEl.showPicker;
  g.hook.popupEl = () => null;
  g.hook.open();
  assert.equal(global.document.activeElement, g.textEl);
});

test("a showPicker that throws falls back to the calendar, or the text field", () => {
  const h = makeHook({ iso: "2026-10-16" });
  h.valueEl.showPicker = () => { throw new Error("NotAllowedError"); };
  global.window.matchMedia = () => ({ matches: true });
  let popups = 0;
  h.hook.popupEl = () => ({ showPopover() {} });
  h.hook.openPopup = () => { popups += 1; };
  h.hook.open();
  assert.equal(popups, 1);

  const g = makeHook({ iso: "2026-10-16" });
  g.valueEl.showPicker = () => { throw new Error("x"); };
  g.hook.popupEl = () => null;
  g.hook.open();
  global.window.matchMedia = () => ({ matches: false });
  assert.equal(global.document.activeElement, g.textEl);
});
