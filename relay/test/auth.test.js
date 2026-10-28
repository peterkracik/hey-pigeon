import { test } from "node:test";
import assert from "node:assert/strict";

import { rejectReason, createAuth } from "../src/auth.js";

const CLIENT = "123-ios.apps.googleusercontent.com";
const allowed = new Set([CLIENT]);
// What tokeninfo returns for the app's grant: no email (no userinfo.email scope).
const ok = {
  aud: CLIENT,
  azp: CLIENT,
  scope: "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/drive.appdata",
  expires_in: "3599",
};
const silent = { warn() {}, info() {} };

test("accepts a token from an allowed client with a gmail scope", () => {
  assert.equal(rejectReason(ok, allowed), null);
  assert.equal(rejectReason({ ...ok, email: "x@y.z", email_verified: "true" }, allowed), null);
});

test("rejects other clients, explicitly unverified emails and non-gmail grants", () => {
  assert.match(rejectReason({ ...ok, aud: "other", azp: "other" }, allowed), /aud other/);
  assert.equal(rejectReason({ ...ok, email: "x@y.z", email_verified: "false" }, allowed), "email not verified");
  assert.equal(rejectReason({ ...ok, scope: "openid profile" }, allowed), "no gmail scope");
  assert.equal(rejectReason(null, allowed), "no tokeninfo");
});

test("verify resolves the address from the Gmail profile when tokeninfo has none", async () => {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, auth: init?.headers?.authorization });
    if (url.startsWith("https://oauth2.googleapis.com/tokeninfo")) {
      if (url.includes("access_token=expired")) return { ok: false, status: 400, json: async () => ({}) };
      return { ok: true, json: async () => ok };
    }
    if (url === "https://gmail.googleapis.com/gmail/v1/users/me/profile") {
      return { ok: true, json: async () => ({ emailAddress: "owner@example.com", historyId: "42" }) };
    }
    throw new Error("unexpected " + url);
  };
  const auth = createAuth({ clientIds: [CLIENT], fetchImpl, log: silent });
  assert.equal(await auth.verify("live"), "owner@example.com");
  assert.equal(calls[1].auth, "Bearer live");
  assert.equal(await auth.verify("expired"), null);
  assert.equal(calls.filter((c) => c.url.includes("profile")).length, 1, "no profile call for a rejected token");
});

test("verify uses the tokeninfo email when present and skips the profile call", async () => {
  const calls = [];
  const fetchImpl = async (url) => {
    calls.push(url);
    return { ok: true, json: async () => ({ ...ok, email: "owner@example.com", email_verified: "true" }) };
  };
  const auth = createAuth({ clientIds: [CLIENT], fetchImpl, log: silent });
  assert.equal(await auth.verify("live"), "owner@example.com");
  assert.equal(calls.length, 1);
});

test("a failing profile call is a rejection, not a crash", async () => {
  const fetchImpl = async (url) =>
    url.includes("tokeninfo") ? { ok: true, json: async () => ok } : { ok: false, status: 403, json: async () => ({}) };
  const auth = createAuth({ clientIds: [CLIENT], fetchImpl, log: silent });
  assert.equal(await auth.verify("live"), null);
});

test("no configured client ids means nobody is accepted", async () => {
  const auth = createAuth({ clientIds: [], fetchImpl: async () => ({ ok: true, json: async () => ok }), log: silent });
  assert.equal(await auth.verify("live"), null);
});
