import { test } from "node:test";
import assert from "node:assert/strict";

import { createHandlers, emailHash } from "../src/handlers.js";
import { fakeTokens, fakeApns, fakeAuth, silentLog, fakeReq, fakeRes, DEVICE } from "./helpers.js";

const TOPIC = "projects/p/topics/gmail-push";
const EMAIL = "owner@example.com";
const HASH = emailHash(EMAIL);

function setup(initial) {
  const tokens = fakeTokens(initial);
  const h = createHandlers({
    tokens,
    apns: fakeApns(),
    auth: fakeAuth({ good: EMAIL }),
    topic: TOPIC,
    log: silentLog(),
  });
  return { tokens, h };
}

const good = { authorization: "Bearer good" };

test("POST with a valid token stores the device and returns the topic", async () => {
  const { tokens, h } = setup();
  const res = fakeRes();
  await h.registerToken(fakeReq({ headers: good, body: { deviceToken: DEVICE, platform: "ios", environment: "sandbox" } }), res);
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, { topic: TOPIC });
  const stored = await tokens.get(HASH);
  assert.equal(stored.length, 1);
  assert.equal(stored[0].token, DEVICE);
  assert.equal(stored[0].env, "sandbox");
});

test("re-registering the same device replaces, not duplicates", async () => {
  const { tokens, h } = setup({ [HASH]: [{ token: DEVICE, env: "sandbox", platform: "ios" }] });
  await h.registerToken(fakeReq({ headers: good, body: { deviceToken: DEVICE, platform: "ios", environment: "production" } }), fakeRes());
  const stored = await tokens.get(HASH);
  assert.equal(stored.length, 1);
  assert.equal(stored[0].env, "production");
});

test("DELETE removes the device", async () => {
  const { tokens, h } = setup({ [HASH]: [{ token: DEVICE, env: "sandbox", platform: "ios" }] });
  const res = fakeRes();
  await h.registerToken(fakeReq({ method: "DELETE", headers: good, body: { deviceToken: DEVICE } }), res);
  assert.equal(res.statusCode, 204);
  assert.deepEqual(await tokens.get(HASH), []);
});

test("missing or rejected bearer is 401 and writes nothing", async () => {
  const { tokens, h } = setup();
  const r1 = fakeRes();
  await h.registerToken(fakeReq({ body: { deviceToken: DEVICE, platform: "ios", environment: "sandbox" } }), r1);
  assert.equal(r1.statusCode, 401);
  const r2 = fakeRes();
  await h.registerToken(
    fakeReq({ headers: { authorization: "Bearer bad" }, body: { deviceToken: DEVICE, platform: "ios", environment: "sandbox" } }),
    r2,
  );
  assert.equal(r2.statusCode, 401);
  assert.equal(tokens.docs.size, 0);
});

test("bad bodies are 400", async () => {
  const { h } = setup();
  for (const body of [
    {},
    { deviceToken: "not hex", platform: "ios", environment: "sandbox" },
    { deviceToken: DEVICE, platform: "android", environment: "sandbox" },
    { deviceToken: DEVICE, platform: "ios", environment: "staging" },
  ]) {
    const res = fakeRes();
    await h.registerToken(fakeReq({ headers: good, body }), res);
    assert.equal(res.statusCode, 400, JSON.stringify(body));
  }
});

test("other methods are 405", async () => {
  const { h } = setup();
  const res = fakeRes();
  await h.registerToken(fakeReq({ method: "GET", headers: good }), res);
  assert.equal(res.statusCode, 405);
  assert.equal(res.headers.Allow, "POST, DELETE");
});

test("tokeninfo outage is 502, not 401", async () => {
  const tokens = fakeTokens();
  const h = createHandlers({
    tokens,
    apns: fakeApns(),
    auth: { verify: async () => { throw new Error("fetch failed"); } },
    topic: TOPIC,
    log: silentLog(),
  });
  const res = fakeRes();
  await h.registerToken(fakeReq({ headers: good, body: { deviceToken: DEVICE, platform: "ios", environment: "sandbox" } }), res);
  assert.equal(res.statusCode, 502);
});
