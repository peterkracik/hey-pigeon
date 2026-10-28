import { test } from "node:test";
import assert from "node:assert/strict";

import { acceptTokenInfo, createAuth } from "../src/auth.js";

const CLIENT = "123-ios.apps.googleusercontent.com";
const allowed = new Set([CLIENT]);
const ok = {
  aud: CLIENT,
  azp: CLIENT,
  email: "owner@example.com",
  email_verified: "true",
  scope: "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/drive.appdata",
};

test("accepts a verified token from an allowed client with a gmail scope", () => {
  assert.equal(acceptTokenInfo(ok, allowed), "owner@example.com");
});

test("rejects other clients, unverified emails and non-gmail grants", () => {
  assert.equal(acceptTokenInfo({ ...ok, aud: "other", azp: "other" }, allowed), null);
  assert.equal(acceptTokenInfo({ ...ok, email_verified: "false" }, allowed), null);
  assert.equal(acceptTokenInfo({ ...ok, scope: "openid profile" }, allowed), null);
  assert.equal(acceptTokenInfo({ ...ok, email: undefined }, allowed), null);
  assert.equal(acceptTokenInfo(null, allowed), null);
});

test("createAuth calls tokeninfo and maps non-2xx to null", async () => {
  const calls = [];
  const fetchImpl = async (url) => {
    calls.push(url);
    if (url.includes("access_token=expired")) return { ok: false, status: 400, json: async () => ({}) };
    return { ok: true, json: async () => ok };
  };
  const auth = createAuth({ clientIds: [CLIENT], fetchImpl });
  assert.equal(await auth.verify("live"), "owner@example.com");
  assert.equal(await auth.verify("expired"), null);
  assert.ok(calls[0].startsWith("https://oauth2.googleapis.com/tokeninfo?access_token=live"));
});

test("no configured client ids means nobody is accepted", async () => {
  const auth = createAuth({ clientIds: [], fetchImpl: async () => ({ ok: true, json: async () => ok }) });
  assert.equal(await auth.verify("live"), null);
});
