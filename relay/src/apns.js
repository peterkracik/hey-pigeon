// APNs over HTTP/2 with a provider token (ES256 JWT signed with the .p8).
// Node 22's node:crypto does the ECDSA; no third-party JWT library.
//
// Both APNs hosts are kept warm: Xcode builds hold sandbox tokens,
// TestFlight / App Store builds production ones, and a token only works
// on the host it was issued for.

import http2 from "node:http2";
import { createPrivateKey, sign } from "node:crypto";

const HOSTS = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
};
const JWT_TTL_MS = 50 * 60 * 1000; // Apple: refresh at least hourly, not more than every 20 min
const REQUEST_TIMEOUT_MS = 10_000;

const b64url = (buf) => Buffer.from(buf).toString("base64url");

/** Build an APNs provider JWT. Exported for tests. */
export function signProviderToken({ keyPem, keyId, teamId, nowMs }) {
  const header = b64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = b64url(JSON.stringify({ iss: teamId, iat: Math.floor(nowMs / 1000) }));
  const data = `${header}.${claims}`;
  const key = createPrivateKey(keyPem);
  const sig = sign("sha256", Buffer.from(data), { key, dsaEncoding: "ieee-p1363" });
  return `${data}.${b64url(sig)}`;
}

export function createApns({ keyId, teamId, topic, loadKey, now = Date.now, connect = http2.connect }) {
  let keyPem = null;
  let jwt = null;
  let jwtIssuedAt = 0;
  const sessions = new Map();

  async function token() {
    if (jwt && now() - jwtIssuedAt < JWT_TTL_MS) return jwt;
    if (!keyPem) keyPem = await loadKey();
    jwtIssuedAt = now();
    jwt = signProviderToken({ keyPem, keyId, teamId, nowMs: jwtIssuedAt });
    return jwt;
  }

  function session(env) {
    const host = HOSTS[env] ?? HOSTS.production;
    let s = sessions.get(host);
    if (s && !s.closed && !s.destroyed) return s;
    s = connect(host);
    const drop = () => {
      if (sessions.get(host) === s) sessions.delete(host);
    };
    s.on("close", drop);
    s.on("goaway", drop);
    s.on("error", drop);
    sessions.set(host, s);
    return s;
  }

  return {
    /** Silent background push. Resolves {status, reason}; rejects on transport errors. */
    async send({ token: deviceToken, env, payload, collapseId }) {
      const bearer = await token();
      const headers = {
        ":method": "POST",
        ":path": `/3/device/${deviceToken}`,
        authorization: `bearer ${bearer}`,
        "apns-topic": topic,
        "apns-push-type": "background",
        "apns-priority": "5",
        // A wake that arrives hours late is useless: the app will have synced.
        "apns-expiration": String(Math.floor(now() / 1000) + 600),
        "content-type": "application/json",
      };
      if (collapseId) headers["apns-collapse-id"] = collapseId;

      return new Promise((resolve, reject) => {
        const req = session(env).request(headers);
        let status = 0;
        let body = "";
        const timer = setTimeout(() => {
          req.close(http2.constants.NGHTTP2_CANCEL);
          reject(Object.assign(new Error("apns timeout"), { code: "ETIMEDOUT" }));
        }, REQUEST_TIMEOUT_MS);
        req.setEncoding("utf8");
        req.on("response", (h) => {
          status = Number(h[":status"]);
        });
        req.on("data", (chunk) => {
          body += chunk;
        });
        req.on("end", () => {
          clearTimeout(timer);
          let reason;
          if (body) {
            try {
              reason = JSON.parse(body).reason;
            } catch {
              reason = undefined;
            }
          }
          resolve({ status, reason });
        });
        req.on("error", (e) => {
          clearTimeout(timer);
          reject(e);
        });
        req.end(JSON.stringify(payload));
      });
    },
  };
}
