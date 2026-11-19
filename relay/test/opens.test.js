import { test } from "node:test";
import assert from "node:assert/strict";

import { emailHash } from "../src/handlers.js";
import { GRACE_MS } from "../src/classify.js";
import { createOpensHandler, MAX_EVENTS, MAX_QUERY, PIXEL, TTL_MS } from "../src/opens-handlers.js";
import { fakeAuth, fakeOpens, fakeRanges, fakeReq, fakeRes, silentLog } from "./helpers.js";

const EMAIL = "owner@example.com";
const OTHER = "someone@example.org";
const HASH = emailHash(EMAIL);
const OTHER_HASH = emailHash(OTHER);
const TOKEN = "0123456789abcdef0123456789abcdef";
const TOKEN2 = "ffffffffffffffffffffffffffffffff";
const NOW = 1_800_000_000_000;
const good = { authorization: "Bearer good" };

// What a real mail client's request carries, and must never be kept.
const IP = "203.0.113.77";
const UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 SecretMailClient/9.9";
const reader = { "x-forwarded-for": `10.9.8.7, ${IP}`, "user-agent": UA, host: "o.example.test" };

/** A registered token, sent `ageMs` ago. */
const sent = (ageMs = GRACE_MS + 60_000, over = {}) => ({
  mailboxHash: HASH,
  createdAt: NOW - ageMs,
  expiresAt: NOW - ageMs + TTL_MS,
  events: [],
  ...over,
});

function setup({ docs = {}, ranges = fakeRanges(false), publicUrl = "", clock = { now: NOW } } = {}) {
  const opens = fakeOpens(docs);
  const log = silentLog();
  const opened = [];
  const handle = createOpensHandler({
    opens,
    auth: fakeAuth({ good: EMAIL, other: OTHER }),
    ranges,
    publicUrl,
    now: () => clock.now,
    onOpen: (hash) => opened.push(hash),
    log,
  });
  const call = async (req) => {
    const res = fakeRes();
    await handle(fakeReq(req), res);
    return res;
  };
  const pixel = (token = TOKEN, headers = reader, method = "GET") => call({ method, path: `/o/${token}.gif`, headers });
  return { opens, log, opened, ranges, call, pixel, clock };
}

function assertIsThePixel(res) {
  assert.equal(res.statusCode, 200);
  assert.equal(res.headers["Content-Type"], "image/gif");
  assert.equal(res.headers["Cache-Control"], "no-store, no-cache, must-revalidate, private");
  assert.equal(res.headers.Location, undefined, "no redirect");
  assert.equal(res.headers["Set-Cookie"], undefined, "no cookie");
  assert.ok(Buffer.isBuffer(res.body) && res.body.equals(PIXEL));
}

test("the pixel is a valid 1×1 GIF", () => {
  assert.equal(PIXEL.subarray(0, 6).toString("latin1"), "GIF89a");
  assert.equal(PIXEL.readUInt16LE(6), 1);
  assert.equal(PIXEL.readUInt16LE(8), 1);
  assert.equal(PIXEL[PIXEL.length - 1], 0x3b);
});

// ---- register

test("register needs a valid Google token and stores the token under the mailbox hash for 30 days", async () => {
  const { opens, call } = setup();
  for (const headers of [{}, { authorization: "Bearer bad" }, { authorization: "good" }]) {
    const res = await call({ path: "/v1/tokens", headers, body: { token: TOKEN } });
    assert.equal(res.statusCode, 401);
  }
  assert.equal(opens.calls.length, 0);

  const res = await call({ path: "/v1/tokens", headers: { ...good, host: "opens-abc.a.run.app" }, body: { token: TOKEN.toUpperCase() } });
  assert.equal(res.statusCode, 200);
  // No public URL configured: the address the app called is the pixel's.
  assert.deepEqual(res.body, { pixelUrl: `https://opens-abc.a.run.app/o/${TOKEN}.gif` });
  assert.deepEqual(opens.docs.get(TOKEN), { mailboxHash: HASH, createdAt: NOW, expiresAt: NOW + TTL_MS, events: [] });
  assert.equal(TTL_MS, 30 * 24 * 3600 * 1000);
  // The address is nowhere in what was stored.
  assert.ok(!JSON.stringify([...opens.docs]).includes(EMAIL));
});

test("register answers with the configured pixel host, is idempotent, and refuses another mailbox's token", async () => {
  const { opens, call } = setup({ publicUrl: "https://o.heypigeon.app" });
  const first = await call({ path: "/v1/tokens", headers: good, body: { token: TOKEN } });
  assert.deepEqual(first.body, { pixelUrl: `https://o.heypigeon.app/o/${TOKEN}.gif` });
  // A retried send registers again: same answer, the document untouched.
  opens.docs.get(TOKEN).events.push({ label: "opened", at: NOW });
  const again = await call({ path: "/v1/tokens", headers: good, body: { token: TOKEN } });
  assert.equal(again.statusCode, 200);
  assert.equal(opens.docs.get(TOKEN).events.length, 1);
  const stolen = await call({ path: "/v1/tokens", headers: { authorization: "Bearer other" }, body: { token: TOKEN } });
  assert.equal(stolen.statusCode, 409);
  assert.equal(opens.docs.get(TOKEN).mailboxHash, HASH);
});

