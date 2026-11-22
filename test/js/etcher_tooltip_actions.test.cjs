"use strict";

// The tooltip header actions Etcher shows on a persisted shape of the media
// viewer: Reply / Edit label / View discussion (`window.Etcher.tooltipActions`
// in phoenix_kit.js). A surface without the comment contract (no
// `comment_count`, no `comments_off`) keeps the plain tooltip. A viewer with
// comments switched off keeps label editing and drops only Reply and View.
//
//   node --test test/js/etcher_tooltip_actions.test.cjs

const test = require("node:test");
const assert = require("node:assert/strict");
const { createEnv } = require("./support/pk_env.cjs");

const env = createEnv();
env.load("phoenix_kit.js");
// The bundle runs in its own realm: copy the names into this one's array.
const actions = (shape) =>
  Array.from(env.window.Etcher.tooltipActions(shape), (a) => a.action);

test("a shape with a comment thread offers Reply, Edit label and View", () => {
  const shape = { uuid: "s1", metadata: { comment_count: 2 } };
  assert.deepEqual(actions(shape), ["pk-reply", "pk-edit", "pk-view"]);
});

test("a shape without a thread offers Reply and Edit label", () => {
  const shape = { uuid: "s1", metadata: { comment_count: 0 } };
  assert.deepEqual(actions(shape), ["pk-reply", "pk-edit"]);
});

test("a read-only shape cannot be edited", () => {
  const shape = { uuid: "s1", readonly: true, metadata: { comment_count: 0 } };
  assert.deepEqual(actions(shape), ["pk-reply"]);
});

test("a surface without the comment contract keeps the plain tooltip", () => {
  assert.deepEqual(actions({ uuid: "s1", metadata: {} }), []);
  assert.deepEqual(actions({ uuid: "s1" }), []);
  assert.deepEqual(actions({ metadata: { comment_count: 1 } }), []);
});

test("with comments off the label stays editable and Reply / View are gone", () => {
  const shape = { uuid: "s1", metadata: { comments_off: true } };
  assert.deepEqual(actions(shape), ["pk-edit"]);
});

test("with comments off a read-only shape has no action at all", () => {
  const shape = { uuid: "s1", readonly: true, metadata: { comments_off: true } };
  assert.deepEqual(actions(shape), []);
});

test("with comments off a stray comment_count does not bring View back", () => {
  const shape = { uuid: "s1", metadata: { comments_off: true, comment_count: 3 } };
  assert.deepEqual(actions(shape), ["pk-edit"]);
});
