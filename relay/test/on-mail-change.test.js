import { test } from "node:test";
import assert from "node:assert/strict";

import { createHandlers, emailHash, decodePubsub } from "../src/handlers.js";
import { fakeTokens, fakeApns, fakeAuth, silentLog, pubsubEvent, DEVICE, DEVICE2 } from "./helpers.js";

const EMAIL = "Someone@Example.com";
const HASH = emailHash(EMAIL);

test("decodePubsub accepts a numeric historyId and normalises it to a string", () => {
  const c = decodePubsub(pubsubEvent({ emailAddress: "a@b.c", historyId: 12345 }));
  assert.deepEqual(c, { emailAddress: "a@b.c", historyId: "12345" });
  assert.equal(decodePubsub(pubsubEvent({ emailAddress: "nope" })), null);
  assert.equal(decodePubsub({ data: { message: { data: "!!!" } } }), null);
  assert.equal(decodePubsub({}), null);
});

test("emailHash is case- and whitespace-insensitive", () => {
  assert.equal(emailHash(" SOMEONE@example.com "), emailHash("someone@example.com"));
});

test("sends one silent push per device with the expected payload and headers", async () => {
  const tokens = fakeTokens({ [HASH]: [{ token: DEVICE, env: "sandbox" }, { token: DEVICE2, env: "production" }] });
  const apns = fakeApns();
  const log = silentLog();
  const h = createHandlers({ tokens, apns, auth: fakeAuth({}), topic: "t", log });

  await h.onMailChange(pubsubEvent({ emailAddress: EMAIL, historyId: 777 }));

  assert.equal(apns.sent.length, 2);
  assert.deepEqual(apns.sent[0].payload, { aps: { "content-available": 1 }, email: EMAIL, historyId: "777" });
  assert.equal(apns.sent[0].env, "sandbox");
  assert.equal(apns.sent[1].env, "production");
  assert.equal(apns.sent[0].collapseId, HASH.slice(0, 16));
  // Log lines never carry the address.
  assert.ok(log.lines.every((l) => !l.toLowerCase().includes("example.com")));
  assert.ok(log.lines.some((l) => l.includes(HASH.slice(0, 8))));
});

test("unknown address is a silent no-op", async () => {
  const tokens = fakeTokens();
  const apns = fakeApns();
  const log = silentLog();
  const h = createHandlers({ tokens, apns, auth: fakeAuth({}), topic: "t", log });
  await h.onMailChange(pubsubEvent({ emailAddress: "stranger@x.y", historyId: 1 }));
  assert.equal(apns.sent.length, 0);
  assert.deepEqual(log.lines, []);
});

test("410 removes the token; 400 BadDeviceToken keeps it", async () => {
  const tokens = fakeTokens({ [HASH]: [{ token: DEVICE, env: "production" }, { token: DEVICE2, env: "sandbox" }] });
  const apns = fakeApns((m) =>
    m.token === DEVICE ? { status: 410, reason: "Unregistered" } : { status: 400, reason: "BadDeviceToken" },
  );
  const h = createHandlers({ tokens, apns, auth: fakeAuth({}), topic: "t", log: silentLog() });
  await h.onMailChange(pubsubEvent({ emailAddress: EMAIL, historyId: 2 }));
  assert.deepEqual(
    (await tokens.get(HASH)).map((t) => t.token),
    [DEVICE2],
  );
});

test("a transport error on one device does not stop the others", async () => {
  const tokens = fakeTokens({ [HASH]: [{ token: DEVICE, env: "production" }, { token: DEVICE2, env: "production" }] });
  const apns = fakeApns((m) => (m.token === DEVICE ? Object.assign(new Error("boom"), { code: "ECONNRESET" }) : { status: 200 }));
  const log = silentLog();
  const h = createHandlers({ tokens, apns, auth: fakeAuth({}), topic: "t", log });
  await h.onMailChange(pubsubEvent({ emailAddress: EMAIL, historyId: 3 }));
  assert.equal(apns.sent.length, 2);
  assert.ok(log.lines.some((l) => l.includes("ECONNRESET")));
});
