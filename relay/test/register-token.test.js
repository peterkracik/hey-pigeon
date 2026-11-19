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
  assert.deepEqual(res.body, { topic: TOPIC, opensUrl: null });
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
  await h.registerToken(fakeReq({ method: "PUT", headers: good }), res);
  assert.equal(res.statusCode, 405);
  assert.equal(res.headers.Allow, "GET, POST, DELETE");
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

test("GET answers where the relay is and writes nothing", async () => {
  const tokens = fakeTokens();
  const h = createHandlers({
    tokens,
    apns: fakeApns(),
    auth: fakeAuth({ good: EMAIL }),
    topic: TOPIC,
    opensUrl: "https://o.example.test",
    log: silentLog(),
  });
  const res = fakeRes();
  // No body, no device token: the Mac has none to give.
  await h.registerToken(fakeReq({ method: "GET", headers: good }), res);
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, { topic: TOPIC, opensUrl: "https://o.example.test" });
  assert.equal(tokens.docs.size, 0);

  // And a registration reports the same.
  const posted = fakeRes();
  await h.registerToken(fakeReq({ headers: good, body: { deviceToken: DEVICE, platform: "ios", environment: "sandbox" } }), posted);
  assert.deepEqual(posted.body, { topic: TOPIC, opensUrl: "https://o.example.test" });
});

test("GET needs the same Google token as a registration", async () => {
  const { tokens, h } = setup();
  const none = fakeRes();
  await h.registerToken(fakeReq({ method: "GET" }), none);
  assert.equal(none.statusCode, 401);
  const bad = fakeRes();
  await h.registerToken(fakeReq({ method: "GET", headers: { authorization: "Bearer bad" } }), bad);
  assert.equal(bad.statusCode, 401);
  assert.equal(bad.body.topic, undefined);
  assert.equal(tokens.docs.size, 0);
  // Without the opens function deployed, it says so.
  const res = fakeRes();
  await h.registerToken(fakeReq({ method: "GET", headers: good }), res);
  assert.deepEqual(res.body, { topic: TOPIC, opensUrl: null });
});

test("a failing store is a 503 with a code in the log, not a crash", async () => {
  for (const [method, request] of [
    ["upsert", { headers: good, body: { deviceToken: DEVICE, platform: "ios", environment: "sandbox" } }],
    ["remove", { method: "DELETE", headers: good, body: { deviceToken: DEVICE } }],
  ]) {
    const tokens = fakeTokens();
    tokens[method] = async () => {
      throw Object.assign(new Error(`unavailable for ${EMAIL}`), { code: 14 });
    };
    const log = silentLog();
    const h = createHandlers({ tokens, apns: fakeApns(), auth: fakeAuth({ good: EMAIL }), topic: TOPIC, log });
    const res = fakeRes();
    await h.registerToken(fakeReq(request), res);
    assert.equal(res.statusCode, 503);
    assert.deepEqual(res.body, { error: "unavailable" });
    assert.deepEqual(log.lines, [`warn register ${HASH.slice(0, 8)}: store failed (14)`]);
  }
});
