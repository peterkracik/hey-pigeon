// Firestore-backed token table: tokens/{sha256(email)} → { tokens: [...] }.
// The document id is a hash so a dump of the collection does not list
// addresses; the address itself is never stored.

import { FieldValue } from "@google-cloud/firestore";

const COLLECTION = "tokens";

export function createTokenStore(db) {
  const col = db.collection(COLLECTION);

  return {
    async get(hash) {
      const snap = await col.doc(hash).get();
      if (!snap.exists) return [];
      const list = snap.data()?.tokens;
      return Array.isArray(list) ? list.filter((t) => t && typeof t.token === "string") : [];
    },

    async upsert(hash, entry) {
      const ref = col.doc(hash);
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(ref);
        const existing = snap.exists && Array.isArray(snap.data()?.tokens) ? snap.data().tokens : [];
        const others = existing.filter((t) => t?.token !== entry.token);
        others.push({ ...entry, updatedAt: Date.now() });
        tx.set(ref, { tokens: others, updatedAt: FieldValue.serverTimestamp() });
      });
    },

    async remove(hash, token) {
      const ref = col.doc(hash);
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(ref);
        if (!snap.exists) return;
        const existing = Array.isArray(snap.data()?.tokens) ? snap.data().tokens : [];
        const rest = existing.filter((t) => t?.token !== token);
        if (rest.length === 0) {
          tx.delete(ref);
        } else {
          tx.set(ref, { tokens: rest, updatedAt: FieldValue.serverTimestamp() });
        }
      });
    },
  };
}
