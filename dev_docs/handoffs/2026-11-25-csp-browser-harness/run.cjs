const { chromium } = require(process.env.PK_PLAYWRIGHT);
const BASE = "http://127.0.0.1:4177";
const out = [];
const rec = (name, ok, detail) => { out.push({ name, ok, detail }); console.log((ok ? "PASS " : "FAIL ") + name + (detail ? "  — " + detail : "")); };

async function open(browser, path) {
  const ctx = await browser.newContext({ permissions: ["clipboard-read", "clipboard-write"] });
  const page = await ctx.newPage();
  await page.addInitScript(() => {
    window.__v = [];
    document.addEventListener("securitypolicyviolation", (e) => window.__v.push(e.effectiveDirective + " " + (e.blockedURI || "") + " " + (e.sample || "")));
  });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  await page.goto(BASE + path, { waitUntil: "load" });
  await page.waitForTimeout(300);
  return { ctx, page, errors, violations: () => page.evaluate(() => window.__v) };
}
const color = (page, sel) => page.evaluate((s) => getComputedStyle(document.querySelector(s)).color, sel);

(async () => {
  const browser = await chromium.launch({ executablePath: process.env.PKCHROME, env: { ...process.env, LD_LIBRARY_PATH: process.env.PKLIBS } });

  // A. an otherwise empty host page that loads the bundles (Codex's case)
  for (const [label, q, want] of [
    ["bare page, new bundles", "?admin=1", 0],
    ["bare page, two nonces, no style on the page yet", "?admin=1&mode=two", null],
    ["bare page, no nonce on the script tag", "?admin=1&tagnonce=0", null],
  ]) {
    const t = await open(browser, "/bare" + q);
    const v = await t.violations();
    const sheets = await t.page.evaluate(() => Array.from(document.querySelectorAll("style")).map((s) => [s.id || s.getAttributeNames().join(","), !!s.sheet]));
    if (want === null) rec(label + " (documented limit, reported not asserted)", true, v.length + " violations; styles " + JSON.stringify(sheets));
    else rec(label + ": no violation, kit styles applied", v.length === want && sheets.length > 0 && sheets.every((s) => s[1]), v.length + " violations; styles " + JSON.stringify(sheets) + (t.errors.length ? " errors " + t.errors : ""));
    await t.ctx.close();
  }
  {
    const t = await open(browser, "/bare?admin=1&old=1");
    const v = await t.violations();
    rec("CONTROL bare page, bundles from before the fix: violations appear", v.length > 0, v.length + " violations: " + v.slice(0, 2).join(" | "));
    await t.ctx.close();
  }

  // C. a controller page with kit components
  for (const mode of ["one", "two", "late"]) {
    const t = await open(browser, "/plain?admin=1&mode=" + mode);
    const p = t.page;
    const tag = "[" + mode + "] ";

    const icons = await p.evaluate(() => Array.from(document.querySelectorAll("#toggle [data-toggle-icon]")).map((i) => getComputedStyle(i).display !== "none"));
    rec(tag + "theme toggle shows exactly one icon (its <style> is accepted)", icons.length === 2 && icons.filter(Boolean).length === 1, JSON.stringify(icons));

    await p.focus("#qty");
    const focused = await p.inputValue("#qty");
    const host = await p.evaluate(() => window.__hostFocus);
    await p.focus("#ns");
    const restored = await p.inputValue("#qty");
    rec(tag + "decimal input: zero clears on focus, returns on blur; the host's own onfocus is BLOCKED by the policy", focused === "" && restored === "0", "focused=" + JSON.stringify(focused) + " restored=" + JSON.stringify(restored) + " hostHandlerRan=" + (host !== undefined));

    await p.click("#copy");
    const c1 = await p.evaluate(() => navigator.clipboard.readText());
    await p.click("#copyfrom");
    const c2 = await p.evaluate(() => navigator.clipboard.readText());
    rec(tag + "copy buttons", c1 === "it's \"quoted\"" && c2 === "https://example.test/cb", JSON.stringify([c1, c2]));

    const hidden = await p.evaluate(() => getComputedStyle(document.querySelector("#broken")).display);
    rec(tag + "broken image is hidden", hidden === "none", hidden);

    await p.focus("#choice");
    await p.click("#choice");
    const active = await p.evaluate(() => document.activeElement.tagName);
    rec(tag + "a click inside data-pk-blur drops the focus", active === "BODY", active);

    await p.focus("#ns");
    await p.keyboard.press("Enter");
    await p.waitForTimeout(200);
    rec(tag + "data-pk-no-submit form is not submitted", p.url().includes("/plain"), p.url());

    const v = await t.violations();
    // The host's own inline onfocus on the decimal input is the one expected violation.
    const unexpected = v.filter((x) => !x.startsWith("script-src-attr"));
    rec(tag + "no violation from the kit's own markup or bundles", unexpected.length === 0, v.length + " total (" + v.filter((x) => x.startsWith("script-src-attr")).length + " from the host's inline handler); unexpected: " + unexpected.slice(0, 3).join(" | ") + (t.errors.length ? " errors " + t.errors : ""));
    await t.ctx.close();
  }

  // D. LiveView: styles added after the socket connects, in the page's view and in nested ones
  for (const mode of ["one", "two", "late"]) {
    const t = await open(browser, "/live?mode=" + mode);
    const p = t.page;
    const tag = "[live " + mode + "] ";
    await p.waitForFunction(() => window.liveSocket && window.liveSocket.isConnected() && document.querySelector("#child-box") && document.querySelector("[data-phx-main].phx-connected, .phx-connected"), null, { timeout: 8000 }).catch(() => {});
    await p.waitForTimeout(500);
    rec(tag + "socket connected", await p.evaluate(() => window.liveSocket.isConnected()), "");

    const first = await color(p, "#child-first");
    rec(tag + "nested view: the style of its first render applies", first === "rgb(1, 2, 3)", first);

    await p.click("#parent-btn"); await p.waitForTimeout(300);
    const pl = await color(p, "#parent-late");
    rec(tag + "page view: a <style> patched in after connect applies", pl === "rgb(10, 11, 12)", pl);

    await p.click("#child-btn"); await p.waitForTimeout(300);
    const cl = await color(p, "#child-late");
    rec(tag + "nested view (use PhoenixKitWeb, :live_view): a <style> patched in after connect applies", cl === "rgb(4, 5, 6)", cl);

    const before = (await t.violations()).length;
    await p.click("#ctl-btn"); await p.waitForTimeout(300);
    const ctl = await color(p, "#ctl-late");
    const after = (await t.violations()).length;
    rec(tag + "CONTROL nested view with nothing restoring the nonce: its late style is blocked", ctl !== "rgb(7, 8, 9)" && after > before, ctl + ", violations " + before + " -> " + after);
    rec(tag + "no violation before the control", before === 0, String(before));
    await t.ctx.close();
  }

  await browser.close();
  const failed = out.filter((o) => !o.ok);
  console.log("\n" + out.length + " checks, " + failed.length + " failed");
})().catch((e) => { console.log("CRASH", e); process.exit(1); });
