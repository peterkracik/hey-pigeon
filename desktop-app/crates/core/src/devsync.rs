//! Cross-device sync of app-local state (DESIGN.md "Cross-device sync").
//!
//! Mail state already syncs through the provider; this moves what the
//! provider never sees — reminders now, prefs later — between the user's
//! devices with no server. Per account, each device owns exactly one file
//! in the account's hidden sync folder (`state-<device>.json`) holding
//! that device's full merged view of the key→value map. Merge is a
//! state-based last-writer-wins map: newest `(ts, device)` per key wins,
//! tombstones (`value: None`) delete. Single writer per file means no
//! write races (Drive has no conditional PUT), and re-merging any file is
//! idempotent, so a crash mid-sync is harmless.
//!
//! Keys are namespaced strings: `reminder:<thread_id>` → epoch ms.
// ponytail: tombstones are never garbage-collected. They cost ~80 bytes
// each and a personal mailbox produces a few hundred a year; GC needs a
// rule that survives a replica being offline longer than the GC window
// (otherwise its stale live entry resurrects the key). Revisit at 10k+.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

use serde::{Deserialize, Serialize};

use crate::domain::{AccountId, SyncEntry, ThreadId};
use crate::ports::{RemoteFile, Store, StoreError, SyncError, SyncTransport};

const FILE_PREFIX: &str = "state-";
const FILE_SUFFIX: &str = ".json";
const REMINDER_PREFIX: &str = "reminder:";
/// sync_meta keys.
const META_FILE_ID: &str = "file_id";
const META_UPLOADED_FP: &str = "uploaded_fp";
const META_SEEN_PREFIX: &str = "seen:";
const META_LAST_SYNC_AT: &str = "last_sync_at";

#[derive(Debug, thiserror::Error)]
pub enum DevSyncError {
    #[error(transparent)]
    Transport(#[from] SyncError),
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error("corrupt remote state file {name}: {reason}")]
    Corrupt { name: String, reason: String },
}

/// On-disk/remote shape of one device's state file.
#[derive(Debug, Serialize, Deserialize)]
struct Snapshot {
    v: u32,
    device: String,
    entries: Vec<SyncEntry>,
}

const SNAPSHOT_VERSION: u32 = 1;

pub fn reminder_key(thread_id: &ThreadId) -> String {
    format!("{REMINDER_PREFIX}{thread_id}")
}

fn reminder_thread(key: &str) -> Option<&str> {
    key.strip_prefix(REMINDER_PREFIX)
}

fn file_name(device: &str) -> String {
    format!("{FILE_PREFIX}{device}{FILE_SUFFIX}")
}

fn is_state_file(name: &str) -> bool {
    name.starts_with(FILE_PREFIX) && name.ends_with(FILE_SUFFIX)
}

