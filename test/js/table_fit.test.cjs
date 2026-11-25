"use strict";

// Unit tests for the pure helpers behind the TableFit
// hook in priv/static/assets/phoenix_kit_admin.js. Same global stubbing as
// push_to_owner.test.cjs — the bundle is browser code.
//
// Run: mix test.js

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

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
global.window = {
  addEventListener: noop,
  removeEventListener: noop,
  matchMedia: () => ({ matches: false, addEventListener: noop, addListener: noop }),
  location: { href: "http://localhost/", origin: "http://localhost" },
  localStorage: { getItem: () => null, setItem: noop, removeItem: noop },
  document: global.document,
};
// Node >= 21 defines a global `navigator` as a getter-only accessor
// property, so a plain assignment throws; redefine it instead.
Object.defineProperty(global, "navigator", {
  value: { userAgent: "node" },
  configurable: true,
  writable: true,
});
global.localStorage = global.window.localStorage;
global.MutationObserver = class { observe() {} disconnect() {} };
global.IntersectionObserver = class { observe() {} disconnect() {} };


const {
  fitEvictionOrder,
  fitHideCss,
  fitColumns,
  fitEscapeId,
  fitSignature,
} = (require("../../priv/static/assets/phoenix_kit.js"), require("../../priv/static/assets/phoenix_kit_admin.js"));

const col = (index, priority, head = index) => ({ index, head, priority });
const order = (cols) => fitEvictionOrder(cols).map((c) => c.index);

test("the highest priority number goes first, 1 last", () => {
  const cols = [col(1, NaN), col(2, NaN), col(3, 1), col(4, 3), col(5, 2), col(6, NaN)];
  assert.deepEqual(order(cols), [4, 5, 3]);
});

test("a column with no priority is never dropped", () => {
  assert.deepEqual(order([col(1, NaN), col(2, NaN)]), []);
});

test("equal priorities go from the right", () => {
  assert.deepEqual(order([col(2, 2), col(3, 2), col(4, 2)]), [4, 3, 2]);
});

test("the order does not mutate its input", () => {
  const cols = [col(1, 1), col(2, 5)];
  fitEvictionOrder(cols);
  assert.deepEqual(cols.map((c) => c.index), [1, 2]);
});

test("nothing hidden is an empty stylesheet", () => {
  assert.equal(fitHideCss("t-fit", [], 5), "");
});

