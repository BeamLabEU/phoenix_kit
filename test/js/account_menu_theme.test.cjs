const {test} = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

test("System survives a menu patch and a reload with a legacy theme preference", () => {
  const fixture = fs.readFileSync(path.join(__dirname, "../fixtures/admin_layout_without_widgets.html"), "utf8");
  const scripts = Array.from(fixture.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/g), match => match[1]);
  const values = new Map([["phoenix_kit_theme", "phoenix-dark"]]);
  const localStorage = {
    getItem: key => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
    removeItem: key => values.delete(key),
  };

  function load() {
    const attrs = new Map();
    const listeners = new Map();
    const document = {
      documentElement: {style: {}, setAttribute: (key, value) => attrs.set(key, value)},
      querySelectorAll: () => [],
      addEventListener() {},
    };
    const window = {addEventListener: (name, handler) => listeners.set(name, handler)};
    for (const script of scripts.filter(script => script.includes("phoenix_kit_theme"))) {
      vm.runInNewContext(script, {document, window, localStorage});
    }
    return {attrs, listeners};
  }

  const {attrs, listeners} = load();
  assert.equal(attrs.get("data-theme-choice"), "phoenix-dark");
  listeners.get("phx:set-theme")({detail: {theme: "system"}});
  listeners.get("phoenix_kit:theme-sync")();
  assert.equal(attrs.get("data-theme-choice"), "system");
  assert.equal(load().attrs.get("data-theme-choice"), "system");
});
