"use strict";

// A suggestion's face in the `@` list (`pkMentionFace` in phoenix_kit.js):
// the person's picture by the rule of every face (`UserInfo.avatar_brief/2`),
// placed by its stored crop through the style API, or covering the face; the
// initials underneath (Max, 2026-11-26: the list showed a cropped picture
// whole, and the chips none at all).
//
// Run: mix test.js

const test = require("node:test");
const assert = require("node:assert/strict");
const { createEnv } = require("./support/pk_env.cjs");

function face(avatar) {
  const env = createEnv();
  env.load("phoenix_kit.js");
  assert.equal(typeof env.window.pkMentionFace, "function");
  return env.window.pkMentionFace(avatar);
}

test("a cropped picture is placed by its style, not object-cover", () => {
  const style = "position:absolute;max-width:none;width:200.00%;height:200.00%;left:-50.00%;top:-50.00%;";
  const f = face({ url: "/files/x/small/a.jpg", style: style, initials: "AK", gradient: "from-a to-b" });
  const img = f.children[0];

  assert.equal(f.textContent, "AK");
  assert.equal(img.src, "/files/x/small/a.jpg");
  assert.equal(img.style.cssText, style);
  assert.ok(!String(img.className || "").includes("object-cover"));
});

test("an uncropped picture covers the face", () => {
  const f = face({ url: "https://lh3.example/a.png", style: null, initials: "AK" });
  assert.ok(f.children[0].className.includes("object-cover"));
});

test("no picture: the initials alone", () => {
  const f = face({ url: null, initials: "AK" });
  assert.equal(f.children.length, 0);
  assert.equal(f.textContent, "AK");
});
