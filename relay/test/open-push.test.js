import { test } from "node:test";
import assert from "node:assert/strict";

import { emailHash } from "../src/handlers.js";
import { GRACE_MS } from "../src/classify.js";
import { createOpensHandler, REPEAT_MS, TTL_MS } from "../src/opens-handlers.js";
import { BUDGET_MS, createOpenPush, PAYLOAD, WINDOW_MS } from "../src/open-push.js";
import { DEVICE, DEVICE2, fakeApns, fakeAuth, fakeOpens, fakeRanges, fakeReq, fakeRes, fakeTokens, silentLog } from "./helpers.js";

const EMAIL = "owner@example.com";
const HASH = emailHash(EMAIL);
const OTHER_HASH = emailHash("someone@example.org");
const TOKEN = "0123456789abcdef0123456789abcdef";
const TOKEN2 = "ffffffffffffffffffffffffffffffff";
const NOW = 1_800_000_000_000;
const IP = "203.0.113.77";
const UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 SecretMailClient/9.9";
const reader = { "x-forwarded-for": IP, "user-agent": UA, host: "o.example.test" };

const devices = () => ({
  [HASH]: [
    { token: DEVICE, env: "production", platform: "ios" },
    { token: DEVICE2, env: "sandbox", platform: "ios" },
  ],
});
const sent = (over = {}) => ({
  mailboxHash: HASH,
  createdAt: NOW - GRACE_MS - 60_000,
  expiresAt: NOW + TTL_MS,
  events: [],
  ...over,
});

/** The opens handler with the real push behind it, on fakes. */
function setup({ docs = { [TOKEN]: sent() }, registered = devices(), apns = fakeApns(), ranges = fakeRanges(false), budgetMs } = {}) {
  const clock = { now: NOW };
  const opens = fakeOpens(docs);
  const tokens = fakeTokens(registered);
  const log = silentLog();
  const handle = createOpensHandler({
    opens,
    auth: fakeAuth({ good: EMAIL }),
    ranges,
    publicUrl: "https://o.example.test",
    now: () => clock.now,
    onOpen: createOpenPush({ tokens, apns, now: () => clock.now, log, budgetMs }),
    log,
  });
  const pixel = async (token = TOKEN, headers = reader, method = "GET") => {
    const res = fakeRes();
    await handle(fakeReq({ method, path: `/o/${token}.gif`, headers }), res);
    return res;
  };
  return { opens, tokens, apns, log, clock, pixel };
}

const isGif = (res) => res.statusCode === 200 && res.headers["Content-Type"] === "image/gif" && Buffer.isBuffer(res.body);

test("the payload is exactly a silent wake that says 'opens'", () => {
  assert.deepEqual(PAYLOAD, { aps: { "content-available": 1 }, opens: 1 });
  assert.deepEqual(Object.keys(PAYLOAD).sort(), ["aps", "opens"]);
  assert.deepEqual(Object.keys(PAYLOAD.aps), ["content-available"]);
  // Nothing can be slipped into it on the way out.
  assert.ok(Object.isFrozen(PAYLOAD) && Object.isFrozen(PAYLOAD.aps));
});

test("an open that is stored wakes every registered device of the mailbox once", async () => {
  const { apns, log, pixel } = setup();
  assert.ok(isGif(await pixel()));
  assert.equal(apns.sent.length, 2);
  assert.deepEqual(apns.sent.map((m) => [m.token, m.env]), [[DEVICE, "production"], [DEVICE2, "sandbox"]]);
  for (const m of apns.sent) {
    assert.deepEqual(m.payload, { aps: { "content-available": 1 }, opens: 1 });
    // One collapse id per mailbox, and not the one new mail uses.
    assert.equal(m.collapseId, `o${HASH.slice(0, 15)}`);
    assert.notEqual(m.collapseId, HASH.slice(0, 16));
  }
  // Nothing about who, which message, or from where went to Apple or the log.
  const out = JSON.stringify({ sent: apns.sent.map(({ token: _device, ...rest }) => rest), log: log.lines });
  for (const secret of [EMAIL, TOKEN, IP, "SecretMailClient", "Mozilla", "/o/", ".gif", HASH]) {
    assert.ok(!out.includes(secret), `${secret} left the function: ${out}`);
  }
  assert.deepEqual(log.lines, [`info open-push ${HASH.slice(0, 8)} production 200`, `info open-push ${HASH.slice(0, 8)} sandbox 200`]);
});

test("hidden, ignored and unknown fetches push nothing", async () => {
  // Apple's privacy proxy: stored as hidden, which is not an open.
  const hidden = setup({ ranges: fakeRanges(true) });
  assert.ok(isGif(await hidden.pixel()));
  assert.equal(hidden.opens.docs.get(TOKEN).events[0].label, "hidden");
  assert.equal(hidden.apns.sent.length, 0);

  // Inside the grace window, a scanner, a HEAD: nothing stored, nothing sent.
  const young = setup({ docs: { [TOKEN]: sent({ createdAt: NOW - GRACE_MS + 1 }) } });
  await young.pixel();
  const scanned = setup();
  await scanned.pixel(TOKEN, { ...reader, "user-agent": "curl/8.5.0" });
  await scanned.pixel(TOKEN, reader, "HEAD");
  // An unknown, an expired and a malformed token.
  const unknown = setup();
  await unknown.pixel(TOKEN2);
  await unknown.pixel("nope");
  const expired = setup({ docs: { [TOKEN]: sent({ expiresAt: NOW - 1 }) } });
  await expired.pixel();
  for (const s of [young, scanned, unknown, expired]) {
    assert.equal(s.apns.sent.length, 0);
    assert.equal(s.log.lines.length, 0);
  }
});

