// The `opens` function: read status for sent mail (docs/specs/read-status.md
// R20–R22). One HTTP function, four routes, free of I/O. `deps`:
//   opens:   { get, register, record, getMany, removeMailbox }  (src/opens.js)
//   auth:    { verify(bearer) → email | null }                   (src/auth.js)
//   ranges:  { contains(ip) → true | false | null }              (src/ranges.js)
//   publicUrl: where the pixel is served from (the custom domain), without
//            a trailing slash; "" while there is none — registration is
//            then refused, so no pixel ever names another host
//   now:     () → epoch ms
//   onOpen:  (mailboxHash) → void — called after an event was stored. The
//            seam for the silent push of R24; nothing is wired to it yet.
//   log:     console-like
//
// Privacy contract. What this function stores, per tracked message: the
// token, sha256(mailbox address), and for each counted fetch a label and a
// time. It reads the fetching client's address and user agent to choose
// the label and passes them to nothing else: not the store, not `onOpen`,
// not the log. The mailbox address is never stored.
//
// What this code logs: a mailbox hash prefix on register and delete, the
// state of Apple's list, and a failed store call's error code. Never a
// token, an address, a user agent, a URL or a request body. A pixel
// request that goes well logs nothing.
//
// What this code cannot answer for is what runs before it: the framework
// (Express and its body parser) rejects a request it cannot parse — a
// path with a broken %-escape, a body that is not JSON — without calling
// this handler, and prints the error, which quotes the path or a piece of
// the body. On an `opens` instance that printing is reduced to the
// error's class name (src/quiet.js, installed by index.js), so the
// sentence above holds for the whole process, not only for this file.
//
// The pixel is public and anyone can ask for any token, so the unknown
// token is the cheap path: one document lookup, then the GIF. No write,
// no list load, no push, no log.

import { classify } from "./classify.js";
import { emailHash } from "./handlers.js";

/** Tokens live this long; Firestore's TTL deletes the document after it. */
export const TTL_MS = 30 * 24 * 60 * 60 * 1000;
/**
 * Events kept per token and label. With two labels a token holds at most
 * 50; one label can never use the other's room.
 */
export const MAX_PER_LABEL = 25;
/** A fetch with the same label this soon after the last one adds nothing. */
export const REPEAT_MS = 60 * 1000;
/**
 * Live tokens one mailbox may hold. Gmail lets a consumer account send to
 * 500 recipients a day: 30 days of that, every message tracked, is 15,000.
 */
export const MAX_TOKENS_PER_MAILBOX = 20_000;

/**
 * The events of a token after one more counted fetch, or null when it adds
 * nothing. Pure.
 *
 * - The same label within `REPEAT_MS` of its last event: nothing. A mail
 *   client that asks three times while it renders, or someone reloading in
 *   a loop, is one open — and costs at most one write a minute.
 * - Otherwise appended, until the label holds `MAX_PER_LABEL`; from then on
 *   the newest replaces that label's last entry. So the first 24 and the
 *   latest of each label are always there: a recipient who fills "hidden"
 *   cannot push out a real "opened", and "last opened" stays true however
 *   often a message is read.
 */
export function nextEvents(events, label, at) {
  const same = events.filter((e) => e.label === label);
  const last = same[same.length - 1];
  if (last && at - last.at < REPEAT_MS) return null;
  if (same.length < MAX_PER_LABEL) return [...events, { label, at }];
  const out = events.slice();
  out[out.lastIndexOf(last)] = { label, at };
  return out;
}
/** Tokens one query may ask about. */
export const MAX_QUERY = 100;

const TOKEN_RE = /^[0-9a-f]{32}$/;
const PIXEL_RE = /^\/o\/([0-9a-f]{32})\.gif$/;

/** A transparent 1 × 1 GIF89a, 42 bytes. */
export const PIXEL = Buffer.from("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7", "base64");

/**
 * The address the request came from. Google's front end appends it to
 * `X-Forwarded-For`, so it is the last entry; anything before it was
 * written by the client.
 */
function clientAddress(req) {
  const forwarded = req.get("x-forwarded-for") ?? "";
  const last = forwarded.split(",").pop().trim();
  return last || req.ip || "";
}

