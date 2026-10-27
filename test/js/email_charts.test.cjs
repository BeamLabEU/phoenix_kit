"use strict";

// EmailCharts draws the email dashboard's two charts with Chart.js. Chart.js
// is no longer pasted into phoenix_kit.js (every page of every host paid for
// it, one hook used it): it is a vendored library the hook loads when it
// mounts, and a host that wants a chart of its own asks for it through
// `PhoenixKitLibraries.chartjs()`.
//
//   node --test test/js/email_charts.test.cjs

const test = require("node:test");
const assert = require("node:assert/strict");
const { createEnv, makeHook } = require("./support/pk_env.cjs");

const FACTS = { chartjs: { file: "chartjs-4.5.1-deadbeef.js", cdn: null } };
const CHART_URL = "https://app.test/assets/vendor/lib/chartjs-4.5.1-deadbeef.js?vsn=d";

// The bundle(s) that carry the hook: today the whole file, after the split the
// admin bundle. Both are loaded when they exist, so the test follows the code.
function page() {
  const env = createEnv({ facts: FACTS });
  env.load("phoenix_kit.js", { src: "https://app.test/assets/vendor/phoenix_kit.js" });
  const adminHooks = () => env.window.PhoenixKitAdminHooks || {};
  const fs = require("fs");
  const path = require("path");
  const adminFile = path.join(__dirname, "..", "..", "priv", "static", "assets", "phoenix_kit_admin.js");
  if (fs.existsSync(adminFile)) env.load("phoenix_kit_admin.js");

  for (const id of ["delivery-chart-container", "engagement-chart-container"]) {
    const el = env.makeEl("div");
    el.attrs["data-chart-data"] = JSON.stringify({ labels: ["a"], datasets: [] });
    env.els[id] = el;
  }
  env.els["delivery-trend-chart"] = env.makeEl("canvas");
  env.els["engagement-chart"] = env.makeEl("canvas");

  const constructed = [];
  function FakeChart(canvas, config) {
    this.canvas = canvas;
    this.config = config;
    this.destroyed = false;
    constructed.push(this);
  }
  FakeChart.prototype.destroy = function () { this.destroyed = true; };
  FakeChart.prototype.update = function () {};

  const def = (adminHooks().EmailCharts) || env.window.PhoenixKitHooks.EmailCharts;
  return { env, def, constructed, FakeChart };
}

const tick = () => new Promise((r) => setTimeout(r, 0));

test("the public bundle no longer carries Chart.js", () => {
  const { env } = page();
  assert.equal(typeof env.window.Chart, "undefined", "nothing defines window.Chart at load");
});

test("mounting fetches the vendored Chart.js first, and draws only once it has arrived", async () => {
  const { env, def, constructed, FakeChart } = page();
  const hook = makeHook(def);
  hook.mounted();

  assert.equal(env.scripts.length, 1);
  assert.equal(env.scripts[0].src, CHART_URL);
  assert.equal(constructed.length, 0, "no chart before the library is there");

  env.window.Chart = FakeChart;
  env.loaded(0);
  await tick();

  assert.equal(constructed.length, 2, "delivery and engagement");
  assert.deepEqual(constructed.map((c) => c.config.type), ["line", "doughnut"]);
});

test("a page that already has Chart.js fetches nothing", async () => {
  const { env, def, constructed, FakeChart } = page();
  env.window.Chart = FakeChart;
  makeHook(def).mounted();
  await tick();

  assert.equal(env.scripts.length, 0);
  assert.equal(constructed.length, 2);
});

test("server pushes that arrive while the library loads are not lost", async () => {
  const { env, def, constructed, FakeChart } = page();
  const hook = makeHook(def);
  hook.mounted();
  assert.equal(typeof hook.handlers["email-charts-update"], "function", "registered at mount, not after the load");

  // Nothing drawn yet: an early update is a no-op, not an error.
  hook.handlers["email-charts-update"]({ charts: { delivery_trend: { labels: [] } } });

  env.window.Chart = FakeChart;
  env.loaded(0);
  await tick();
  assert.equal(constructed.length, 2);
});

test("a hook destroyed while the library loads never draws", async () => {
  const { env, def, constructed, FakeChart } = page();
  const hook = makeHook(def);
  hook.mounted();
  hook.destroyed();
  env.window.Chart = FakeChart;
  env.loaded(0);
  await tick();

  assert.equal(constructed.length, 0);
});

test("when the library cannot be loaded the dashboard says so instead of throwing", async () => {
  const { env, def } = page();
  const hook = makeHook(def);
  hook.mounted();
  env.failed(0); // local copy fails; no CDN configured
  await tick();

  const container = env.els["delivery-chart-container"];
  assert.ok(container.children.length > 0, "the container holds the notice");
  assert.ok(env.errors.some((m) => m.includes("Chart.js") && m.includes(CHART_URL)), "and the console names the file");
});

test("PhoenixKitLibraries.chartjs() resolves to window.Chart for a host's own pages", async () => {
  const { env, FakeChart } = page();
  const p = env.window.PhoenixKitLibraries.chartjs();
  assert.equal(env.scripts[0].src, CHART_URL);
  env.window.Chart = FakeChart;
  env.loaded(0);
  assert.equal(await p, FakeChart);

  // Asking again costs nothing.
  assert.equal(await env.window.PhoenixKitLibraries.chartjs(), FakeChart);
  assert.equal(env.scripts.length, 1);
});