test("a repeat within a minute stores nothing and pushes nothing", async () => {
  const { opens, apns, pixel, clock } = setup({ registered: { [HASH]: [{ token: DEVICE, env: "production", platform: "ios" }] } });
  for (let i = 0; i < 30; i += 1) {
    clock.now += 1000;
    await pixel();
  }
  assert.equal(opens.docs.get(TOKEN).events.length, 1);
  assert.equal(apns.sent.length, 1);
});

test("one mailbox is woken at most once a window, however many messages are opened", async () => {
  // A newsletter: two hundred tracked messages of one mailbox, all opened now.
  const docs = {};
  const many = Array.from({ length: 200 }, (_, i) => i.toString(16).padStart(32, "a"));
  for (const t of many) docs[t] = sent();
  // And one message of another mailbox, with its own device.
  docs[TOKEN2] = sent({ mailboxHash: OTHER_HASH });
  const { opens, apns, pixel, clock } = setup({
    docs,
    registered: { [HASH]: [{ token: DEVICE, env: "production", platform: "ios" }], [OTHER_HASH]: [{ token: DEVICE2, env: "production", platform: "ios" }] },
  });
  for (const t of many) {
    clock.now += 100;
    await pixel(t);
  }
  assert.equal(many.filter((t) => opens.docs.get(t).events.length === 1).length, 200, "every open is still stored");
  assert.equal(apns.sent.length, 1);
  // Another mailbox has its own window.
  await pixel(TOKEN2);
  assert.deepEqual(apns.sent.map((m) => m.token), [DEVICE, DEVICE2]);
  // Past the window (and past the same-label minute), the next open wakes again.
  clock.now = NOW + 200 * 100 + Math.max(WINDOW_MS, REPEAT_MS) + 1;
  await pixel(many[0]);
  assert.equal(apns.sent.filter((m) => m.token === DEVICE).length, 2);
  assert.equal(WINDOW_MS, 60_000);
});

test("a mailbox with no registered device is a no-op without a log line", async () => {
  const { apns, log, pixel } = setup({ registered: {} });
  assert.ok(isGif(await pixel()));
  assert.equal(apns.sent.length, 0);
  assert.equal(log.lines.length, 0);
});

test("a failing APNs call still answers the GIF and keeps the event", async () => {
  for (const script of [
    () => Object.assign(new Error(`cannot reach apple for ${TOKEN}`), { code: "ECONNRESET" }),
    () => ({ status: 500, reason: "InternalServerError" }),
    () => ({ status: 400, reason: "BadDeviceToken" }),
  ]) {
    const { opens, tokens, log, pixel } = setup({ apns: fakeApns(script) });
    assert.ok(isGif(await pixel()));
    assert.equal(opens.docs.get(TOKEN).events.length, 1);
    // A device is only forgotten when Apple says it is gone.
    assert.equal((await tokens.get(HASH)).length, 2);
    assert.ok(log.lines.every((l) => l.includes(`open-push ${HASH.slice(0, 8)}`)));
    assert.ok(!log.lines.join("\n").includes(TOKEN));
  }
  // A token table that fails is caught too.
  const broken = setup();
  broken.tokens.get = async () => {
    throw Object.assign(new Error("firestore down"), { code: 14 });
  };
  assert.ok(isGif(await broken.pixel()));
  assert.deepEqual(broken.log.lines, [`warn open-push ${HASH.slice(0, 8)}: 14`]);
});

test("a device Apple says is gone is forgotten", async () => {
  const { tokens, pixel } = setup({ apns: fakeApns((m) => (m.token === DEVICE ? { status: 410, reason: "Unregistered" } : { status: 200 })) });
  await pixel();
  assert.deepEqual((await tokens.get(HASH)).map((d) => d.token), [DEVICE2]);
});

test("the pixel never waits for Apple longer than the budget", async () => {
  let release;
  const stuck = new Promise((resolve) => {
    release = resolve;
  });
  const apns = { sent: [], send: async (m) => (apns.sent.push(m), stuck.then(() => ({ status: 200 }))) };
  const { log, pixel } = setup({ apns, budgetMs: 20 });
  const started = Date.now();
  assert.ok(isGif(await pixel()));
  assert.ok(Date.now() - started < 1000, "answered without Apple");
  assert.equal(apns.sent.length, 1);
  assert.deepEqual(log.lines, [`info open-push ${HASH.slice(0, 8)}: not waited for`]);
  release();
  assert.ok(BUDGET_MS <= 2000);
});

test("the push module alone: bad input is ignored, the window is per mailbox", async () => {
  const apns = fakeApns();
  let at = NOW;
  const onOpen = createOpenPush({ tokens: fakeTokens({ [HASH]: [{ token: DEVICE, env: "production", platform: "ios" }] }), apns, now: () => at, log: silentLog() });
  for (const bad of [undefined, null, "", 42, {}]) await onOpen(bad);
  assert.equal(apns.sent.length, 0);
  await onOpen(HASH);
  await onOpen(HASH);
  at += WINDOW_MS - 1;
  await onOpen(HASH);
  assert.equal(apns.sent.length, 1);
  at += 1;
  await onOpen(HASH);
  assert.equal(apns.sent.length, 2);
  // A clock that went back does not silence it for good.
  at -= 10 * WINDOW_MS;
  await onOpen(HASH);
  assert.equal(apns.sent.length, 3);
});
