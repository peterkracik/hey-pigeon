import { test } from "node:test";
import assert from "node:assert/strict";

import { createAppleRanges, inRanges, parseRanges, parseV4, parseV6 } from "../src/ranges.js";
import { silentLog } from "./helpers.js";

// The published file's shape: CIDR, country, region, city, then nothing.
const CSV = [
  "172.224.224.0/31,GB,GB-EN,London,",
  "172.224.224.2/31,GB,GB-EN,London,",
  "104.28.0.0/24,US,US-CA,Los Angeles,",
  "2a02:26f7:b000:4000::/64,CH,CH-ZH,Zurich,",
  "2606:54c0:76a0:1238::/45,US,US-NY,New York,",
  "not a range,,,,",
  "",
].join("\n");

test("addresses are read", () => {
  assert.equal(parseV4("1.2.3.4"), 0x01020304);
  assert.equal(parseV4("255.255.255.255"), 0xffffffff);
  for (const bad of ["1.2.3", "1.2.3.256", "a.b.c.d", "", "1.2.3.4.5"]) assert.equal(parseV4(bad), null, bad);
  assert.equal(parseV6("::1"), 1n);
  assert.equal(parseV6("2a02:26f7:b000:4000::"), 0x2a0226f7b00040000000000000000000n);
  assert.equal(parseV6("2A02:26F7:B000:4000:0:0:0:1"), 0x2a0226f7b00040000000000000000001n);
  assert.equal(parseV6("::ffff:1.2.3.4"), 0xffff01020304n);
  for (const bad of ["1.2.3.4", "2a02::1::2", "2a02:xyz::", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9"]) {
    assert.equal(parseV6(bad), null, bad);
  }
});

test("ranges are parsed, merged and searched", () => {
  const ranges = parseRanges(CSV);
  // The two /31s touch: one range.
  assert.equal(ranges.v4.length, 2);
  assert.equal(ranges.v6.length, 2);
  for (const inside of [
    "172.224.224.0",
    "172.224.224.3",
    "104.28.0.255",
    "::ffff:104.28.0.7",
    "2a02:26f7:b000:4000::1",
    "2a02:26f7:b000:4000:ffff:ffff:ffff:ffff",
    "2606:54c0:76a7:ffff::9",
  ]) {
    assert.equal(inRanges(ranges, inside), true, inside);
  }
  for (const outside of [
    "172.224.224.4",
    "104.28.1.0",
    "104.27.255.255",
    "8.8.8.8",
    "2a02:26f7:b000:4001::1",
    "2606:54c0:76a8::1",
    "",
    "garbage",
    undefined,
  ]) {
    assert.equal(inRanges(ranges, outside), false, String(outside));
  }
});

test("a damaged prefix is not a range, and a range too wide to be Apple's marks the file", () => {
  // `Number("")` is 0 and `Number("1e1")` is 10: neither may become a range.
  for (const line of ["1.2.3.4/,US", "1.2.3.4/1e1,US", "1.2.3.4/ 24,US", "1.2.3.4/-1,US", "1.2.3.4/33,US", "1.2.3.4/0x18,US", "2a02::/129,CH", "2a02::/,CH", "1.2.3.4/24x,US"]) {
    const parsed = parseRanges(line);
    assert.equal(parsed.v4.length + parsed.v6.length, 0, line);
    assert.equal(parsed.implausible, false, line);
    assert.equal(inRanges(parsed, "8.8.8.8"), false, line);
  }
  assert.equal(parseRanges(CSV).implausible, false);
  for (const wide of ["0.0.0.0/0,,,,", "10.0.0.0/7,,,,", "::/0,,,,", "2000::/3,,,,"]) {
    assert.equal(parseRanges(`${CSV}\n${wide}`).implausible, true, wide);
  }
  assert.equal(parseRanges("17.0.0.0/8,US").implausible, false);
});

test("a file with a range that covers everything is a failed load, and is not announced as loaded", async () => {
  for (const poisoned of [`${CSV}\n0.0.0.0/0,,,,`, `${CSV}\n::/0,,,,`, "1.2.3.4/,US"]) {
    const log = silentLog();
    const ranges = createAppleRanges({ fetchImpl: async () => ({ ok: true, text: async () => poisoned }), log });
    // null, not true: the classifier falls back to the user agent.
    assert.equal(await ranges.contains("8.8.8.8"), null);
    assert.equal(await ranges.contains("104.28.0.9"), null);
    assert.equal(log.lines.length, 1);
    assert.match(log.lines[0], /^warn opens: apple ranges unavailable/);
    assert.ok(!log.lines.join("\n").includes("loaded"));
  }
});

test("the list is fetched once and then answers from memory", async () => {
  let fetched = 0;
  const ranges = createAppleRanges({
    fetchImpl: async () => {
      fetched += 1;
      return { ok: true, text: async () => CSV };
    },
    log: silentLog(),
  });
  const [a, b] = await Promise.all([ranges.contains("104.28.0.9"), ranges.contains("8.8.8.8")]);
  assert.equal(a, true);
  assert.equal(b, false);
  assert.equal(await ranges.contains("2a02:26f7:b000:4000::2"), true);
  assert.equal(fetched, 1);
});

test("a list that cannot be loaded answers null, says so without an address, and is tried again later", async () => {
  for (const failure of [
    async () => {
      throw new Error("network down");
    },
    async () => ({ ok: false, status: 503 }),
    async () => ({ ok: true, text: async () => "<html>not the list</html>" }),
  ]) {
    let fetched = 0;
    let clock = 1_000_000;
    let fail = true;
    const log = silentLog();
    const ranges = createAppleRanges({
      fetchImpl: async () => {
        fetched += 1;
        return fail ? failure() : { ok: true, text: async () => CSV };
      },
      now: () => clock,
      log,
    });
    assert.equal(await ranges.contains("104.28.0.9"), null);
    assert.equal(await ranges.contains("104.28.0.9"), null);
    assert.equal(fetched, 1, "no second attempt inside the retry pause");
    assert.equal(log.lines.length, 1);
    assert.match(log.lines[0], /^warn opens: apple ranges unavailable/);
    assert.ok(!log.lines.join("\n").includes("104.28.0.9"));
    // Five minutes on, Apple answers.
    clock += 5 * 60 * 1000;
    fail = false;
    assert.equal(await ranges.contains("104.28.0.9"), true);
    assert.equal(fetched, 2);
  }
});
