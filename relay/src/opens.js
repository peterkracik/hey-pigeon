// Firestore-backed table of tracked messages:
//   opens/{token} → { mailboxHash, createdAt, expiresAt, events: [{label, at}] }
// The token is 128 random bits made by the app; `mailboxHash` is
// sha256(address) as in the device-token table — the address itself is not
// stored. `expiresAt` is a timestamp field with a Firestore TTL policy on
// it (terraform/firestore.tf): the document is deleted about 30 days after
// registration. TTL deletion can lag by a day, so readers check the field
// themselves and treat an expired document as absent.

import { Timestamp } from "@google-cloud/firestore";

const COLLECTION = "opens";

function live(snap, nowMs) {
  if (!snap.exists) return null;
  const d = snap.data() ?? {};
  const expiresAt = d.expiresAt?.toMillis?.() ?? 0;
  if (expiresAt <= nowMs) return null;
  return {
    mailboxHash: d.mailboxHash,
    createdAt: Number(d.createdAt) || 0,
    events: Array.isArray(d.events) ? d.events : [],
  };
}

export function createOpenStore(db) {
  const col = db.collection(COLLECTION);

  return {
    /** The live document for `token`, or null (absent or expired). One read. */
    async get(token, nowMs) {
      return live(await col.doc(token).get(), nowMs);
    },

    /**
     * Create the document. "created", "exists" (same mailbox, still live: a
     * retried registration), "taken" (the token is another mailbox's) or
     * "full" (the mailbox already holds `maxPerMailbox` documents).
     *
     * "taken" also when the other mailbox's document has expired and is
     * only waiting for the TTL sweep: a token must never change hands, or
     * the new owner would be told of fetches of the old owner's mail.
     */
    async register(token, mailboxHash, nowMs, ttlMs, maxPerMailbox) {
      const ref = col.doc(token);
      // Counted outside the transaction: a cap that two racing sends can
      // overshoot by one is still a cap.
      const held = await col.where("mailboxHash", "==", mailboxHash).count().get();
      return db.runTransaction(async (tx) => {
        const snap = await tx.get(ref);
        if (snap.exists && snap.data()?.mailboxHash !== mailboxHash) return "taken";
        if (live(snap, nowMs)) return "exists";
        if (held.data().count >= maxPerMailbox) return "full";
        tx.set(ref, {
          mailboxHash,
          createdAt: nowMs,
          expiresAt: Timestamp.fromMillis(nowMs + ttlMs),
          events: [],
        });
        return "created";
      });
    },

    /**
     * Record one event, by the rule of `nextEvents` (src/opens-handlers.js),
     * which is given the stored events and returns the new list, or null
     * for "nothing to store". True when something was written.
     */
    async record(token, nextEvents, nowMs) {
      const ref = col.doc(token);
      return db.runTransaction(async (tx) => {
        const current = live(await tx.get(ref), nowMs);
        if (!current) return false;
        const events = nextEvents(current.events);
        if (!events) return false;
        tx.update(ref, { events });
        return true;
      });
    },

    /** The live documents among `tokens`, as a Map. One batched read. */
    async getMany(tokens, nowMs) {
      const out = new Map();
      if (!tokens.length) return out;
      const snaps = await db.getAll(...tokens.map((t) => col.doc(t)));
      for (const snap of snaps) {
        const doc = live(snap, nowMs);
        if (doc) out.set(snap.id, doc);
      }
      return out;
    },

    /** Delete every document of a mailbox. Returns how many went. */
    async removeMailbox(mailboxHash) {
      let removed = 0;
      for (;;) {
        const page = await col.where("mailboxHash", "==", mailboxHash).limit(400).get();
        if (page.empty) return removed;
        const batch = db.batch();
        for (const doc of page.docs) batch.delete(doc.ref);
        await batch.commit();
        removed += page.size;
      }
    },
  };
}
