// The two functions, free of I/O. `deps`:
//   tokens: { get(hash) → [{token, env, platform, updatedAt}], upsert(hash, entry), remove(hash, token) }
//   apns:   { send({token, env, payload, collapseId}) → {status, reason} }
//   auth:   { verify(bearer) → email | null }
//   topic:  the Pub/Sub topic the app should `users.watch`
//   log:    console-like
//
// Privacy contract (DESIGN.md "Push notifications", tier 3): the relay
// learns `email → device tokens` and, per event, `email + historyId`.
// Log lines carry a hash prefix and an APNs status, never an address or
// a payload.

import { createHash } from "node:crypto";

export const ENVIRONMENTS = new Set(["sandbox", "production"]);
// APNs tokens are 32 bytes today; Apple says treat the length as opaque.
const TOKEN_RE = /^[0-9a-f]{32,400}$/i;

export function emailHash(email) {
  return createHash("sha256").update(email.trim().toLowerCase()).digest("hex");
}

export function decodePubsub(cloudEvent) {
  const data = cloudEvent?.data?.message?.data;
  if (!data) return null;
  let parsed;
  try {
    parsed = JSON.parse(Buffer.from(data, "base64").toString("utf8"));
  } catch {
    return null;
  }
  const { emailAddress, historyId } = parsed ?? {};
  if (typeof emailAddress !== "string" || !emailAddress.includes("@")) return null;
  if (historyId === undefined || historyId === null) return null;
  return { emailAddress, historyId: String(historyId) };
}

export function createHandlers({ tokens, apns, auth, topic, log = console }) {
  async function onMailChange(cloudEvent) {
    const change = decodePubsub(cloudEvent);
    if (!change) {
      log.warn("push: undecodable Pub/Sub message, dropped");
      return;
    }
    const hash = emailHash(change.emailAddress);
    const devices = await tokens.get(hash);
    // Anyone who knows the topic name can `watch` their own mailbox into
    // it. Unknown addresses are a silent no-op — no log, no record.
    if (!devices.length) return;

    const payload = {
      aps: { "content-available": 1 },
      email: change.emailAddress,
      historyId: change.historyId,
    };
    const collapseId = hash.slice(0, 16);
    for (const d of devices) {
      let result;
      try {
        result = await apns.send({ token: d.token, env: d.env, payload, collapseId });
      } catch (e) {
        log.warn(`push ${hash.slice(0, 8)} ${d.env}: transport error ${e?.code ?? e?.message ?? e}`);
        continue;
      }
      log.info(`push ${hash.slice(0, 8)} ${d.env} ${result.status}${result.reason ? " " + result.reason : ""}`);
      // 410 = the device is gone for this topic. A 400 BadDeviceToken is
      // usually a sandbox token on the production host (or vice versa) and
      // must not delete anything.
      if (result.status === 410) {
        await tokens.remove(hash, d.token);
      }
    }
  }

  async function registerToken(req, res) {
    if (req.method !== "POST" && req.method !== "DELETE") {
      res.set("Allow", "POST, DELETE").status(405).end();
      return;
    }
    const authz = req.get("authorization") ?? "";
    const bearer = authz.startsWith("Bearer ") ? authz.slice(7).trim() : "";
    if (!bearer) {
      res.status(401).json({ error: "missing bearer token" });
      return;
    }
    let email;
    try {
      email = await auth.verify(bearer);
    } catch (e) {
      log.warn(`register: tokeninfo failed ${e?.message ?? e}`);
      res.status(502).json({ error: "token verification unavailable" });
      return;
    }
    if (!email) {
      res.status(401).json({ error: "token rejected" });
      return;
    }
    const body = typeof req.body === "object" && req.body ? req.body : {};
    const deviceToken = typeof body.deviceToken === "string" ? body.deviceToken.trim() : "";
    if (!TOKEN_RE.test(deviceToken)) {
      res.status(400).json({ error: "deviceToken must be a hex string" });
      return;
    }
    const hash = emailHash(email);

    if (req.method === "DELETE") {
      await tokens.remove(hash, deviceToken);
      res.status(204).end();
      return;
    }

    if (body.platform !== "ios") {
      res.status(400).json({ error: "platform must be ios" });
      return;
    }
    if (!ENVIRONMENTS.has(body.environment)) {
      res.status(400).json({ error: "environment must be sandbox or production" });
      return;
    }
    await tokens.upsert(hash, { token: deviceToken, env: body.environment, platform: "ios" });
    res.status(200).json({ topic });
  }

  return { onMailChange, registerToken };
}
