//! Optimistic mutations: apply locally now, queue for the provider, drain later.
//! This is the entire "feels instant" trick (DESIGN.md).

use crate::devsync;
use crate::domain::{AccountId, Mutation};
use crate::ports::{MailError, MailProvider, Store, StoreError};

#[derive(Debug, thiserror::Error)]
pub enum OutboxError {
    #[error(transparent)]
    Store(#[from] StoreError),
}

/// Apply a mutation to the local store and enqueue it for the provider.
/// Returns immediately — the UI never waits for the network.
///
/// Done (archive) and delete also end the thread's reminder, follow-up and
/// "needs reply" flag: those lists only hold mail still waiting in the
/// inbox. Returns true when it cleared one, so the caller can push the
/// cross-device sync map now rather than on the next round.
pub fn enqueue<S: Store>(
    store: &S,
    account_id: &AccountId,
    mutation: Mutation,
) -> Result<bool, OutboxError> {
    store.apply_local(&mutation)?;
    store.outbox_push(account_id, &mutation)?;
    let cleared = match &mutation {
        Mutation::Archive { thread_id } | Mutation::Trash { thread_id } => {
            devsync::clear_on_done(store, thread_id)?
        }
        _ => false,
    };
    Ok(cleared)
}

/// Drain pending mutations against the provider. Items that fail stay queued
/// with a bumped attempt count; the caller reschedules with backoff.
/// On `AuthExpired` the drain stops early (no point hammering).
/// Returns (applied, failed).
// ponytail: retry backoff is caller-scheduled (fixed interval in M1); add
// per-item exponential delay from `attempts` if Gmail throttling ever shows up.
pub async fn drain<M: MailProvider, S: Store>(
    provider: &M,
    store: &S,
    batch: u32,
) -> Result<(usize, usize), OutboxError> {
    let items = store.outbox_list(batch)?;
    let mut applied = 0usize;
    let mut failed = 0usize;
    for item in items {
        match provider.apply(&item.account_id, &item.mutation).await {
            Ok(()) => {
                store.outbox_delete(item.id)?;
                applied += 1;
            }
            Err(MailError::AuthExpired) => {
                store.outbox_bump_attempts(item.id)?;
                failed += 1;
                log::warn!("outbox drain: auth expired, stopping");
                break;
            }
            Err(e) => {
                store.outbox_bump_attempts(item.id)?;
                failed += 1;
                log::warn!("outbox drain: item {} failed: {e}", item.id);
            }
        }
    }
    Ok((applied, failed))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::ThreadFilter;
    use crate::fakes::{FakeProvider, MemStore};

    fn seeded_store() -> MemStore {
        let store = MemStore::default();
        store
            .upsert_account(&crate::fakes::sample_account("a1"))
            .unwrap();
        store
    }

    #[tokio::test]
    async fn enqueue_applies_locally_and_queues() {
        let store = seeded_store();
        let provider = FakeProvider::with_sample_data("a1", 3, 10);
        crate::sync::backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        let t = &store
            .list_threads(None, &ThreadFilter::Inbox, None, 10)
            .unwrap()[0];

        enqueue(
            &store,
            &"a1".to_string(),
            Mutation::Archive {
                thread_id: t.id.clone(),
            },
        )
        .unwrap();

        // local effect is immediate
        let t2 = store.get_thread(&t.id).unwrap().unwrap();
        assert!(t2.is_archived);
        assert!(!t2.is_inbox);
        assert_eq!(store.outbox_list(10).unwrap().len(), 1);
    }

    #[tokio::test]
    async fn done_clears_reminder_follow_up_and_needs_reply() {
        let store = seeded_store();
        let provider = FakeProvider::with_sample_data("a1", 3, 10);
        crate::sync::backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        let ids: Vec<_> = store
            .list_threads(None, &ThreadFilter::Inbox, None, 10)
            .unwrap()
            .into_iter()
            .map(|t| t.id)
            .collect();
        let (flagged, plain) = (&ids[0], &ids[1]);
        store.set_schedule(flagged, Some(1)).unwrap();
        store.set_follow_up(flagged, Some(1)).unwrap();
        store.set_needs_reply(flagged, true).unwrap();

        let a1 = "a1".to_string();
        assert!(enqueue(
            &store,
            &a1,
            Mutation::Archive {
                thread_id: flagged.clone()
            }
        )
        .unwrap());
        let t = store.get_thread(flagged).unwrap().unwrap();
        assert_eq!(
            (t.scheduled_at, t.follow_up_since, t.needs_reply),
            (None, None, false)
        );
        // The clears travel to the other devices as tombstones.
        let keys: Vec<_> = store
            .sync_entries(&a1)
            .unwrap()
            .into_iter()
            .filter(|e| e.value.is_none())
            .map(|e| e.key)
            .collect();
        assert_eq!(keys.len(), 3, "{keys:?}");

        // Nothing to clear: no sync entries, nothing to push.
        assert!(!enqueue(
            &store,
            &a1,
            Mutation::Trash {
                thread_id: plain.clone()
            }
        )
        .unwrap());
        assert_eq!(store.sync_entries(&a1).unwrap().len(), 3);
    }

    #[tokio::test]
    async fn drain_applies_remotely_and_clears_queue() {
        let store = seeded_store();
        let provider = FakeProvider::with_sample_data("a1", 3, 10);
        crate::sync::backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        let id = store
            .list_threads(None, &ThreadFilter::Inbox, None, 10)
            .unwrap()[0]
            .id
            .clone();
        enqueue(
            &store,
            &"a1".to_string(),
            Mutation::Archive {
                thread_id: id.clone(),
            },
        )
        .unwrap();

        let (applied, failed) = drain(&provider, &store, 10).await.unwrap();

        assert_eq!((applied, failed), (1, 0));
        assert!(store.outbox_list(10).unwrap().is_empty());
        assert!(provider
            .applied_mutations()
            .iter()
            .any(|(_, m)| matches!(m, Mutation::Archive { thread_id } if *thread_id == id),));
    }

    #[tokio::test]
    async fn drain_keeps_failed_items_queued_with_bumped_attempts() {
        let store = seeded_store();
        let provider = FakeProvider::with_sample_data("a1", 2, 10);
        crate::sync::backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        let id = store
            .list_threads(None, &ThreadFilter::Inbox, None, 10)
            .unwrap()[0]
            .id
            .clone();
        enqueue(
            &store,
            &"a1".to_string(),
            Mutation::Archive { thread_id: id },
        )
        .unwrap();
        provider.fail_applies(true);

        let (applied, failed) = drain(&provider, &store, 10).await.unwrap();

        assert_eq!((applied, failed), (0, 1));
        let items = store.outbox_list(10).unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].attempts, 1);
    }
}
