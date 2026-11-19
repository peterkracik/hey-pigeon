// The `opens` function: read status for sent mail (docs/specs/read-status.md
// R20–R22). One HTTP function, four routes, free of I/O. `deps`:
//   opens:   { get, register, append, getMany, removeMailbox }  (src/opens.js)
//   auth:    { verify(bearer) → email | null }                   (src/auth.js)
//   ranges:  { contains(ip) → true | false | null }              (src/ranges.js)
//   publicUrl: where the pixel is served from, without a trailing slash;
//            "" to answer with the host the request came to
//   now:     () → epoch ms
//   onOpen:  (mailboxHash) → void — called after an event was stored. The
//            seam for the silent push of R24; nothing is wired to it yet.
//   log:     console-like
//
// Privacy contract. What this function stores, per tracked message: the
// token, sha256(mailbox address), and for each counted fetch a label and a
// time. It reads the fetching client's address and user agent to choose
// the label and passes them to nothing else: not the store, not `onOpen`,
// not the log. A pixel request writes no log line at all unless the store
// fails, and then only the error's code. The mailbox address is never
// stored. Tokens are not logged (a token is a capability to be counted).
//
// The pixel is public and anyone can ask for any token, so the unknown
// token is the cheap path: one document lookup, then the GIF. No write,
// no list load, no push, no log.

import { classify } from "./classify.js";
import { emailHash } from "./handlers.js";

/** Tokens live this long; Firestore's TTL deletes the document after it. */
export const TTL_MS = 30 * 24 * 60 * 60 * 1000;
/** Events kept per token; later fetches change nothing. */
export const MAX_EVENTS = 50;
/** Tokens one query may ask about. */
export const MAX_QUERY = 100;

const TOKEN_RE = /^[0-9a-f]{32}$/;
const PIXEL_RE = /^\/o\/([0-9a-f]{32})\.gif$/;

/** A transparent 1 × 1 GIF89a, 43 bytes. */
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
          if (label && doc.events.length < MAX_EVENTS) {
            const stored = await opens.append(token, { label, at }, MAX_EVENTS, at);
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

  /** POST /v1/tokens { token } — the app is about to send a tracked message. */
  async function register(req, res) {
    const hash = await mailbox(req, res);
    if (!hash) return;
    const token = typeof req.body?.token === "string" ? req.body.token.trim().toLowerCase() : "";
    if (!TOKEN_RE.test(token)) {
      res.status(400).json({ error: "token must be 32 hex digits" });
      return;
    }
    const outcome = await opens.register(token, hash, now(), TTL_MS);
    if (outcome === "taken") {
      res.status(409).json({ error: "token is in use" });
      return;
    }
    const base = publicUrl || `https://${req.get("host") ?? ""}`;
    log.info(`opens ${hash.slice(0, 8)} registered`);
    res.status(200).json({ pixelUrl: `${base}/o/${token}.gif` });
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
    if (path === "/v1/tokens" && req.method === "POST") return register(req, res);
    if (path === "/v1/tokens" && req.method === "DELETE") return removeAll(req, res);
    if (path === "/v1/opens" && req.method === "POST") return query(req, res);
    res.status(404).end();
  };
}
