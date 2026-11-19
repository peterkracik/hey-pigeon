// Firestore-backed table of tracked messages:
//   opens/{token} → { mailboxHash, createdAt, expiresAt, events: [{label, at}] }
// The token is 128 random bits made by the app; `mailboxHash` is
// sha256(address) as in the device-token table — the address itself is not
// stored. `expiresAt` is a timestamp field with a Firestore TTL policy on
// it (terraform/firestore.tf): the document is deleted about 30 days after
// registration. TTL deletion can lag by a day, so readers check the field
// themselves and treat an expired document as absent.

import { FieldValue, Timestamp } from "@google-cloud/firestore";

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
     * Create the document. "created", "exists" (same mailbox: a retried
     * registration) or "taken" (another mailbox's token).
     */
    async register(token, mailboxHash, nowMs, ttlMs) {
      const ref = col.doc(token);
      return db.runTransaction(async (tx) => {
        const current = live(await tx.get(ref), nowMs);
        if (current) return current.mailboxHash === mailboxHash ? "exists" : "taken";
        tx.set(ref, {
          mailboxHash,
          createdAt: nowMs,
          expiresAt: Timestamp.fromMillis(nowMs + ttlMs),
          events: [],
        });
        return "created";
      });
    },

    /** Append one event unless the document already holds `cap`. True when written. */
    async append(token, event, cap, nowMs) {
      const ref = col.doc(token);
      return db.runTransaction(async (tx) => {
        const current = live(await tx.get(ref), nowMs);
        if (!current || current.events.length >= cap) return false;
        tx.update(ref, { events: FieldValue.arrayUnion(event) });
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
