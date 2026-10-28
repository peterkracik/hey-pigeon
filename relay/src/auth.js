// Who is calling `register-token`? The phone sends the Google access token
// it already holds for the mailbox; Google's tokeninfo endpoint tells us
// which account and which OAuth client it belongs to. No new login, and
// only the mailbox owner can write that mailbox's tokens.

const TOKENINFO = "https://oauth2.googleapis.com/tokeninfo";

export function createAuth({ clientIds, fetchImpl = globalThis.fetch }) {
  const allowed = new Set(clientIds);

  return {
    /** Resolves to the verified email, or null when the token is not acceptable. */
    async verify(accessToken) {
      if (!accessToken || allowed.size === 0) return null;
      const url = `${TOKENINFO}?access_token=${encodeURIComponent(accessToken)}`;
      const res = await fetchImpl(url);
      if (!res.ok) return null;
      const info = await res.json();
      return acceptTokenInfo(info, allowed);
    },
  };
}

/** Pure check over a tokeninfo document. Exported for tests. */
export function acceptTokenInfo(info, allowed) {
  if (!info || typeof info !== "object") return null;
  if (!allowed.has(info.aud) && !allowed.has(info.azp)) return null;
  if (info.email_verified !== "true" && info.email_verified !== true) return null;
  if (typeof info.email !== "string" || !info.email.includes("@")) return null;
  const scope = typeof info.scope === "string" ? info.scope : "";
  if (!scope.includes("gmail")) return null;
  return info.email;
}