export function createOpensHandler({ opens, auth, ranges, publicUrl = "", now = Date.now, onOpen, log = console }) {
  function sendPixel(req, res) {
    res
      .status(200)
      .set("Content-Type", "image/gif")
      .set("Content-Length", String(PIXEL.length))
      .set("Cache-Control", "no-store, no-cache, must-revalidate, private")
      .set("Pragma", "no-cache")
      .set("Expires", "0");
    if (req.method === "HEAD") res.end();
    else res.end(PIXEL);
  }

  /** GET /o/<token>.gif — always the GIF; a counted fetch of a known token is recorded first. */
  async function pixel(req, res, token) {
    try {
      // A HEAD is never a reader, and a malformed name is no token: neither
      // is worth a lookup.
      if (token && req.method === "GET") {
        const at = now();
        const doc = await opens.get(token, at);
        if (doc) {
          const label = classify({
            method: req.method,
            userAgent: req.get("user-agent") ?? "",
            fromApple: await ranges.contains(clientAddress(req)),
            ageMs: at - doc.createdAt,
          });
          // Checked on the copy just read, so a repeat costs no write;
          // decided again inside the store's transaction.
          if (label && nextEvents(doc.events, label, at)) {
            const stored = await opens.record(token, (events) => nextEvents(events, label, at), at);
            if (stored && onOpen) await onOpen(doc.mailboxHash);
          }
        }
      }
    } catch (e) {
      // The recipient's mail app gets its picture whatever happened here.
      log.warn(`opens: pixel not recorded (${e?.code ?? e?.name ?? "error"})`);
    }
    sendPixel(req, res);
  }

  /** The caller's mailbox hash, or null after answering 401 / 502. */
  async function mailbox(req, res) {
    const authz = req.get("authorization") ?? "";
    const bearer = authz.startsWith("Bearer ") ? authz.slice(7).trim() : "";
    if (!bearer) {
      res.status(401).json({ error: "missing bearer token" });
      return null;
    }
    let email;
    try {
      email = await auth.verify(bearer);
    } catch (e) {
      log.warn(`opens: tokeninfo failed ${e?.message ?? e}`);
      res.status(502).json({ error: "token verification unavailable" });
      return null;
    }
    if (!email) {
      res.status(401).json({ error: "token rejected" });
      return null;
    }
    return emailHash(email);
  }

  /**
   * The three routes the app calls, with a failing store answered as the
   * pixel route answers it: a line with the error's code, and here a 503
   * that says nothing more. Left to the framework, the rejection would be
   * logged with its stack, its message sent to the caller, and the
   * instance shut down.
   */
  function guarded(name, route) {
    return async (req, res) => {
      try {
        await route(req, res);
      } catch (e) {
        log.warn(`opens: ${name} failed (${e?.code ?? e?.name ?? "error"})`);
        if (!res.headersSent) res.status(503).json({ error: "unavailable" });
      }
    };
  }

  /** POST /v1/tokens { token } — the app is about to send a tracked message. */
  async function register(req, res) {
    const hash = await mailbox(req, res);
    if (!hash) return;
    const token = typeof req.body?.token === "string" ? req.body.token.trim().toLowerCase() : "";
    if (!TOKEN_RE.test(token)) {
      res.status(400).json({ error: "token must be 32 hex digits" });
      return;
    }
    // Without a pixel host there is no address to put in a message, and
    // the one this request came to (a run.app URL) must never be it.
    // Refused before anything is stored.
    if (!publicUrl) {
      res.status(503).json({ error: "read status is not set up on this relay" });
      return;
    }
    const outcome = await opens.register(token, hash, now(), TTL_MS, MAX_TOKENS_PER_MAILBOX);
    if (outcome === "taken") {
      res.status(409).json({ error: "token is in use" });
      return;
    }
    if (outcome === "full") {
      log.warn(`opens ${hash.slice(0, 8)} at its token limit`);
      res.status(429).json({ error: `this mailbox already tracks ${MAX_TOKENS_PER_MAILBOX} messages` });
      return;
    }
    log.info(`opens ${hash.slice(0, 8)} registered`);
    res.status(200).json({ pixelUrl: `${publicUrl}/o/${token}.gif` });
  }

  /** DELETE /v1/tokens — read status was turned off for this mailbox. Idempotent. */
  async function removeAll(req, res) {
    const hash = await mailbox(req, res);
    if (!hash) return;
    const removed = await opens.removeMailbox(hash);
    log.info(`opens ${hash.slice(0, 8)} deleted ${removed}`);
    res.status(204).end();
  }

  /** POST /v1/opens { tokens } — the events of the caller's own tokens. */
  async function query(req, res) {
    const hash = await mailbox(req, res);
    if (!hash) return;
    const asked = req.body?.tokens;
    if (!Array.isArray(asked) || asked.length > MAX_QUERY) {
      res.status(400).json({ error: `tokens must be a list of at most ${MAX_QUERY}` });
      return;
    }
    const tokens = [...new Set(asked.filter((t) => typeof t === "string").map((t) => t.toLowerCase()))].filter((t) =>
      TOKEN_RE.test(t),
    );
    const found = await opens.getMany(tokens, now());
    const out = {};
    // A token is in the HTML every recipient got, so holding one proves
    // nothing: another mailbox's token is left out exactly like an unknown
    // one.
    for (const [token, doc] of found) {
      if (doc.mailboxHash !== hash) continue;
      out[token] = doc.events.map((e) => ({ label: e.label, at: e.at }));
    }
    res.status(200).json(out);
  }

  return async function opensHandler(req, res) {
    const path = req.path ?? "";
    if (path.startsWith("/o/")) {
      if (req.method !== "GET" && req.method !== "HEAD") {
        res.set("Allow", "GET, HEAD").status(405).end();
        return;
      }
      await pixel(req, res, PIXEL_RE.exec(path)?.[1] ?? null);
      return;
    }
    if (path === "/v1/tokens" && req.method === "POST") return guarded("register", register)(req, res);
    if (path === "/v1/tokens" && req.method === "DELETE") return guarded("delete", removeAll)(req, res);
    if (path === "/v1/opens" && req.method === "POST") return guarded("query", query)(req, res);
    res.status(404).end();
  };
}
