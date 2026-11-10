"use strict";

// Unit tests for the passkey helpers in priv/static/assets/phoenix_kit.js: the
// base64url conversion both ways, and the shaping of the server's options and
// the browser's answers (PasskeySignIn / PasskeyRegister).
//
// Run: mix test.js

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

const {
  passkeyToBase64Url,
  passkeyFromBase64Url,
  passkeyCreationOptions,
  passkeyRequestOptions,
  passkeyRegistrationPayload,
  passkeyAssertionPayload,
} = require("../../priv/static/assets/phoenix_kit.js");

const bytes = (...list) => new Uint8Array(list);

test("base64url has no padding and no + or /", () => {
  assert.equal(passkeyToBase64Url(bytes(0xfb, 0xff, 0xbf)), "-_-_");
  assert.equal(passkeyToBase64Url(bytes(1)), "AQ");
  assert.equal(passkeyToBase64Url(bytes()), "");
});

test("base64url round-trips every byte value", () => {
  const all = new Uint8Array(256).map((_, i) => i);
  assert.deepEqual(passkeyFromBase64Url(passkeyToBase64Url(all)), all);
});

test("an ArrayBuffer encodes like its bytes", () => {
  assert.equal(passkeyToBase64Url(bytes(1, 2, 3).buffer), passkeyToBase64Url(bytes(1, 2, 3)));
});

test("creation options turn the challenge, the user id and excluded ids into bytes", () => {
  const options = passkeyCreationOptions({
    challenge: "AQID",
    rp: { id: "example.com", name: "Example" },
    user: { id: "BAU", name: "a@example.com", displayName: "A" },
    excludeCredentials: [{ type: "public-key", id: "Bg", transports: ["internal"] }],
    authenticatorSelection: { residentKey: "required" },
  });

  assert.deepEqual(options.challenge, bytes(1, 2, 3));
  assert.deepEqual(options.user.id, bytes(4, 5));
  assert.equal(options.user.name, "a@example.com");
  assert.deepEqual(options.excludeCredentials, [
    { type: "public-key", id: bytes(6), transports: ["internal"] },
  ]);
  assert.deepEqual(options.rp, { id: "example.com", name: "Example" });
  assert.equal(options.authenticatorSelection.residentKey, "required");
});

test("request options with no allowed credentials give an empty list", () => {
  const options = passkeyRequestOptions({ challenge: "AQID", rpId: "example.com" });
  assert.deepEqual(options.challenge, bytes(1, 2, 3));
  assert.deepEqual(options.allowCredentials, []);
  assert.equal(options.rpId, "example.com");
});

test("a registration answer is sent as base64url with its transports", () => {
  const payload = passkeyRegistrationPayload(
    {
      rawId: bytes(9).buffer,
      response: {
        attestationObject: bytes(1).buffer,
        clientDataJSON: bytes(2).buffer,
        getTransports: () => ["internal", "hybrid"],
      },
    },
    "Mozilla/5.0"
  );

  assert.deepEqual(payload, {
    rawId: "CQ",
    attestationObject: "AQ",
    clientDataJSON: "Ag",
    transports: ["internal", "hybrid"],
    userAgent: "Mozilla/5.0",
  });
});

test("a browser without getTransports sends none", () => {
  const payload = passkeyRegistrationPayload({
    rawId: bytes(9).buffer,
    response: { attestationObject: bytes(1).buffer, clientDataJSON: bytes(2).buffer },
  });

  assert.deepEqual(payload.transports, []);
  assert.equal(payload.userAgent, "");
});

test("a sign-in answer carries the user handle, or null without one", () => {
  const credential = (userHandle) => ({
    rawId: bytes(9).buffer,
    response: {
      authenticatorData: bytes(1).buffer,
      clientDataJSON: bytes(2).buffer,
      signature: bytes(3).buffer,
      userHandle,
    },
  });

  assert.deepEqual(passkeyAssertionPayload(credential(bytes(4).buffer)), {
    rawId: "CQ",
    authenticatorData: "AQ",
    clientDataJSON: "Ag",
    signature: "Aw",
    userHandle: "BA",
  });

  assert.equal(passkeyAssertionPayload(credential(null)).userHandle, null);
});
