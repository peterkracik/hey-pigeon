//! Backfill sync: page through recent threads and upsert into the store.
//! Idempotent — safe to re-run after crash/quit (upserts keyed on native ids).

use crate::domain::AccountId;
use crate::ports::{MailError, MailProvider, Store, StoreError};

#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error(transparent)]
    Mail(#[from] MailError),
    #[error(transparent)]
    Store(#[from] StoreError),
}

/// M1 backfill: capture `historyId` FIRST (so the future delta loop has a
/// checkpoint that predates the backfill), then page newest-first through the
/// provider and upsert everything.
pub async fn backfill<M: MailProvider, S: Store>(
    provider: &M,
    store: &S,
    account_id: &AccountId,
    window_days: u32,
) -> Result<usize, SyncError> {
    let profile = provider.profile(account_id).await?;
    store.set_history_id(account_id, &profile.history_id)?;

    let mut total = 0usize;
    let mut page_token: Option<String> = None;
    loop {
        let page = provider
            .list_recent(account_id, window_days, page_token.take())
            .await?;
        for (thread, messages) in &page.threads {
            store.upsert_thread(thread)?;
            for m in messages {
                store.upsert_message(m)?;
            }
            total += 1;
        }
        match page.next_page_token {
            Some(t) => page_token = Some(t),
            None => break,
        }
    }
    log::info!("backfill({account_id}): {total} threads");
    Ok(total)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fakes::{FakeProvider, MemStore};

    #[tokio::test]
    async fn backfill_stores_history_id_then_threads() {
        let provider = FakeProvider::with_sample_data("a1", 25, 10); // 25 threads, page size 10
        let store = MemStore::default();
        store
            .upsert_account(&crate::fakes::sample_account("a1"))
            .unwrap();

        let n = backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();

        assert_eq!(n, 25, "all pages walked");
        let accounts = store.list_accounts().unwrap();
        assert_eq!(accounts[0].history_id.as_deref(), Some("hist-1"));
        let threads = store.list_threads(None, None, 100).unwrap();
        assert_eq!(threads.len(), 25);
        // newest first
        assert!(threads.windows(2).all(|w| w[0].last_msg_at >= w[1].last_msg_at));
    }

    #[tokio::test]
    async fn backfill_is_idempotent() {
        let provider = FakeProvider::with_sample_data("a1", 5, 10);
        let store = MemStore::default();
        store
            .upsert_account(&crate::fakes::sample_account("a1"))
            .unwrap();
        backfill(&provider, &store, &"a1".to_string(), 30).await.unwrap();
        backfill(&provider, &store, &"a1".to_string(), 30).await.unwrap();
        assert_eq!(store.list_threads(None, None, 100).unwrap().len(), 5);
    }
}
