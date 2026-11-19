// What a fetch of the pixel means, decided in memory from the request
// alone. Pure: no I/O, no clock, nothing kept.
//
//   opened   Gmail's image proxy, or a mail client / browser asking directly
//   hidden   Apple's mail privacy proxy: the mail reached a device that
//            hides opens. Never shown or counted as opened.
//   null     ignored — nothing is stored: a HEAD, a fetch inside the grace
//            window after the message was sent (the sender's own Sent
//            folder, a gateway scanning on delivery), a scanner or a script
//
// The source address and the user agent are inputs here and nowhere else:
// the handler passes them in and forgets them (docs/specs/read-status.md
// R21). Only the label leaves this function.

/** Fetches this soon after registration are not a person reading. */
export const GRACE_MS = 2 * 60 * 1000;

/** Gmail fetches every picture through this proxy, when the reader opens the mail. */
const GMAIL_PROXY = /GoogleImageProxy/i;

/**
 * Apple's mail privacy proxy sends exactly this and nothing more. It is
 * the fallback signal when Apple's egress list could not be loaded, and a
 * second one when it could.
 */
const BARE_MOZILLA = /^Mozilla\/5\.0$/;

/** Security gateways, link checkers, scripts: not a reader. */
const SCANNER =
  /bot\b|crawler|spider|scanner|proofpoint|mimecast|barracuda|symantec|forcepoint|trendmicro|fireeye|sophos|python|curl|wget|go-http-client|libwww|java\//i;

/**
 * @param {object} fetch
 * @param {string} fetch.method     the request method
 * @param {string} fetch.userAgent  the User-Agent header ("" when absent)
 * @param {boolean|null} fetch.fromApple  the source address is inside Apple's
 *   published egress ranges; null when the list could not be loaded
 * @param {number} fetch.ageMs      time since the token was registered
 * @returns {"opened"|"hidden"|null}
 */
export function classify({ method, userAgent, fromApple, ageMs }) {
  if (method !== "GET") return null;
  if (!(ageMs >= GRACE_MS)) return null;
  const ua = (userAgent ?? "").trim();
  if (GMAIL_PROXY.test(ua)) return "opened";
  // Apple first, scanners second: the proxy's bare user agent must not be
  // read as "no user agent, so a script".
  if (fromApple === true || BARE_MOZILLA.test(ua)) return "hidden";
  if (ua === "" || SCANNER.test(ua)) return null;
  // Without Apple's list (fromApple === null) this is still safe to call
  // opened: the proxy never sends a user agent that names a mail client or
  // a browser, so what is left here can be told from it.
  return "opened";
}