test("register refuses anything that is not 32 hex digits", async () => {
  const { opens, call } = setup();
  for (const token of [undefined, "", "abc", TOKEN + "0", TOKEN.slice(1) + "g", 42, { a: 1 }, `../${TOKEN}`]) {
    const res = await call({ path: "/v1/tokens", headers: good, body: { token } });
    assert.equal(res.statusCode, 400, String(token));
  }
  assert.equal(opens.docs.size, 0);
});

// ---- pixel

test("an unknown token gets the GIF and nothing else happens", async () => {
  const { opens, log, opened, ranges, pixel } = setup();
  assertIsThePixel(await pixel(TOKEN2));
  // One lookup. No write, no address list, no push, no log line.
  assert.deepEqual(opens.calls, [["get", TOKEN2, NOW]]);
  assert.equal(ranges.asked.length, 0);
  assert.equal(opened.length, 0);
  assert.equal(log.lines.length, 0);
});

test("a malformed name under /o/ gets the GIF without a lookup", async () => {
  const { opens, call } = setup();
  for (const path of ["/o/", "/o/x.gif", `/o/${TOKEN}`, `/o/${TOKEN}.png`, `/o/${TOKEN.toUpperCase()}.gif`, `/o/${TOKEN}.gif/x`, "/o/../v1/tokens"]) {
    assertIsThePixel(await call({ method: "GET", path, headers: reader }));
  }
  assert.equal(opens.calls.length, 0);
});

test("an expired token is an unknown token", async () => {
  const { opens, pixel } = setup({ docs: { [TOKEN]: sent(TTL_MS + 1) } });
  assertIsThePixel(await pixel());
  assert.deepEqual(opens.writes(), []);
});

test("a known token opened by a mail client: the GIF, one event, one notification", async () => {
  const { opens, opened, pixel } = setup({ docs: { [TOKEN]: sent() } });
  assertIsThePixel(await pixel());
  assert.deepEqual(opens.docs.get(TOKEN).events, [{ label: "opened", at: NOW }]);
  assert.deepEqual(opens.writes(), [["append", TOKEN, { label: "opened", at: NOW }, MAX_EVENTS, NOW]]);
  // The seam for the silent push: the mailbox hash and nothing more.
  assert.deepEqual(opened, [HASH]);
});

test("Apple's privacy proxy is stored as hidden, by address or by user agent", async () => {
  const byAddress = setup({ docs: { [TOKEN]: sent() }, ranges: fakeRanges((ip) => ip === IP) });
  assertIsThePixel(await byAddress.pixel());
  assert.deepEqual(byAddress.opens.docs.get(TOKEN).events, [{ label: "hidden", at: NOW }]);
  // The address asked about is the one Google appended, not the one the
  // client wrote in front of it.
  assert.deepEqual(byAddress.ranges.asked, [IP]);

  const listDown = setup({ docs: { [TOKEN]: sent() }, ranges: fakeRanges(null) });
  await listDown.pixel(TOKEN, { ...reader, "user-agent": "Mozilla/5.0" });
  assert.deepEqual(listDown.opens.docs.get(TOKEN).events, [{ label: "hidden", at: NOW }]);
});

test("the grace window, scanners and HEAD record nothing — and still get the GIF", async () => {
  const young = setup({ docs: { [TOKEN]: sent(GRACE_MS - 1) } });
  assertIsThePixel(await young.pixel());
  assert.deepEqual(young.opens.writes(), []);

  const scanned = setup({ docs: { [TOKEN]: sent() } });
  assertIsThePixel(await scanned.pixel(TOKEN, { ...reader, "user-agent": "curl/8.5.0" }));
  assertIsThePixel(await scanned.pixel(TOKEN, { "x-forwarded-for": IP }));
  assert.deepEqual(scanned.opens.writes(), []);
  assert.equal(scanned.opened.length, 0);

  const head = setup({ docs: { [TOKEN]: sent() } });
  const res = await head.pixel(TOKEN, reader, "HEAD");
  assert.equal(res.statusCode, 200);
  assert.equal(res.headers["Content-Type"], "image/gif");
  assert.equal(res.body, undefined);
  assert.equal(head.opens.calls.length, 0);

  const post = await head.call({ method: "POST", path: `/o/${TOKEN}.gif`, headers: reader });
  assert.equal(post.statusCode, 405);
  assert.equal(head.opens.calls.length, 0);
});

test("a token holds at most MAX_EVENTS events", async () => {
  const { opens, opened, pixel, clock } = setup({ docs: { [TOKEN]: sent() } });
  for (let i = 0; i < MAX_EVENTS + 5; i += 1) {
    clock.now += 1000;
    assertIsThePixel(await pixel());
  }
  assert.equal(opens.docs.get(TOKEN).events.length, MAX_EVENTS);
  assert.equal(opened.length, MAX_EVENTS);
  assert.equal(MAX_EVENTS, 50);
});

