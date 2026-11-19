// The silent push that tells a phone "something of yours was opened", so
// it asks the relay now instead of at its next sync
// (docs/specs/read-status.md R24). `createOpenPush(deps)` returns the
// `onOpen(mailboxHash)` the opens handler calls after it stored an
// `opened` event. `deps`:
//   tokens: the device-token table (src/tokens.js) — the same one push uses
//   apns:   { send({token, env, payload, collapseId}) → {status, reason} }
//   now:    () → epoch ms
//   log:    console-like
//
// What goes to Apple and on to the phone is `PAYLOAD` and nothing else:
// no address, no token, no message, no subject, no count. It says only
// that the mailbox this device registered has an open to ask about; the
// phone then runs its ordinary sync round and asks the relay itself, with
// its Google token. A device gets it only if it registered for "New mail
// (push)"; a mailbox with no registered device is a no-op, without a log
// line.
//
// The pixel is public, so this must not be a way to make a phone buzz:
//   - it is only reached for a fetch that *stored* an `opened` event, and
//     the handler stores at most one of those a minute per message;
//   - at most one push per mailbox per `WINDOW_MS`, whatever the number of
//     messages opened (a newsletter to two hundred people read in the
//     same minute is one wake, not two hundred). Kept in memory: no write
//     on the public path. An instance each has its own memory, and there
//     are at most three, so the true bound is three a minute; Apple
//     collapses what is still queued (the collapse id) and throttles
//     background pushes to a few an hour on its side anyway;
//   - it never fails the pixel and never holds it long: the caller gets
//     its answer after `BUDGET_MS` at the latest. It is awaited, not left
//     running behind the response — the function's CPU is only guaranteed
//     while a request is in flight.

/** The whole push. Frozen: nothing can be added to it on the way out. */
export const PAYLOAD = Object.freeze({ aps: Object.freeze({ "content-available": 1 }), opens: 1 });

/** At most one push per mailbox in this long (per instance). */
export const WINDOW_MS = 60 * 1000;
/** The longest the pixel's answer waits for Apple. */
export const BUDGET_MS = 1500;
/** Mailboxes remembered before the oldest are forgotten. */
const REMEMBERED = 2000;

export function createOpenPush({ tokens, apns, now = Date.now, log = console, budgetMs = BUDGET_MS }) {
  /** mailbox hash → when it was last pushed. */
  const last = new Map();

  function due(hash, at) {
    const before = last.get(hash);
    if (before !== undefined && at - before < WINDOW_MS && at >= before) return false;
    // Re-inserted, so the map stays in order of use and the oldest can go.
    last.delete(hash);
    last.set(hash, at);
    if (last.size > REMEMBERED) last.delete(last.keys().next().value);
    return true;
  }

  async function push(hash) {
    const devices = await tokens.get(hash);
    if (!devices.length) return;
    // Its own collapse id: a queued "opened" wake never replaces a queued
    // "new mail" wake for the same mailbox, or the other way round.
    const collapseId = `o${hash.slice(0, 15)}`;
    for (const d of devices) {
      let result;
      try {
        result = await apns.send({ token: d.token, env: d.env, payload: PAYLOAD, collapseId });
      } catch (e) {
        log.warn(`open-push ${hash.slice(0, 8)} ${d.env}: transport error ${e?.code ?? e?.name ?? "error"}`);
        continue;
      }
      log.info(`open-push ${hash.slice(0, 8)} ${d.env} ${result.status}${result.reason ? " " + result.reason : ""}`);
      // 410 = the device is gone for this topic (as in onMailChange).
      if (result.status === 410) await tokens.remove(hash, d.token);
    }
  }

  /** Never throws, never takes longer than the budget. */
  return async function onOpen(mailboxHash) {
    if (typeof mailboxHash !== "string" || !mailboxHash) return;
    if (!due(mailboxHash, now())) return;
    let timer;
    const budget = new Promise((resolve) => {
      timer = setTimeout(resolve, budgetMs, "late");
    });
    const work = push(mailboxHash).catch((e) => {
      log.warn(`open-push ${mailboxHash.slice(0, 8)}: ${e?.code ?? e?.name ?? "error"}`);
    });
    const outcome = await Promise.race([work, budget]);
    clearTimeout(timer);
    if (outcome === "late") log.info(`open-push ${mailboxHash.slice(0, 8)}: not waited for`);
  };
}