/// Content fingerprint for "did what I hold change since the last upload".
/// Local cache marker only (never compared across devices), so std's
/// deterministic-per-build hasher is enough — worst case after a toolchain
/// bump is one redundant upload.
fn fingerprint(bytes: &[u8]) -> String {
    let mut h = DefaultHasher::new();
    bytes.hash(&mut h);
    format!("{:016x}", h.finish())
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Record a local write so it wins LWW and reaches other devices on the
/// next push. The timestamp is bumped past any stored entry for the key —
/// a device whose clock runs behind must still see its own edit stick.
pub fn record_local<S: Store>(
    store: &S,
    account_id: &AccountId,
    key: &str,
    value: Option<serde_json::Value>,
) -> Result<(), StoreError> {
    let device = store.sync_device_id()?;
    let floor = store
        .sync_entries(account_id)?
        .into_iter()
        .find(|e| e.key == key)
        .map(|e| e.ts + 1)
        .unwrap_or(0);
    let entry = SyncEntry {
        key: key.to_string(),
        value,
        ts: now_ms().max(floor),
        device,
    };
    store.sync_merge(account_id, &[entry])?;
    Ok(())
}

/// Convenience for the one key family that exists today.
pub fn record_reminder<S: Store>(
    store: &S,
    account_id: &AccountId,
    thread_id: &ThreadId,
    scheduled_at: Option<i64>,
) -> Result<(), StoreError> {
    record_local(
        store,
        account_id,
        &reminder_key(thread_id),
        scheduled_at.map(Into::into),
    )
}

/// One full sync round for one account: pull every changed remote state
/// file and merge it, project the merged map onto local rows, then push
/// this device's view if it differs from what it last uploaded. Returns
/// whether anything visible changed locally.
pub async fn sync_account<T: SyncTransport, S: Store>(
    transport: &T,
    store: &S,
    account_id: &AccountId,
) -> Result<bool, DevSyncError> {
    let device = store.sync_device_id()?;
    let own_name = file_name(&device);

    // ---- pull
    let mut changed_keys: Vec<String> = Vec::new();
    for file in transport.list(account_id).await? {
        if !is_state_file(&file.name) {
            continue;
        }
        if file.name == own_name {
            // Our own file: remember its id (a fresh install on a restored
            // DB, or a lost meta row) — and skip it unless someone else
            // wrote it, which the fingerprint check below catches.
            store.sync_meta_set(account_id, META_FILE_ID, &file.id)?;
        }
        let seen_key = format!("{META_SEEN_PREFIX}{}", file.id);
        if store.sync_meta_get(account_id, &seen_key)?.as_deref() == Some(file.fingerprint.as_str())
        {
            continue;
        }
        let bytes = transport.download(account_id, &file.id).await?;
        let snapshot: Snapshot =
            serde_json::from_slice(&bytes).map_err(|e| DevSyncError::Corrupt {
                name: file.name.clone(),
                reason: e.to_string(),
            })?;
        if snapshot.v != SNAPSHOT_VERSION {
            // A newer app wrote it; skip rather than misread it. The old
            // fingerprint is left unrecorded so an upgrade re-reads it.
            log::warn!(
                "devsync({account_id}): {} has version {}, skipping",
                file.name,
                snapshot.v
            );
            continue;
        }
        changed_keys.extend(store.sync_merge(account_id, &snapshot.entries)?);
        store.sync_meta_set(account_id, &seen_key, &file.fingerprint)?;
    }

    // ---- project onto local rows
    let entries = store.sync_entries(account_id)?;
    let applied = apply_reminders(store, &entries, &changed_keys)?;

    // ---- push
    let snapshot = Snapshot {
        v: SNAPSHOT_VERSION,
        device: device.clone(),
        entries,
    };
    let bytes = serde_json::to_vec(&snapshot).map_err(|e| StoreError(e.to_string()))?;
    let fp = fingerprint(&bytes);
    let file_id = store.sync_meta_get(account_id, META_FILE_ID)?;
    let uploaded_fp = store.sync_meta_get(account_id, META_UPLOADED_FP)?;
    if file_id.is_none() || uploaded_fp.as_deref() != Some(fp.as_str()) {
        let uploaded =
            upload_or_create(transport, account_id, file_id.as_deref(), &own_name, bytes).await?;
        store.sync_meta_set(account_id, META_FILE_ID, &uploaded.id)?;
        store.sync_meta_set(account_id, META_UPLOADED_FP, &fp)?;
        // Our own upload must not come back as "changed" on the next list.
        store.sync_meta_set(
            account_id,
            &format!("{META_SEEN_PREFIX}{}", uploaded.id),
            &uploaded.fingerprint,
        )?;
    }
    store.sync_meta_set(account_id, META_LAST_SYNC_AT, &now_ms().to_string())?;
    log::info!(
        "devsync({account_id}): {} remote keys changed, {} reminders applied",
        changed_keys.len(),
        applied
    );
    Ok(applied > 0)
}

/// Epoch ms of the last round that completed for this account, on any
/// run of the app (persisted — survives restarts). None until the first.
pub fn last_sync_at<S: Store>(
    store: &S,
    account_id: &AccountId,
) -> Result<Option<i64>, StoreError> {
    Ok(store
        .sync_meta_get(account_id, META_LAST_SYNC_AT)?
        .and_then(|v| v.parse().ok()))
}

async fn upload_or_create<T: SyncTransport>(
    transport: &T,
    account_id: &AccountId,
    file_id: Option<&str>,
    name: &str,
    bytes: Vec<u8>,
) -> Result<RemoteFile, SyncError> {
    if let Some(id) = file_id {
        match transport
            .upload(account_id, Some(id), name, bytes.clone())
            .await
        {
            Err(SyncError::NotFound) => {
                log::info!("devsync({account_id}): own state file vanished remotely, recreating");
            }
            other => return other,
        }
    }
    transport.upload(account_id, None, name, bytes).await
}

/// Project reminder entries onto `threads.scheduled_at`. Keys that changed
/// in this merge are applied whatever their value (a tombstone clears the
/// local schedule); every live entry is additionally re-checked so a
/// reminder set on another device lands once the thread itself arrives
/// here via backfill. Returns how many threads were updated.
fn apply_reminders<S: Store>(
    store: &S,
    entries: &[SyncEntry],
    changed_keys: &[String],
) -> Result<usize, StoreError> {
    let mut applied = 0usize;
    for entry in entries {
        let Some(thread_id) = reminder_thread(&entry.key) else {
            continue;
        };
        let want: Option<i64> = entry.value.as_ref().and_then(|v| v.as_i64());
        let changed = changed_keys.iter().any(|k| k == &entry.key);
        if !changed && want.is_none() {
            continue;
        }
        let Some(thread) = store.get_thread(&thread_id.to_string())? else {
            continue; // not backfilled yet — retried on the next round
        };
        if thread.scheduled_at == want {
            continue;
        }
        if store.set_schedule(&thread.id, want)? {
            applied += 1;
        }
    }
    Ok(applied)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::Thread;
    use crate::fakes::{sample_account, MemStore, MemTransport};
    use std::sync::Arc;

    fn thread(id: &str, account: &str) -> Thread {
        Thread {
            id: id.to_string(),
            account_id: account.to_string(),
            subject: "s".into(),
            snippet: "".into(),
            last_msg_at: 1,
            is_read: true,
            is_inbox: true,
            is_archived: false,
            msg_count: 1,
            from_summary: "".into(),
            last_from_addr: "".into(),
            scheduled_at: None,
            labels: vec!["INBOX".into()],
            has_attachment: false,
            priority: None,
            triage_label_ids: Vec::new(),
        }
    }

    fn device_store(account: &str, device: &str) -> MemStore {
        let s = MemStore::with_device_id(device);
        s.upsert_account(&sample_account(account)).unwrap();
        s.upsert_thread(&thread("t1", account)).unwrap();
        s
    }

    #[test]
    fn lww_newest_ts_then_device_wins() {
        let a = SyncEntry {
            key: "k".into(),
            value: None,
            ts: 5,
            device: "a".into(),
        };
        let b = SyncEntry {
            key: "k".into(),
            value: None,
            ts: 6,
            device: "a".into(),
        };
        let c = SyncEntry {
            key: "k".into(),
            value: None,
            ts: 6,
            device: "b".into(),
        };
        assert!(b.is_newer_than(&a));
        assert!(!a.is_newer_than(&b));
        assert!(c.is_newer_than(&b));
        assert!(!b.is_newer_than(&c));
    }

    #[test]
    fn record_local_bumps_past_future_timestamps() {
        let store = device_store("acc", "dev");
        let acc = "acc".to_string();
        // A remote entry from a device whose clock is far ahead.
        let far = now_ms() + 3_600_000;
        store
            .sync_merge(
                &acc,
                &[SyncEntry {
                    key: reminder_key(&"t1".into()),
                    value: Some(1.into()),
                    ts: far,
                    device: "zzz".into(),
                }],
            )
            .unwrap();
        record_reminder(&store, &acc, &"t1".into(), Some(2)).unwrap();
        let e = store
            .sync_entries(&acc)
            .unwrap()
            .into_iter()
            .next()
            .unwrap();
        assert_eq!(e.value, Some(2.into()), "local edit must win");
        assert_eq!(e.ts, far + 1);
        assert_eq!(e.device, "dev");
    }

    #[tokio::test]
    async fn reminder_round_trips_between_two_devices() {
        let remote = Arc::new(MemTransport::default());
        let acc = "acc".to_string();
        let a = device_store("acc", "dev-a");
        let b = device_store("acc", "dev-b");

        // Device A sets a reminder and syncs.
        a.set_schedule(&"t1".into(), Some(42)).unwrap();
        record_reminder(&a, &acc, &"t1".into(), Some(42)).unwrap();
        assert_eq!(last_sync_at(&a, &acc).unwrap(), None);
        assert!(
            !sync_account(&*remote, &a, &acc).await.unwrap(),
            "own write is not a local change"
        );
        assert_eq!(remote.uploads(), 1);
        assert!(last_sync_at(&a, &acc)
            .unwrap()
            .is_some_and(|t| t <= now_ms()));

        // Device B syncs: reminder lands on its thread row.
        assert!(sync_account(&*remote, &b, &acc).await.unwrap());
        assert_eq!(
            b.get_thread(&"t1".into()).unwrap().unwrap().scheduled_at,
            Some(42)
        );
        assert_eq!(remote.uploads(), 2, "B publishes its merged view");
        assert_eq!(remote.file_count(&acc), 2);

        // Nothing changed: no re-download, no re-upload.
        let d = remote.downloads();
        assert!(!sync_account(&*remote, &a, &acc).await.unwrap());
        assert!(!sync_account(&*remote, &b, &acc).await.unwrap());
        assert_eq!(remote.uploads(), 2);
        assert_eq!(remote.downloads(), d + 1, "A downloads B's new file once");

        // B clears it; A sees the tombstone.
        b.set_schedule(&"t1".into(), None).unwrap();
        record_reminder(&b, &acc, &"t1".into(), None).unwrap();
        sync_account(&*remote, &b, &acc).await.unwrap();
        assert!(sync_account(&*remote, &a, &acc).await.unwrap());
        assert_eq!(
            a.get_thread(&"t1".into()).unwrap().unwrap().scheduled_at,
            None
        );
    }

    #[tokio::test]
    async fn reminder_waits_for_thread_to_arrive() {
        let remote = Arc::new(MemTransport::default());
        let acc = "acc".to_string();
        let a = device_store("acc", "dev-a");
        let b = MemStore::with_device_id("dev-b");
        b.upsert_account(&sample_account("acc")).unwrap();

        record_reminder(&a, &acc, &"t1".into(), Some(7)).unwrap();
        sync_account(&*remote, &a, &acc).await.unwrap();

        // B has no such thread yet: nothing applied, entry kept.
        assert!(!sync_account(&*remote, &b, &acc).await.unwrap());
        assert_eq!(b.sync_entries(&acc).unwrap().len(), 1);
        // Thread arrives via backfill; the next round applies it.
        b.upsert_thread(&thread("t1", "acc")).unwrap();
        assert!(sync_account(&*remote, &b, &acc).await.unwrap());
        assert_eq!(
            b.get_thread(&"t1".into()).unwrap().unwrap().scheduled_at,
            Some(7)
        );
    }

    #[tokio::test]
    async fn vanished_own_file_is_recreated() {
        let remote = Arc::new(MemTransport::default());
        let acc = "acc".to_string();
        let a = device_store("acc", "dev-a");
        record_reminder(&a, &acc, &"t1".into(), Some(1)).unwrap();
        sync_account(&*remote, &a, &acc).await.unwrap();
        remote.clear(&acc);
        record_reminder(&a, &acc, &"t1".into(), Some(2)).unwrap();
        sync_account(&*remote, &a, &acc).await.unwrap();
        assert_eq!(remote.file_count(&acc), 1);
    }

    #[tokio::test]
    async fn corrupt_remote_file_is_an_error_not_a_panic() {
        let remote = Arc::new(MemTransport::default());
        let acc = "acc".to_string();
        remote
            .upload(&acc, None, "state-x.json", b"{not json".to_vec())
            .await
            .unwrap();
        let a = device_store("acc", "dev-a");
        assert!(matches!(
            sync_account(&*remote, &a, &acc).await,
            Err(DevSyncError::Corrupt { .. })
        ));
    }
}
