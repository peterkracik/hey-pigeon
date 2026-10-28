//! Push watch bookkeeping (DESIGN.md "Push notifications", tier 3).
//!
//! A provider watch (Gmail `users.watch`) is a lease: it publishes
//! "mailbox changed" events to a Pub/Sub topic for at most 7 days. This
//! module owns the renewal *policy*; the shell owns the *decision* to push
//! (docs/ios.md: the shell owns cadence, the engine never spawns a loop).
//! Shells call `ensure_watch` at the end of every successful delta round;
//! it talks to the provider at most once a day per account.
//!
//! State lives in the per-account `sync_meta` table — no migration, and it
//! dies with the account.

use crate::domain::AccountId;
use crate::ports::{MailProvider, Store, StoreError, WatchState};
use crate::sync::SyncError;

/// sync_meta keys.
pub const META_WATCH_EXPIRATION_MS: &str = "push.watch_expiration_ms";
pub const META_WATCH_TOPIC: &str = "push.watch_topic";

/// Renew while this much of the lease (or less) is left. Gmail leases run
/// 7 days and Google recommends a daily `watch`; 6 days means "once per
/// day on any day the app syncs", so a phone that opens on day 6 and again
/// on day 8 keeps its push instead of losing it for two days.
pub const RENEW_BEFORE_MS: i64 = 6 * 24 * 3_600_000;

/// Make sure a live watch for `account_id` points at `topic`. Calls the
/// provider when there is no recorded watch, the topic changed, `force`
/// is set, or less than `RENEW_BEFORE_MS` of the lease remains. Returns
/// the new state when the provider was called, `None` when the recorded
/// watch is still good. Never touches the account's `history_id`
/// checkpoint — the delta loop owns that.
pub async fn ensure_watch<M: MailProvider, S: Store>(
    provider: &M,
    store: &S,
    account_id: &AccountId,
    topic: &str,
    now_ms: i64,
    force: bool,
) -> Result<Option<WatchState>, SyncError> {
    if !force && !needs_renewal(store, account_id, topic, now_ms)? {
        return Ok(None);
    }
    let state = provider.watch(account_id, topic).await?;
    store.sync_meta_set(
        account_id,
        META_WATCH_EXPIRATION_MS,
        &state.expiration_ms.to_string(),
    )?;
    store.sync_meta_set(account_id, META_WATCH_TOPIC, topic)?;
    log::info!(
        "push({account_id}): watch renewed, expires in {}h",
        (state.expiration_ms - now_ms).max(0) / 3_600_000
    );
    Ok(Some(state))
}

/// Tell the provider to stop publishing and forget the lease. The local
/// record is cleared even when the remote call fails (offline, revoked
/// grant): the lease expires on its own within 7 days and the caller has
/// already decided push is off.
pub async fn disable_watch<M: MailProvider, S: Store>(
    provider: &M,
    store: &S,
    account_id: &AccountId,
) -> Result<(), SyncError> {
    let result = provider.stop_watch(account_id).await;
    store.sync_meta_set(account_id, META_WATCH_EXPIRATION_MS, "")?;
    store.sync_meta_set(account_id, META_WATCH_TOPIC, "")?;
    result.map_err(SyncError::Mail)
}

/// Epoch ms when the recorded watch expires; None when there is none.
pub fn watch_expiration<S: Store>(
    store: &S,
    account_id: &AccountId,
) -> Result<Option<i64>, StoreError> {
    Ok(store
        .sync_meta_get(account_id, META_WATCH_EXPIRATION_MS)?
        .and_then(|v| v.parse::<i64>().ok()))
}

