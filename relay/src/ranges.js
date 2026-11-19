// Apple's published egress ranges (the addresses iCloud Private Relay and
// Mail Privacy Protection fetch from), loaded once per instance.
//
// Fetched at cold start rather than bundled: the list is some hundreds of
// thousands of lines and changes weekly, and a stale copy in the zip would
// quietly turn Apple's proxy into "opened". Loaded lazily, on the first
// fetch of a *known* token — an unknown one never costs more than its
// lookup.
//
// When it cannot be loaded (Apple unreachable, a timeout, an empty or
// unparseable answer), `contains` answers null — "unknown", never false —
// and the classifier falls back to the user agent, where Apple's proxy is
// still recognised and still labelled hidden (classify.js). The failure is
// logged once per attempt, without an address, and the load is tried again
// after `RETRY_MS`.

export const APPLE_EGRESS_URL = "https://mask-api.icloud.com/egress-ip-ranges.csv";
const LOAD_TIMEOUT_MS = 4000;
const RETRY_MS = 5 * 60 * 1000;

/** "1.2.3.4" → 32-bit number, or null. */
export function parseV4(text) {
  const parts = text.split(".");
  if (parts.length !== 4) return null;
  let n = 0;
  for (const p of parts) {
    if (!/^\d{1,3}$/.test(p)) return null;
    const v = Number(p);
    if (v > 255) return null;
    n = n * 256 + v;
  }
  return n;
}

/** An IPv6 address → 128-bit BigInt, or null. `::` and a v4 tail are read. */
export function parseV6(text) {
  let s = text.trim().toLowerCase();
  const zone = s.indexOf("%");
  if (zone >= 0) s = s.slice(0, zone);
  if (!s.includes(":")) return null;
  const lastColon = s.lastIndexOf(":");
  const tail = s.slice(lastColon + 1);
  if (tail.includes(".")) {
    const v4 = parseV4(tail);
    if (v4 === null) return null;
    s = `${s.slice(0, lastColon + 1)}${(v4 >>> 16).toString(16)}:${(v4 & 0xffff).toString(16)}`;
  }
  const halves = s.split("::");
  if (halves.length > 2) return null;
  const head = halves[0] ? halves[0].split(":") : [];
  const rest = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
  const missing = 8 - head.length - rest.length;
  if (halves.length === 1 ? missing !== 0 : missing < 1) return null;
  const groups = [...head, ...Array(halves.length === 2 ? missing : 0).fill("0"), ...rest];
  let n = 0n;
  for (const g of groups) {
    if (!/^[0-9a-f]{1,4}$/.test(g)) return null;
    n = (n << 16n) | BigInt(parseInt(g, 16));
  }
  return n;
}

/** `::ffff:1.2.3.4` is the v4 address 1.2.3.4. */
function normalise(ip) {
  const s = String(ip ?? "").trim();
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(s);
  return mapped ? mapped[1] : s;
}

/**
 * The CSV as published: `CIDR,country,region,city,…` per line. Lines that
 * are not a CIDR are skipped. Returns sorted, merged ranges per family.
 */
export function parseRanges(csv) {
  const v4 = [];
  const v6 = [];
  for (const line of csv.split("\n")) {
    const cidr = line.slice(0, line.indexOf(",") >= 0 ? line.indexOf(",") : line.length).trim();
    const slash = cidr.indexOf("/");
    if (slash < 0) continue;
    const bits = Number(cidr.slice(slash + 1));
    const addr = cidr.slice(0, slash);
    if (!Number.isInteger(bits) || bits < 0) continue;
    if (addr.includes(":")) {
      const n = parseV6(addr);
      if (n === null || bits > 128) continue;
      const size = 1n << BigInt(128 - bits);
      const start = (n / size) * size;
      v6.push([start, start + size - 1n]);
    } else {
      const n = parseV4(addr);
      if (n === null || bits > 32) continue;
      const size = 2 ** (32 - bits);
      const start = Math.floor(n / size) * size;
      v4.push([start, start + size - 1]);
    }
  }
  return { v4: merge(v4, 1), v6: merge(v6, 1n) };
}

function merge(ranges, one) {
  ranges.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  const out = [];
  for (const r of ranges) {
    const last = out[out.length - 1];
    if (last && r[0] <= last[1] + one) {
      if (r[1] > last[1]) last[1] = r[1];
    } else {
      out.push([r[0], r[1]]);
    }
  }
  return out;
}

function within(ranges, n) {
  let lo = 0;
  let hi = ranges.length - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (n < ranges[mid][0]) hi = mid - 1;
    else if (n > ranges[mid][1]) lo = mid + 1;
    else return true;
  }
  return false;
}

/** Is `ip` inside `ranges` (from `parseRanges`)? False for anything unreadable. */
export function inRanges(ranges, ip) {
  const s = normalise(ip);
  if (s.includes(":")) {
    const n = parseV6(s);
    return n !== null && within(ranges.v6, n);
  }
  const n = parseV4(s);
  return n !== null && within(ranges.v4, n);
}

/**
 * @returns {{ contains(ip: string): Promise<boolean|null> }} true / false
 *   once the list is loaded, null while it is not.
 */
export function createAppleRanges({
  fetchImpl = globalThis.fetch,
  url = APPLE_EGRESS_URL,
  now = Date.now,
  log = console,
  timeoutMs = LOAD_TIMEOUT_MS,
} = {}) {
  let ranges = null;
  let loading = null;
  let retryAt = 0;

  async function load() {
    try {
      const res = await fetchImpl(url, { signal: AbortSignal.timeout(timeoutMs) });
      if (!res.ok) throw new Error(`status ${res.status}`);
      const parsed = parseRanges(await res.text());
      if (parsed.v4.length + parsed.v6.length === 0) throw new Error("no ranges in the answer");
      ranges = parsed;
      log.info(`opens: apple ranges loaded (${parsed.v4.length} v4, ${parsed.v6.length} v6)`);
    } catch (e) {
      retryAt = now() + RETRY_MS;
      log.warn(`opens: apple ranges unavailable (${e?.name ?? "error"}: ${e?.message ?? e}) — classifying by user agent`);
    } finally {
      loading = null;
    }
  }

  return {
    async contains(ip) {
      if (!ranges && now() >= retryAt) {
        loading ??= load();
        await loading;
      }
      return ranges ? inRanges(ranges, ip) : null;
    },
  };
}
