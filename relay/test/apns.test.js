import { test } from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, verify } from "node:crypto";
import { EventEmitter } from "node:events";

import { signProviderToken, createApns } from "../src/apns.js";

const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const keyPem = privateKey.export({ type: "pkcs8", format: "pem" });

test("provider JWT is ES256 with kid/iss/iat and verifies with the public key", () => {
  const jwt = signProviderToken({ keyPem, keyId: "KEY123", teamId: "TEAM456", nowMs: 1_700_000_000_000 });
  const [h, c, s] = jwt.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(h, "base64url")), { alg: "ES256", kid: "KEY123" });
  assert.deepEqual(JSON.parse(Buffer.from(c, "base64url")), { iss: "TEAM456", iat: 1_700_000_000 });
  const okSig = verify("sha256", Buffer.from(`${h}.${c}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(s, "base64url"));
  assert.ok(okSig);
});

/** Minimal http2 session/stream fake recording headers and body. */
function fakeConnect(script) {
  const connected = [];
  const connect = (host) => {
    const session = new EventEmitter();
    session.closed = false;
    session.destroyed = false;
    session.requests = [];
    session.request = (headers) => {
      const stream = new EventEmitter();
      stream.setEncoding = () => {};
      stream.close = () => {};
      stream.end = (body) => {
        session.requests.push({ headers, body: JSON.parse(body) });
        const r = script(headers, host);
        queueMicrotask(() => {
          stream.emit("response", { ":status": r.status });
          if (r.body) stream.emit("data", JSON.stringify(r.body));
          stream.emit("end");
        });
      };
      return stream;
    };
    connected.push({ host, session });
    return session;
  };
  return { connect, connected };
}

test("send targets the host for the token's environment with background-push headers", async () => {
  let loads = 0;
  const { connect, connected } = fakeConnect(() => ({ status: 200 }));
  const apns = createApns({
    keyId: "K",
    teamId: "T",
    topic: "app.heypigeon.ios",
    loadKey: async () => {
      loads += 1;
      return keyPem;
    },
    now: () => 1_700_000_000_000,
    connect,
  });

  const r1 = await apns.send({ token: "aa", env: "sandbox", payload: { aps: { "content-available": 1 } }, collapseId: "c1" });
  const r2 = await apns.send({ token: "bb", env: "production", payload: { aps: { "content-available": 1 } } });
  assert.equal(r1.status, 200);
  assert.equal(r2.status, 200);
  assert.deepEqual(
    connected.map((c) => c.host),
    ["https://api.sandbox.push.apple.com", "https://api.push.apple.com"],
  );
  const h = connected[0].session.requests[0].headers;
  assert.equal(h[":path"], "/3/device/aa");
  assert.equal(h["apns-push-type"], "background");
  assert.equal(h["apns-priority"], "5");
  assert.equal(h["apns-topic"], "app.heypigeon.ios");
  assert.equal(h["apns-collapse-id"], "c1");
  assert.equal(h["apns-expiration"], String(1_700_000_000 + 600));
  assert.ok(h.authorization.startsWith("bearer "));
  assert.equal(loads, 1, "the key is read once and the JWT cached");
  // Second production send reuses the session.
  await apns.send({ token: "cc", env: "production", payload: {} });
  assert.equal(connected.length, 2);
});

test("send surfaces APNs status and reason", async () => {
  const { connect } = fakeConnect(() => ({ status: 410, body: { reason: "Unregistered" } }));
  const apns = createApns({ keyId: "K", teamId: "T", topic: "t", loadKey: async () => keyPem, connect });
  const r = await apns.send({ token: "aa", env: "production", payload: {} });
  assert.deepEqual(r, { status: 410, reason: "Unregistered" });
});
