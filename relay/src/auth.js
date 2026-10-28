// Who is calling `register-token`? The phone sends the Google access token
// it already holds for the mailbox. Two lookups, both with that token:
//   1. tokeninfo — is this token ours (issued to one of our OAuth clients)
//      and does it carry a Gmail scope?
//   2. Gmail users/me/profile — which mailbox is it for. (tokeninfo only
//      returns an email when the grant has the `userinfo.email` scope, which
//      the app does not ask for; the Gmail profile needs only the scope it
//      already has — the same call the Rust core makes.)
// No new login, and only the mailbox owner can write that mailbox's tokens.

const TOKENINFO = "https://oauth2.googleapis.com/tokeninfo";
const GMAIL_PROFILE = "https://gmail.googleapis.com/gmail/v1/users/me/profile";

export function createAuth({ clientIds, fetchImpl = globalThis.fetch, log = console }) {
  const allowed = new Set(clientIds);

  return {
    /** Resolves to the verified email, or null when the token is not acceptable. */
    async verify(accessToken) {
      if (!accessToken) return null;
      if (allowed.size === 0) {
        log.warn("register: GOOGLE_CLIENT_IDS is empty — every token is rejected");
        return null;
      }
      const url = `${TOKENINFO}?access_token=${encodeURIComponent(accessToken)}`;
      const res = await fetchImpl(url);
      if (!res.ok) {
        log.warn(`register: tokeninfo ${res.status} (expired or malformed token)`);
        return null;
      }
      const info = await res.json();
      const why = rejectReason(info, allowed);
      if (why) {
        // The client id is public (it ships in the app); logging it is what
        // makes a mismatch with GOOGLE_CLIENT_IDS diagnosable.
        log.warn(`register: token rejected — ${why}`);
        return null;
      }
      if (typeof info.email === "string" && info.email.includes("@")) return info.email;

      const prof = await fetchImpl(GMAIL_PROFILE, { headers: { authorization: `Bearer ${accessToken}` } });
      if (!prof.ok) {
        log.warn(`register: gmail profile ${prof.status}`);
        return null;
      }
      const profile = await prof.json();
      const email = profile?.emailAddress;
      return typeof email === "string" && email.includes("@") ? email : null;
    },
  };
}

/**
 * Pure check over a tokeninfo document: null when acceptable, else a short
 * reason. Exported for tests.
 */
export function rejectReason(info, allowed) {
  if (!info || typeof info !== "object") return "no tokeninfo";
  if (!allowed.has(info.aud) && !allowed.has(info.azp)) {
    return `aud ${info.aud ?? "?"} not in GOOGLE_CLIENT_IDS`;
  }
  if (info.email_verified !== undefined && info.email_verified !== "true" && info.email_verified !== true) {
    return "email not verified";
  }
  const scope = typeof info.scope === "string" ? info.scope : "";
  if (!scope.includes("gmail")) return "no gmail scope";
  return null;
}

/** Kept for callers that only need the yes/no: the email from tokeninfo, or null. */
export function acceptTokenInfo(info, allowed) {
  if (rejectReason(info, allowed)) return null;
  return typeof info.email === "string" && info.email.includes("@") ? info.email : null;
}