test("hides whole columns by position, on screen only, sparing colspan cells", () => {
  const css = fitHideCss("t-fit", [col(4, 2), col(2, 3)], 5);
  assert.match(css, /^@media screen \{/);
  assert.ok(css.includes("#t-fit > table > :not(thead) > tr > :nth-child(4):not([colspan])"));
  assert.ok(css.includes("#t-fit > table > :not(thead) > tr > :nth-child(2):not([colspan])"));
  assert.ok(css.includes("display: none"));
});

test("says how many columns are dropped, on the last header cell", () => {
  const css = fitHideCss("t-fit", [col(4, 2), col(2, 3)], 5);
  assert.ok(css.includes('#t-fit > table > thead > tr > :nth-child(5)::before { content: "+2"'));
});

test("after a spanning header, the header cell and its body cells sit at different positions", () => {
  // [A][B colspan=2][C priority 2][D]: C is the 3rd header cell and the 4th
  // body cell. Hiding nth-child(4) in the header would take D instead.
  const cols = fitColumns([
    { colSpan: 1, priority: undefined },
    { colSpan: 2, priority: "5" },
    { colSpan: 1, priority: "2" },
    { colSpan: 1, priority: undefined },
  ]);
  assert.deepEqual(cols.map((c) => [c.index, c.head]), [[1, 1], [2, 2], [4, 3], [5, 4]]);
  assert.ok(Number.isNaN(cols[1].priority)); // the spanning header never goes

  const dropped = fitEvictionOrder(cols);
  assert.deepEqual(dropped.map((c) => c.index), [4]);

  const css = fitHideCss("t-fit", dropped, 4);
  assert.ok(css.includes("> thead > tr > :nth-child(3)"));
  assert.ok(!css.includes("> thead > tr > :nth-child(4),"));
  assert.ok(css.includes("> :not(thead) > tr > :nth-child(4):not([colspan])"));
});

test("an id that is not a CSS identifier is escaped in the selector", () => {
  assert.equal(fitEscapeId("users-table-fit"), "users-table-fit");
  assert.notEqual(fitEscapeId("01a0-fit"), "01a0-fit");
  assert.ok(!fitHideCss("a.b:c-fit", [col(2, 1)], 3).includes("#a.b:c-fit"));
  assert.ok(fitHideCss("a.b:c-fit", [col(2, 1)], 3).includes("#a\\.b\\:c-fit"));
});

test("the signature changes when a column is added, removed or re-prioritised", () => {
  const base = [{ colSpan: 1 }, { colSpan: 1, priority: "2" }, { colSpan: 1, priority: "1" }];
  const sig = fitSignature(base);
  assert.equal(sig, fitSignature(base.map((h) => ({ ...h }))));
  assert.notEqual(sig, fitSignature(base.slice(0, 2)));
  assert.notEqual(sig, fitSignature([{ colSpan: 1 }, ...base]));
  assert.notEqual(sig, fitSignature([base[0], base[2], base[1]]));
});

test("the dropped-column count stays visible when the last headers are dropped", () => {
  const css = fitHideCss("t-fit", [col(4, 2), col(3, 1)], 4);
  assert.ok(css.includes('> thead > tr > :nth-child(2)::before { content: "+2"'));
  assert.ok(!css.includes(':last-child::before'));
});

test("there is no badge target if every header is dropped", () => {
  const css = fitHideCss("t-fit", [col(1, 1)], 1);
  assert.ok(!css.includes("::before"));
});

// The first paint cannot call fitHideCss: its script runs as the table is
// parsed, before phoenix_kit_admin.js. It is a second copy of that grammar.
// Running the copy is what keeps the two from drifting, and what proves a
// stylesheet string remembered in localStorage is never inserted.
function firstPaintScript() {
  const src = fs.readFileSync(
    path.join(__dirname, "../../lib/phoenix_kit_web/components/core/table_default.ex"),
    "utf8"
  );
  const from = src.indexOf("defp fit_restore");
  const slice = src.slice(from);
  const open = slice.indexOf("<script");
  const bodyAt = slice.indexOf(">", open) + 1;
  const bodyEnd = slice.indexOf("</script>", bodyAt);
  assert.ok(from !== -1 && open !== -1 && bodyEnd !== -1, "fit_restore script is in table_default.ex");
  return slice.slice(bodyAt, bodyEnd);
}

function runFirstPaint({ id, headers, saved, styleNonce, scriptNonce }) {
  const styles = [];
  const document = {
    currentScript: {
      previousElementSibling: {
        id,
        querySelector(sel) {
          assert.equal(sel, ":scope > table > thead > tr");
          return {
            children: headers.map((h) => ({
              colSpan: h.colSpan || 1,
              dataset: h.priority === undefined ? {} : { colPriority: h.priority },
            })),
          };
        },
      },
      nonce: scriptNonce || "",
    },
    head: { appendChild(el) { styles.push(el); return el; } },
    getElementsByTagName(tag) {
      return tag === "style" && styleNonce ? [{ nonce: styleNonce }] : [];
    },
    createElement(tag) {
      assert.equal(tag, "style");
      return {
        nonce: "",
        textContent: "",
        setAttribute(name, value) { this[name] = value; },
      };
    },
  };
  const context = vm.createContext({
    document,
    localStorage: {
      getItem(key) {
        assert.equal(key, "phoenix_kit:table-fit:" + id);
        return saved == null ? null : JSON.stringify(saved);
      },
    },
    window: {},
  });
  vm.runInContext(firstPaintScript(), context);
  return styles;
}

test("the first-paint script rebuilds fitHideCss and stamps the style nonce", () => {
  const id = "a.b:c-fit";
  const headers = [{ colSpan: 2 }, { colSpan: 1, priority: "1" }, { colSpan: 1, priority: "2" }];
  const cols = [{ index: 3, head: 2 }];
  const styles = runFirstPaint({
    id,
    headers,
    styleNonce: "style-only",
    scriptNonce: "script-only",
    saved: {
      sig: fitSignature(headers),
      cols,
      headerCount: headers.length,
      css: "body{background:url(https://evil.example/x)}",
    },
  });
  assert.equal(styles.length, 1);
  assert.equal(styles[0].textContent, fitHideCss(id, cols, headers.length));
  assert.equal(styles[0].nonce, "style-only");
  assert.equal(styles[0]["data-pk-table-fit"], id);
  assert.ok(!styles[0].textContent.includes("evil"));
});

test("the first-paint script uses the loading script's nonce when no style has one", () => {
  const headers = [{ colSpan: 1, priority: "1" }, { colSpan: 1 }];
  const cols = [{ index: 1, head: 1 }];
  const styles = runFirstPaint({
    id: "people-fit",
    headers,
    scriptNonce: "shared",
    saved: { sig: fitSignature(headers), cols, headerCount: headers.length },
  });
  assert.equal(styles.length, 1);
  assert.equal(styles[0].nonce, "shared");
  assert.equal(styles[0].textContent, fitHideCss("people-fit", cols, headers.length));
});

test("the first-paint script inserts nothing it did not rebuild from column numbers", () => {
  const headers = [{ colSpan: 1, priority: "1" }, { colSpan: 1, priority: "2" }];
  const sig = fitSignature(headers);
  const id = "people-fit";
  const rejected = [
    null,
    { sig, css: "body{color:red}" },
    { sig, cols: [{ index: "2);color:red", head: 2 }], headerCount: 2 },
    { sig, cols: [{ index: 2, head: 2 }], headerCount: 2.5 },
    { sig: "other", cols: [{ index: 2, head: 2 }], headerCount: 2 },
    { sig, cols: [], headerCount: 2 },
  ];
  for (const saved of rejected) {
    assert.deepEqual(runFirstPaint({ id, headers, saved, scriptNonce: "shared" }), []);
  }
});