test("a store that fails still answers the GIF, and the log names no token or address", async () => {
  const { opens, log, pixel } = setup({ docs: { [TOKEN]: sent() } });
  opens.append = async () => {
    throw Object.assign(new Error(`write failed for ${TOKEN} from ${IP}`), { code: 14 });
  };
  assertIsThePixel(await pixel());
  assert.deepEqual(log.lines, ["warn opens: pixel not recorded (14)"]);
});

test("no address, user agent or URL reaches the store, the notification or the log", async () => {
  for (const ranges of [fakeRanges(false), fakeRanges(true), fakeRanges(null)]) {
    const { opens, log, opened, call, pixel } = setup({ docs: { [TOKEN]: sent() }, ranges });
    await call({ path: "/v1/tokens", headers: { ...good, ...reader }, body: { token: TOKEN2 } });
    await pixel();
    await pixel(TOKEN, { ...reader, "user-agent": "Mozilla/5.0" });
    await call({ path: "/v1/opens", headers: { ...good, ...reader }, body: { tokens: [TOKEN, TOKEN2] } });
    await call({ method: "DELETE", path: "/v1/tokens", headers: { ...good, ...reader } });
    const kept = JSON.stringify({ calls: opens.calls, docs: [...opens.docs], opened, log: log.lines });
    for (const secret of [IP, "10.9.8.7", "SecretMailClient", "Mozilla", "AppleWebKit", "/o/", ".gif", EMAIL, "good"]) {
      assert.ok(!kept.includes(secret), `${secret} was kept: ${kept}`);
    }
    // And the log never carries a token.
    assert.ok(!log.lines.join("\n").includes(TOKEN) && !log.lines.join("\n").includes(TOKEN2));
  }
});

// ---- query

test("query returns the caller's tokens only, with label and time and nothing else", async () => {
  const { call } = setup({
    docs: {
      [TOKEN]: sent(undefined, { events: [{ label: "hidden", at: NOW - 5 }, { label: "opened", at: NOW - 1, extra: "x" }] }),
      [TOKEN2]: sent(undefined, { mailboxHash: OTHER_HASH, events: [{ label: "opened", at: NOW - 2 }] }),
    },
  });
  const unknown = "a".repeat(32);
  const res = await call({ path: "/v1/opens", headers: good, body: { tokens: [TOKEN, TOKEN2, unknown, "junk", 7, TOKEN] } });
  assert.equal(res.statusCode, 200);
  // Another mailbox's token is left out exactly like an unknown one.
  assert.deepEqual(res.body, { [TOKEN]: [{ label: "hidden", at: NOW - 5 }, { label: "opened", at: NOW - 1 }] });

  // A tracked message nobody opened is there, empty.
  const quiet = setup({ docs: { [TOKEN]: sent() } });
  assert.deepEqual((await quiet.call({ path: "/v1/opens", headers: good, body: { tokens: [TOKEN] } })).body, { [TOKEN]: [] });
});

test("query needs a Google token and takes at most MAX_QUERY tokens", async () => {
  const { opens, call } = setup({ docs: { [TOKEN]: sent() } });
  assert.equal((await call({ path: "/v1/opens", body: { tokens: [TOKEN] } })).statusCode, 401);
  assert.equal(opens.calls.length, 0);
  for (const tokens of [undefined, TOKEN, Array(MAX_QUERY + 1).fill(TOKEN)]) {
    assert.equal((await call({ path: "/v1/opens", headers: good, body: { tokens } })).statusCode, 400);
  }
  assert.equal((await call({ path: "/v1/opens", headers: good, body: { tokens: [] } })).statusCode, 200);
  assert.equal(MAX_QUERY, 100);
});

// ---- delete

test("delete removes the caller's mailbox and only that, and is 204 twice in a row", async () => {
  const { opens, call, pixel } = setup({
    docs: { [TOKEN]: sent(), ["b".repeat(32)]: sent(), [TOKEN2]: sent(undefined, { mailboxHash: OTHER_HASH }) },
  });
  assert.equal((await call({ method: "DELETE", path: "/v1/tokens" })).statusCode, 401);
  assert.equal(opens.docs.size, 3);

  const first = await call({ method: "DELETE", path: "/v1/tokens", headers: good });
  assert.equal(first.statusCode, 204);
  assert.deepEqual([...opens.docs.keys()], [TOKEN2]);
  const second = await call({ method: "DELETE", path: "/v1/tokens", headers: good });
  assert.equal(second.statusCode, 204);
  assert.deepEqual([...opens.docs.keys()], [TOKEN2]);

  // A pixel already sent now names an unknown token: the GIF, nothing kept.
  assertIsThePixel(await pixel());
  assert.deepEqual(opens.writes().filter((c) => c[0] === "append"), []);
});

test("anything else is 404", async () => {
  const { opens, call } = setup();
  for (const [method, path] of [["GET", "/"], ["GET", "/v1/tokens"], ["GET", "/v1/opens"], ["POST", "/v1/other"], ["PUT", "/v1/tokens"], ["GET", "/favicon.ico"]]) {
    assert.equal((await call({ method, path, headers: good })).statusCode, 404, `${method} ${path}`);
  }
  assert.equal(opens.calls.length, 0);
});