fn needs_renewal<S: Store>(
    store: &S,
    account_id: &AccountId,
    topic: &str,
    now_ms: i64,
) -> Result<bool, StoreError> {
    let Some(expiration) = watch_expiration(store, account_id)? else {
        return Ok(true);
    };
    let recorded_topic = store
        .sync_meta_get(account_id, META_WATCH_TOPIC)?
        .unwrap_or_default();
    if recorded_topic != topic {
        return Ok(true);
    }
    Ok(expiration - now_ms < RENEW_BEFORE_MS)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fakes::{sample_account, FakeProvider, MemStore};
    use crate::ports::MailError;

    const TOPIC: &str = "projects/p/topics/gmail-push";
    const NOW: i64 = 1_760_000_000_000;
    const DAY: i64 = 24 * 3_600_000;

    fn fixture() -> (FakeProvider, MemStore, AccountId) {
        let store = MemStore::default();
        store.upsert_account(&sample_account("acc")).unwrap();
        let provider = FakeProvider::with_sample_data("acc", 0, 10);
        (provider, store, "acc".to_string())
    }

    #[tokio::test]
    async fn first_call_registers_and_records_lease() {
        let (provider, store, acc) = fixture();
        provider.set_watch_expiration(NOW + 7 * DAY);
        let state = ensure_watch(&provider, &store, &acc, TOPIC, NOW, false)
            .await
            .unwrap()
            .expect("provider called");
        assert_eq!(state.expiration_ms, NOW + 7 * DAY);
        assert_eq!(
            provider.watch_calls(),
            vec![(acc.clone(), TOPIC.to_string())]
        );
        assert_eq!(watch_expiration(&store, &acc).unwrap(), Some(NOW + 7 * DAY));
        assert_eq!(
            store
                .sync_meta_get(&acc, META_WATCH_TOPIC)
                .unwrap()
                .as_deref(),
            Some(TOPIC)
        );
    }

    #[tokio::test]
    async fn fresh_lease_is_left_alone() {
        let (provider, store, acc) = fixture();
        provider.set_watch_expiration(NOW + 7 * DAY);
        ensure_watch(&provider, &store, &acc, TOPIC, NOW, false)
            .await
            .unwrap();
        // Half a day later: 6.5 days left, nothing to do.
        let again = ensure_watch(&provider, &store, &acc, TOPIC, NOW + DAY / 2, false)
            .await
            .unwrap();
        assert!(again.is_none());
        assert_eq!(provider.watch_calls().len(), 1);
    }

    #[tokio::test]
    async fn renews_once_less_than_six_days_remain() {
        let (provider, store, acc) = fixture();
        provider.set_watch_expiration(NOW + 7 * DAY);
        ensure_watch(&provider, &store, &acc, TOPIC, NOW, false)
            .await
            .unwrap();
        let later = NOW + DAY + 1;
        provider.set_watch_expiration(later + 7 * DAY);
        let renewed = ensure_watch(&provider, &store, &acc, TOPIC, later, false)
            .await
            .unwrap();
        assert!(renewed.is_some());
        assert_eq!(provider.watch_calls().len(), 2);
        assert_eq!(
            watch_expiration(&store, &acc).unwrap(),
            Some(later + 7 * DAY)
        );
    }

    #[tokio::test]
    async fn topic_change_rewatches() {
        let (provider, store, acc) = fixture();
        provider.set_watch_expiration(NOW + 7 * DAY);
        ensure_watch(&provider, &store, &acc, TOPIC, NOW, false)
            .await
            .unwrap();
        let other = "projects/other/topics/gmail-push";
        let renewed = ensure_watch(&provider, &store, &acc, other, NOW, false)
            .await
            .unwrap();
        assert!(renewed.is_some());
        assert_eq!(provider.watch_calls()[1].1, other);
    }

    #[tokio::test]
    async fn force_always_calls_provider() {
        let (provider, store, acc) = fixture();
        provider.set_watch_expiration(NOW + 7 * DAY);
        ensure_watch(&provider, &store, &acc, TOPIC, NOW, false)
            .await
            .unwrap();
        ensure_watch(&provider, &store, &acc, TOPIC, NOW, true)
            .await
            .unwrap();
        assert_eq!(provider.watch_calls().len(), 2);
    }

    #[tokio::test]
    async fn provider_error_leaves_record_untouched() {
        let (provider, store, acc) = fixture();
        provider.fail_watch(true);
        let err = ensure_watch(&provider, &store, &acc, TOPIC, NOW, false)
            .await
            .unwrap_err();
        assert!(matches!(err, SyncError::Mail(MailError::Provider(_))));
        assert_eq!(watch_expiration(&store, &acc).unwrap(), None);
    }

    #[tokio::test]
    async fn disable_stops_and_clears() {
        let (provider, store, acc) = fixture();
        provider.set_watch_expiration(NOW + 7 * DAY);
        ensure_watch(&provider, &store, &acc, TOPIC, NOW, false)
            .await
            .unwrap();
        disable_watch(&provider, &store, &acc).await.unwrap();
        assert_eq!(provider.stop_calls(), vec![acc.clone()]);
        assert_eq!(watch_expiration(&store, &acc).unwrap(), None);
        // Next ensure registers again from scratch.
        ensure_watch(&provider, &store, &acc, TOPIC, NOW, false)
            .await
            .unwrap()
            .expect("re-registered");
    }

    #[tokio::test]
    async fn disable_clears_even_when_stop_fails() {
        let (provider, store, acc) = fixture();
        provider.set_watch_expiration(NOW + 7 * DAY);
        ensure_watch(&provider, &store, &acc, TOPIC, NOW, false)
            .await
            .unwrap();
        provider.fail_watch(true);
        assert!(disable_watch(&provider, &store, &acc).await.is_err());
        assert_eq!(watch_expiration(&store, &acc).unwrap(), None);
    }
}
