//! Cross-device sync of app-local state (DESIGN.md "Cross-device sync").
//!
//! Mail state already syncs through the provider; this moves what the
//! provider never sees — reminders, flags, settings — between the user's
//! devices with no server. Per account, each device owns exactly one file
//! in the account's hidden sync folder (`state-<device>.json`) holding
//! that device's full merged view of the key→value map. Merge is a
//! state-based last-writer-wins map: newest `(ts, device)` per key wins,
//! tombstones (`value: None`) delete. Single writer per file means no
//! write races (Drive has no conditional PUT), and re-merging any file is
//! idempotent, so a crash mid-sync is harmless.
//!
//! Keys are namespaced strings. Per thread, on the thread's account's file:
//! `reminder:<thread_id>` → epoch ms, `needs_reply:<thread_id>` → `true`
//! (a tombstone or `false` clears), `follow_up:<thread_id>` → epoch ms
//! the follow-up was armed (tombstone clears; always paired with a
//! `reminder:` entry), `thread_triage:<thread_id>` → the manually pinned
//! triage label ids (tombstone lifts the pin; Jev's own results stay
//! local — every device can reclassify). Per account, on its own file:
//! `account:<field>` → string, for `display_name` / `color` / `signature`.
//! App-wide, on the *first* account's file only (see `app_wide_account`):
//! `triage_label:<id>` → `{ "name" }` (tombstone deletes) and
//! `pref:<name>` → any JSON (tombstone clears). Secrets — API keys, OAuth
//! tokens — never enter the map; each device keeps its own keychain.
// ponytail: tombstones are never garbage-collected. They cost ~80 bytes
// each and a personal mailbox produces a few hundred a year; GC needs a
// rule that survives a replica being offline longer than the GC window
// (otherwise its stale live entry resurrects the key). Revisit at 10k+.

use std::collections::hash_map::DefaultHasher;
use std::collections::{HashMap, HashSet};
use std::hash::{Hash, Hasher};

use serde::{Deserialize, Serialize};

use crate::domain::{now_ms, AccountId, SyncEntry, ThreadId, TriageLabel};
use crate::ports::{RemoteFile, Store, StoreError, SyncError, SyncTransport};

const FILE_PREFIX: &str = "state-";
const FILE_SUFFIX: &str = ".json";
const REMINDER_PREFIX: &str = "reminder:";
const NEEDS_REPLY_PREFIX: &str = "needs_reply:";
const FOLLOW_UP_PREFIX: &str = "follow_up:";
const THREAD_TRIAGE_PREFIX: &str = "thread_triage:";
const ACCOUNT_PREFIX: &str = "account:";
const TRIAGE_LABEL_PREFIX: &str = "triage_label:";
const PREF_PREFIX: &str = "pref:";
/// `account:<field>` names — the three per-account settings that sync.
pub const ACCOUNT_FIELD_DISPLAY_NAME: &str = "display_name";
pub const ACCOUNT_FIELD_COLOR: &str = "color";
pub const ACCOUNT_FIELD_SIGNATURE: &str = "signature";
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

pub fn needs_reply_key(thread_id: &ThreadId) -> String {
    format!("{NEEDS_REPLY_PREFIX}{thread_id}")
}

fn needs_reply_thread(key: &str) -> Option<&str> {
    key.strip_prefix(NEEDS_REPLY_PREFIX)
}

pub fn follow_up_key(thread_id: &ThreadId) -> String {
    format!("{FOLLOW_UP_PREFIX}{thread_id}")
}

fn follow_up_thread(key: &str) -> Option<&str> {
    key.strip_prefix(FOLLOW_UP_PREFIX)
}

pub fn thread_triage_key(thread_id: &ThreadId) -> String {
    format!("{THREAD_TRIAGE_PREFIX}{thread_id}")
}

fn thread_triage_thread(key: &str) -> Option<&str> {
    key.strip_prefix(THREAD_TRIAGE_PREFIX)
}

pub fn account_field_key(field: &str) -> String {
    format!("{ACCOUNT_PREFIX}{field}")
}

fn account_field(key: &str) -> Option<&str> {
    key.strip_prefix(ACCOUNT_PREFIX)
}

pub fn triage_label_key(id: &str) -> String {
    format!("{TRIAGE_LABEL_PREFIX}{id}")
}

fn triage_label_id(key: &str) -> Option<&str> {
    key.strip_prefix(TRIAGE_LABEL_PREFIX)
}

pub fn pref_key(name: &str) -> String {
    format!("{PREF_PREFIX}{name}")
}

fn pref_name(key: &str) -> Option<&str> {
    key.strip_prefix(PREF_PREFIX)
}

/// The account whose file carries the app-wide keys (triage labels,
/// prefs): the lexicographically smallest connected account id. Every
/// device with the same accounts picks the same one with no coordination.
/// A device missing that account keeps its own app-wide state locally —
/// the accepted limit of "no anchor account, no server". When the first
/// account is removed, the next one takes over: `seed_app_wide` re-records
/// the local labels and prefs under its file on the next round.
pub fn app_wide_account<S: Store>(store: &S) -> Result<Option<AccountId>, StoreError> {
    Ok(store.list_accounts()?.into_iter().map(|a| a.id).min())
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

/// Convenience for the reminder key family.
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

/// Convenience for the "needs reply" key family. Clearing writes a
/// tombstone rather than `false` so the map stays as small as the reminder
/// one (both read back as "not flagged").
pub fn record_needs_reply<S: Store>(
    store: &S,
    account_id: &AccountId,
    thread_id: &ThreadId,
    needs_reply: bool,
) -> Result<(), StoreError> {
    record_local(
        store,
        account_id,
        &needs_reply_key(thread_id),
        needs_reply.then(|| true.into()),
    )
}

/// Convenience for the "follow up if no reply" key family. Clearing writes
/// a tombstone, like reminders.
pub fn record_follow_up<S: Store>(
    store: &S,
    account_id: &AccountId,
    thread_id: &ThreadId,
    follow_up_since: Option<i64>,
) -> Result<(), StoreError> {
    record_local(
        store,
        account_id,
        &follow_up_key(thread_id),
        follow_up_since.map(Into::into),
    )
}

/// Marking a thread done (archive or delete) ends its reminder, follow-up
/// and "needs reply" flag, here and — through the sync map — on the other
/// devices. Returns true when anything was set.
pub fn clear_on_done<S: Store>(store: &S, thread_id: &ThreadId) -> Result<bool, StoreError> {
    let Some(t) = store.get_thread(thread_id)? else {
        return Ok(false);
    };
    if t.scheduled_at.is_some() {
        store.set_schedule(thread_id, None)?;
        record_reminder(store, &t.account_id, thread_id, None)?;
    }
    if t.follow_up_since.is_some() {
        store.set_follow_up(thread_id, None)?;
        record_follow_up(store, &t.account_id, thread_id, None)?;
    }
    if t.needs_reply {
        store.set_needs_reply(thread_id, false)?;
        record_needs_reply(store, &t.account_id, thread_id, false)?;
    }
    Ok(t.scheduled_at.is_some() || t.follow_up_since.is_some() || t.needs_reply)
}

/// Convenience for the manual thread-triage key family: `Some(ids)` pins
/// the thread's labels on every device, a tombstone lifts the pin.
pub fn record_thread_triage<S: Store>(
    store: &S,
    account_id: &AccountId,
    thread_id: &ThreadId,
    label_ids: Option<&[String]>,
) -> Result<(), StoreError> {
    record_local(
        store,
        account_id,
        &thread_triage_key(thread_id),
        label_ids.map(|ids| serde_json::json!(ids)),
    )
}

/// "Reanalyze all" lifts every manual pin, here and on every other device:
/// tombstone each live `thread_triage:` entry, in every account's map.
pub fn record_reset_triage<S: Store>(store: &S) -> Result<(), StoreError> {
    for account in store.list_accounts()? {
        for entry in store.sync_entries(&account.id)? {
            if entry.value.is_some() && thread_triage_thread(&entry.key).is_some() {
                record_local(store, &account.id, &entry.key, None)?;
            }
        }
    }
    Ok(())
}

/// Convenience for the per-account settings family (`account:<field>`),
/// riding the account's own file.
pub fn record_account_field<S: Store>(
    store: &S,
    account_id: &AccountId,
    field: &str,
    value: &str,
) -> Result<(), StoreError> {
    record_local(
        store,
        account_id,
        &account_field_key(field),
        Some(value.into()),
    )
}

/// Convenience for the triage label family: `Some(name)` creates or
/// renames, `None` deletes. App-wide, so it rides the first account's
/// file; a no-op with no account connected (nothing to sync through).
pub fn record_triage_label<S: Store>(
    store: &S,
    id: &str,
    name: Option<&str>,
) -> Result<(), StoreError> {
    let Some(account_id) = app_wide_account(store)? else {
        return Ok(());
    };
    record_local(
        store,
        &account_id,
        &triage_label_key(id),
        name.map(|n| serde_json::json!({ "name": n })),
    )
}

/// Convenience for the preference family (`pref:<name>`): `None` writes a
/// tombstone. App-wide like labels; no-op without an account.
pub fn record_pref<S: Store>(
    store: &S,
    name: &str,
    value: Option<serde_json::Value>,
) -> Result<(), StoreError> {
    let Some(account_id) = app_wide_account(store)? else {
        return Ok(());
    };
    record_local(store, &account_id, &pref_key(name), value)
}

/// Record every local triage label and pref that the first account's map
/// does not know yet. Covers the first round after this feature landed
/// (labels and prefs predate their sync keys) and the hand-over when the
/// first account is removed and the next one's file takes the app-wide
/// keys. Tombstones count as known, so a deletion that already synced is
/// never undone. Returns how many keys were recorded.
fn seed_app_wide<S: Store>(store: &S, account_id: &AccountId) -> Result<usize, StoreError> {
    let known: HashSet<String> = store
        .sync_entries(account_id)?
        .into_iter()
        .map(|e| e.key)
        .collect();
    let mut n = 0;
    for label in store.list_triage_labels()? {
        if !known.contains(&triage_label_key(&label.id)) {
            record_local(
                store,
                account_id,
                &triage_label_key(&label.id),
                Some(serde_json::json!({ "name": label.name })),
            )?;
            n += 1;
        }
    }
    for (name, value) in store.list_prefs()? {
        if !known.contains(&pref_key(&name)) {
            record_local(store, account_id, &pref_key(&name), Some(value))?;
            n += 1;
        }
    }
    Ok(n)
}

/// What one sync round changed locally, by kind — the shell refreshes the
/// thread list for one and the settings UI for the other.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Applied {
    /// Thread rows (reminders, flags, pinned triage labels).
    pub threads: usize,
    /// Account fields, triage labels, prefs.
    pub settings: usize,
}

impl Applied {
    pub fn any(&self) -> bool {
        self.threads > 0 || self.settings > 0
    }
}

/// One full sync round for one account: pull every changed remote state
/// file and merge it, project the merged map onto local rows, then push
/// this device's view if it differs from what it last uploaded. Returns
/// what changed locally.
pub async fn sync_account<T: SyncTransport, S: Store>(
    transport: &T,
    store: &S,
    account_id: &AccountId,
) -> Result<Applied, DevSyncError> {
    let device = store.sync_device_id()?;
    let own_name = file_name(&device);
    let app_wide = app_wide_account(store)?.as_deref() == Some(account_id.as_str());

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

    // ---- app-wide keys live here: adopt what predates their sync keys
    if app_wide {
        let seeded = seed_app_wide(store, account_id)?;
        if seeded > 0 {
            log::info!("devsync({account_id}): seeded {seeded} app-wide key(s)");
        }
    }

    // ---- project onto local rows
    let entries = store.sync_entries(account_id)?;
    let applied = apply_entries(store, account_id, &entries, &changed_keys, app_wide)?;

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
        "devsync({account_id}): {} remote keys changed, {} thread flags and {} settings applied",
        changed_keys.len(),
        applied.threads,
        applied.settings
    );
    Ok(applied)
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

/// Project the merged map onto local state. Per-thread entries go to
/// their thread columns (`reminder:*` → `threads.scheduled_at`,
/// `needs_reply:*` → `threads.needs_reply`, `follow_up:*` →
/// `threads.follow_up_since`, `thread_triage:*` → the manual label pin).
/// Keys that changed in this merge are applied whatever their value (a
/// tombstone clears the local flag); every live entry is additionally
/// re-checked so a flag set on another device lands once the thread
/// itself arrives here via backfill. Settings are applied statelessly —
/// the map is the truth and local rows are made to match it: `account:*`
/// entries update this account's row; `triage_label:*` and `pref:*` are
/// honoured only when `app_wide` (this is the first account).
fn apply_entries<S: Store>(
    store: &S,
    account_id: &AccountId,
    entries: &[SyncEntry],
    changed_keys: &[String],
    app_wide: bool,
) -> Result<Applied, StoreError> {
    let mut applied = Applied::default();
    // Fetched lazily: most rounds carry no settings change at all.
    let mut account = None;
    let mut labels: Option<HashMap<String, TriageLabel>> = None;
    for entry in entries {
        let changed = changed_keys.iter().any(|k| k == &entry.key);
        if let Some(thread_id) = reminder_thread(&entry.key) {
            let want: Option<i64> = entry.value.as_ref().and_then(|v| v.as_i64());
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
                applied.threads += 1;
            }
        } else if let Some(thread_id) = needs_reply_thread(&entry.key) {
            let want = entry
                .value
                .as_ref()
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            if !changed && !want {
                continue;
            }
            let Some(thread) = store.get_thread(&thread_id.to_string())? else {
                continue; // not backfilled yet — retried on the next round
            };
            if thread.needs_reply == want {
                continue;
            }
            if store.set_needs_reply(&thread.id, want)? {
                applied.threads += 1;
            }
        } else if let Some(thread_id) = follow_up_thread(&entry.key) {
            let want: Option<i64> = entry.value.as_ref().and_then(|v| v.as_i64());
            if !changed && want.is_none() {
                continue;
            }
            let Some(thread) = store.get_thread(&thread_id.to_string())? else {
                continue; // not backfilled yet — retried on the next round
            };
            if thread.follow_up_since == want {
                continue;
            }
            if store.set_follow_up(&thread.id, want)? {
                applied.threads += 1;
            }
        } else if let Some(thread_id) = thread_triage_thread(&entry.key) {
            let want: Option<Vec<String>> = entry
                .value
                .as_ref()
                .and_then(|v| serde_json::from_value(v.clone()).ok());
            if !changed && want.is_none() {
                continue;
            }
            let Some(thread) = store.get_thread(&thread_id.to_string())? else {
                continue; // not backfilled yet — retried on the next round
            };
            match want {
                Some(ids) => {
                    if thread.triage_label_ids == ids {
                        continue;
                    }
                    store.set_manual_triage_labels(&thread.id, &ids)?;
                    applied.threads += 1;
                }
                None => {
                    if store.clear_manual_triage_labels(&thread.id)? {
                        applied.threads += 1;
                    }
                }
            }
        } else if let Some(field) = account_field(&entry.key) {
            // Fields always carry a value; a tombstone has nothing to say.
            // Applied statelessly (the map is the truth), so a row reset
            // behind the map's back heals on the next round.
            let Some(want) = entry.value.as_ref().and_then(|v| v.as_str()) else {
                continue;
            };
            if account.is_none() {
                account = store
                    .list_accounts()?
                    .into_iter()
                    .find(|a| &a.id == account_id);
            }
            let Some(acc) = account.as_mut() else {
                continue;
            };
            let slot = match field {
                ACCOUNT_FIELD_DISPLAY_NAME if !want.trim().is_empty() => &mut acc.display_name,
                ACCOUNT_FIELD_COLOR => &mut acc.color,
                ACCOUNT_FIELD_SIGNATURE => &mut acc.signature,
                _ => continue,
            };
            if slot == want {
                continue;
            }
            *slot = want.to_string();
            store.upsert_account(acc)?;
            applied.settings += 1;
        } else if let Some(id) = triage_label_id(&entry.key) {
            if !app_wide {
                continue;
            }
            let local = labels.get_or_insert_with(|| {
                store
                    .list_triage_labels()
                    .unwrap_or_default()
                    .into_iter()
                    .map(|l| (l.id.clone(), l))
                    .collect()
            });
            let want = entry
                .value
                .as_ref()
                .and_then(|v| v.get("name"))
                .and_then(|n| n.as_str())
                .map(str::trim)
                .filter(|n| !n.is_empty());
            match want {
                Some(name) => {
                    if local.get(id).is_some_and(|l| l.name == name) {
                        continue;
                    }
                    let label = TriageLabel {
                        id: id.to_string(),
                        name: name.to_string(),
                    };
                    store.upsert_triage_label(&label)?;
                    local.insert(label.id.clone(), label);
                    applied.settings += 1;
                }
                None => {
                    if local.remove(id).is_none() {
                        continue;
                    }
                    store.delete_triage_label(id)?;
                    applied.settings += 1;
                }
            }
        } else if let Some(name) = pref_name(&entry.key) {
            if !app_wide {
                continue;
            }
            let current = store.get_pref(name)?;
            if current == entry.value {
                continue;
            }
            store.set_pref(name, entry.value.as_ref())?;
            applied.settings += 1;
        }
    }
    Ok(applied)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{Priority, Thread};
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
            needs_reply: false,
            follow_up_since: None,
            suggestion: None,
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
            !sync_account(&*remote, &a, &acc).await.unwrap().any(),
            "own write is not a local change"
        );
        assert_eq!(remote.uploads(), 1);
        assert!(last_sync_at(&a, &acc)
            .unwrap()
            .is_some_and(|t| t <= now_ms()));

        // Device B syncs: reminder lands on its thread row.
        assert!(sync_account(&*remote, &b, &acc).await.unwrap().any());
        assert_eq!(
            b.get_thread(&"t1".into()).unwrap().unwrap().scheduled_at,
            Some(42)
        );
        assert_eq!(remote.uploads(), 2, "B publishes its merged view");
        assert_eq!(remote.file_count(&acc), 2);

        // Nothing changed: no re-download, no re-upload.
        let d = remote.downloads();
        assert!(!sync_account(&*remote, &a, &acc).await.unwrap().any());
        assert!(!sync_account(&*remote, &b, &acc).await.unwrap().any());
        assert_eq!(remote.uploads(), 2);
        assert_eq!(remote.downloads(), d + 1, "A downloads B's new file once");

        // B clears it; A sees the tombstone.
        b.set_schedule(&"t1".into(), None).unwrap();
        record_reminder(&b, &acc, &"t1".into(), None).unwrap();
        sync_account(&*remote, &b, &acc).await.unwrap();
        assert!(sync_account(&*remote, &a, &acc).await.unwrap().any());
        assert_eq!(
            a.get_thread(&"t1".into()).unwrap().unwrap().scheduled_at,
            None
        );
    }

    #[tokio::test]
    async fn needs_reply_round_trips_between_two_devices() {
        let remote = Arc::new(MemTransport::default());
        let acc = "acc".to_string();
        let a = device_store("acc", "dev-a");
        let b = device_store("acc", "dev-b");

        // Device A flags the thread and syncs; B picks it up.
        a.set_needs_reply(&"t1".into(), true).unwrap();
        record_needs_reply(&a, &acc, &"t1".into(), true).unwrap();
        assert!(!sync_account(&*remote, &a, &acc).await.unwrap().any());
        assert!(sync_account(&*remote, &b, &acc).await.unwrap().any());
        assert!(b.get_thread(&"t1".into()).unwrap().unwrap().needs_reply);

        // A flag that arrives before the thread lands once it is backfilled.
        let c = MemStore::with_device_id("dev-c");
        c.upsert_account(&sample_account("acc")).unwrap();
        assert!(!sync_account(&*remote, &c, &acc).await.unwrap().any());
        c.upsert_thread(&thread("t1", "acc")).unwrap();
        assert!(sync_account(&*remote, &c, &acc).await.unwrap().any());
        assert!(c.get_thread(&"t1".into()).unwrap().unwrap().needs_reply);

        // B clears it (tombstone); A sees the flag drop.
        b.set_needs_reply(&"t1".into(), false).unwrap();
        record_needs_reply(&b, &acc, &"t1".into(), false).unwrap();
        sync_account(&*remote, &b, &acc).await.unwrap();
        assert!(sync_account(&*remote, &a, &acc).await.unwrap().any());
        assert!(!a.get_thread(&"t1".into()).unwrap().unwrap().needs_reply);
        // Reminders are untouched by the needs_reply key family.
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
        assert!(!sync_account(&*remote, &b, &acc).await.unwrap().any());
        assert_eq!(b.sync_entries(&acc).unwrap().len(), 1);
        // Thread arrives via backfill; the next round applies it.
        b.upsert_thread(&thread("t1", "acc")).unwrap();
        assert!(sync_account(&*remote, &b, &acc).await.unwrap().any());
        assert_eq!(
            b.get_thread(&"t1".into()).unwrap().unwrap().scheduled_at,
            Some(7)
        );
    }

    #[tokio::test]
    async fn account_fields_round_trip_between_two_devices() {
        let remote = Arc::new(MemTransport::default());
        let acc = "acc".to_string();
        let a = device_store("acc", "dev-a");
        let b = device_store("acc", "dev-b");

        // Device A renames, recolours and signs; B follows after one round.
        let mut edited = sample_account("acc");
        edited.display_name = "Peter".into();
        edited.color = "coral".into();
        edited.signature = "-- P".into();
        a.upsert_account(&edited).unwrap();
        record_account_field(&a, &acc, ACCOUNT_FIELD_DISPLAY_NAME, "Peter").unwrap();
        record_account_field(&a, &acc, ACCOUNT_FIELD_COLOR, "coral").unwrap();
        record_account_field(&a, &acc, ACCOUNT_FIELD_SIGNATURE, "-- P").unwrap();
        assert!(!sync_account(&*remote, &a, &acc).await.unwrap().any());
        let applied = sync_account(&*remote, &b, &acc).await.unwrap();
        assert_eq!(
            applied,
            Applied {
                threads: 0,
                settings: 3
            }
        );
        let on_b = b.list_accounts().unwrap().remove(0);
        assert_eq!(on_b.display_name, "Peter");
        assert_eq!(on_b.color, "coral");
        assert_eq!(on_b.signature, "-- P");
        // Provider-owned columns are untouched.
        assert_eq!(on_b.email, "acc@example.com");

        // And back: B changes the colour, A sees it; nothing else moves.
        record_account_field(&b, &acc, ACCOUNT_FIELD_COLOR, "mint").unwrap();
        sync_account(&*remote, &b, &acc).await.unwrap();
        assert!(sync_account(&*remote, &a, &acc).await.unwrap().any());
        let on_a = a.list_accounts().unwrap().remove(0);
        assert_eq!(on_a.color, "mint");
        assert_eq!(on_a.display_name, "Peter");
        // Settled: a further round applies nothing.
        assert!(!sync_account(&*remote, &a, &acc).await.unwrap().any());

        // A row reset behind the map's back (a re-connect rewriting the
        // account) heals on the next round, no remote change needed.
        a.upsert_account(&sample_account("acc")).unwrap();
        assert!(sync_account(&*remote, &a, &acc).await.unwrap().any());
        assert_eq!(a.list_accounts().unwrap()[0].display_name, "Peter");
    }

    /// Two accounts on both devices: labels ride "a"'s file (smallest id),
    /// never "b"'s, and create / rename / delete all cross over by id.
    #[tokio::test]
    async fn triage_labels_ride_the_first_accounts_file() {
        let remote = Arc::new(MemTransport::default());
        let (acc_a, acc_b) = ("a".to_string(), "b".to_string());
        let x = device_store("a", "dev-x");
        x.upsert_account(&sample_account("b")).unwrap();
        let y = device_store("a", "dev-y");
        y.upsert_account(&sample_account("b")).unwrap();
        assert_eq!(app_wide_account(&x).unwrap().as_deref(), Some("a"));

        let bills = x.create_triage_label("Bills").unwrap();
        record_triage_label(&x, &bills.id, Some(&bills.name)).unwrap();
        assert_eq!(x.sync_entries(&acc_a).unwrap().len(), 1);
        assert!(x.sync_entries(&acc_b).unwrap().is_empty());
        sync_account(&*remote, &x, &acc_a).await.unwrap();
        sync_account(&*remote, &x, &acc_b).await.unwrap();

        // Y syncs "b" first: nothing app-wide there. Then "a": label lands,
        // same id, same name.
        assert!(!sync_account(&*remote, &y, &acc_b).await.unwrap().any());
        assert!(y.list_triage_labels().unwrap().is_empty());
        let applied = sync_account(&*remote, &y, &acc_a).await.unwrap();
        assert_eq!(applied.settings, 1);
        assert_eq!(y.list_triage_labels().unwrap(), vec![bills.clone()]);
        // Existing mail on Y gets a shot at the new label.
        assert_eq!(y.list_threads_needing_triage(10).unwrap().len(), 1);

        // Rename on Y, delete on X — both arrive by id.
        y.rename_triage_label(&bills.id, "Receipts").unwrap();
        record_triage_label(&y, &bills.id, Some("Receipts")).unwrap();
        sync_account(&*remote, &y, &acc_a).await.unwrap();
        assert!(sync_account(&*remote, &x, &acc_a).await.unwrap().any());
        assert_eq!(x.list_triage_labels().unwrap()[0].name, "Receipts");

        x.set_thread_triage(&"t1".into(), &[bills.id.clone()], Priority::Low, 1)
            .unwrap();
        x.delete_triage_label(&bills.id).unwrap();
        record_triage_label(&x, &bills.id, None).unwrap();
        sync_account(&*remote, &x, &acc_a).await.unwrap();
        assert!(sync_account(&*remote, &y, &acc_a).await.unwrap().any());
        assert!(y.list_triage_labels().unwrap().is_empty());
        // Idempotent: the tombstone stays, nothing re-applies.
        assert!(!sync_account(&*remote, &y, &acc_a).await.unwrap().any());
    }

    #[tokio::test]
    async fn manual_thread_triage_round_trips_and_reset_lifts_the_pin() {
        let remote = Arc::new(MemTransport::default());
        let acc = "acc".to_string();
        let a = device_store("acc", "dev-a");
        let b = device_store("acc", "dev-b");
        let t1: ThreadId = "t1".into();
        let ids = vec!["label-1".to_string()];

        // A pins labels on t1; B's thread adopts them and stays pinned
        // through its own auto-classification.
        a.set_manual_triage_labels(&t1, &ids).unwrap();
        record_thread_triage(&a, &acc, &t1, Some(&ids)).unwrap();
        sync_account(&*remote, &a, &acc).await.unwrap();
        assert!(sync_account(&*remote, &b, &acc).await.unwrap().any());
        assert_eq!(b.get_thread(&t1).unwrap().unwrap().triage_label_ids, ids);
        b.set_thread_triage(&t1, &["label-9".to_string()], Priority::High, 1)
            .unwrap();
        assert_eq!(
            b.get_thread(&t1).unwrap().unwrap().triage_label_ids,
            ids,
            "manual pin survives Jev on the other device too"
        );

        // "Reanalyze all" on B tombstones the pin: A's thread goes stale
        // and Jev may overwrite the labels again.
        b.reset_triage().unwrap();
        record_reset_triage(&b).unwrap();
        sync_account(&*remote, &b, &acc).await.unwrap();
        a.set_thread_triage(&t1, &ids, Priority::Low, 1).unwrap();
        assert!(a.list_threads_needing_triage(10).unwrap().is_empty());
        assert!(sync_account(&*remote, &a, &acc).await.unwrap().any());
        assert_eq!(a.list_threads_needing_triage(10).unwrap().len(), 1);
        a.set_thread_triage(&t1, &["label-9".to_string()], Priority::High, 1)
            .unwrap();
        assert_eq!(
            a.get_thread(&t1).unwrap().unwrap().triage_label_ids,
            vec!["label-9".to_string()],
            "pin lifted: Jev owns the labels again"
        );
    }

    #[tokio::test]
    async fn prefs_round_trip_and_tombstone_clears() {
        let remote = Arc::new(MemTransport::default());
        let acc = "acc".to_string();
        let a = device_store("acc", "dev-a");
        let b = device_store("acc", "dev-b");

        a.set_pref("pin_list", Some(&serde_json::json!(false)))
            .unwrap();
        record_pref(&a, "pin_list", Some(serde_json::json!(false))).unwrap();
        a.set_pref("hover_actions", Some(&serde_json::json!(["pin"])))
            .unwrap();
        record_pref(&a, "hover_actions", Some(serde_json::json!(["pin"]))).unwrap();
        sync_account(&*remote, &a, &acc).await.unwrap();
        let applied = sync_account(&*remote, &b, &acc).await.unwrap();
        assert_eq!(applied.settings, 2);
        assert_eq!(
            b.get_pref("pin_list").unwrap(),
            Some(serde_json::json!(false))
        );
        assert_eq!(
            b.get_pref("hover_actions").unwrap(),
            Some(serde_json::json!(["pin"]))
        );

        // B clears one: A drops it.
        b.set_pref("pin_list", None).unwrap();
        record_pref(&b, "pin_list", None).unwrap();
        sync_account(&*remote, &b, &acc).await.unwrap();
        assert!(sync_account(&*remote, &a, &acc).await.unwrap().any());
        assert_eq!(a.get_pref("pin_list").unwrap(), None);
        assert_eq!(a.list_prefs().unwrap().len(), 1);
    }

    /// Labels and prefs that exist before their sync keys do (upgrade) are
    /// adopted by the first account's file on its first round, and the
    /// remote side wins where both have a value.
    #[tokio::test]
    async fn pre_existing_labels_and_prefs_are_seeded_without_clobbering_remote() {
        let remote = Arc::new(MemTransport::default());
        let acc = "acc".to_string();
        let a = device_store("acc", "dev-a");
        let b = device_store("acc", "dev-b");

        // A already synced a pref; B has an old local value for the same
        // name plus a label nobody recorded.
        a.set_pref("auto_summarize", Some(&serde_json::json!(true)))
            .unwrap();
        record_pref(&a, "auto_summarize", Some(serde_json::json!(true))).unwrap();
        sync_account(&*remote, &a, &acc).await.unwrap();
        b.set_pref("auto_summarize", Some(&serde_json::json!(false)))
            .unwrap();
        let work = b.create_triage_label("Work").unwrap();

        assert!(sync_account(&*remote, &b, &acc).await.unwrap().any());
        assert_eq!(
            b.get_pref("auto_summarize").unwrap(),
            Some(serde_json::json!(true)),
            "the synced value wins over the never-recorded local one"
        );
        let keys: Vec<String> = b
            .sync_entries(&acc)
            .unwrap()
            .into_iter()
            .map(|e| e.key)
            .collect();
        assert!(
            keys.contains(&triage_label_key(&work.id)),
            "local label seeded"
        );
        assert!(sync_account(&*remote, &a, &acc).await.unwrap().any());
        assert_eq!(a.list_triage_labels().unwrap(), vec![work]);
    }

    /// Removing the first account hands the app-wide keys to the next one:
    /// they are re-recorded under its file on the following round.
    #[tokio::test]
    async fn app_wide_keys_follow_the_first_account_when_it_is_removed() {
        let remote = Arc::new(MemTransport::default());
        let (acc_a, acc_b) = ("a".to_string(), "b".to_string());
        let x = device_store("a", "dev-x");
        x.upsert_account(&sample_account("b")).unwrap();
        let bills = x.create_triage_label("Bills").unwrap();
        record_triage_label(&x, &bills.id, Some("Bills")).unwrap();
        x.set_pref("pin_list", Some(&serde_json::json!(true)))
            .unwrap();
        record_pref(&x, "pin_list", Some(serde_json::json!(true))).unwrap();
        sync_account(&*remote, &x, &acc_a).await.unwrap();
        sync_account(&*remote, &x, &acc_b).await.unwrap();
        assert!(x.sync_entries(&acc_b).unwrap().is_empty());

        x.delete_account("a");
        assert_eq!(app_wide_account(&x).unwrap().as_deref(), Some("b"));
        sync_account(&*remote, &x, &acc_b).await.unwrap();
        let keys: Vec<String> = x
            .sync_entries(&acc_b)
            .unwrap()
            .into_iter()
            .map(|e| e.key)
            .collect();
        assert_eq!(
            keys,
            vec![pref_key("pin_list"), triage_label_key(&bills.id)]
        );

        // A device that only ever had "b" now receives them.
        let y = MemStore::with_device_id("dev-y");
        y.upsert_account(&sample_account("b")).unwrap();
        assert!(sync_account(&*remote, &y, &acc_b).await.unwrap().any());
        assert_eq!(y.list_triage_labels().unwrap(), vec![bills]);
        assert_eq!(
            y.get_pref("pin_list").unwrap(),
            Some(serde_json::json!(true))
        );
    }

    /// App-wide keys in a non-first account's file are carried, not
    /// honoured: a device whose first account differs must not have its
    /// settings overwritten from a file it does not treat as the source.
    #[tokio::test]
    async fn app_wide_keys_in_other_files_are_ignored() {
        let remote = Arc::new(MemTransport::default());
        let acc_b = "b".to_string();
        // Y has only "b": its app-wide keys ride "b".
        let y = MemStore::with_device_id("dev-y");
        y.upsert_account(&sample_account("b")).unwrap();
        y.set_pref("pin_list", Some(&serde_json::json!(false)))
            .unwrap();
        record_pref(&y, "pin_list", Some(serde_json::json!(false))).unwrap();
        sync_account(&*remote, &y, &acc_b).await.unwrap();
        // X has "a" and "b": "a" is first, so "b"'s pref entry is not applied.
        let x = device_store("a", "dev-x");
        x.upsert_account(&sample_account("b")).unwrap();
        x.set_pref("pin_list", Some(&serde_json::json!(true)))
            .unwrap();
        assert!(!sync_account(&*remote, &x, &acc_b).await.unwrap().any());
        assert_eq!(
            x.get_pref("pin_list").unwrap(),
            Some(serde_json::json!(true))
        );
    }

    /// The whole point of keeping secrets out of the map: a state file
    /// built from every key family carries nothing that looks like a key
    /// or token, and every key belongs to a known family.
    #[tokio::test]
    async fn state_files_never_carry_secrets() {
        let remote = Arc::new(MemTransport::default());
        let acc = "acc".to_string();
        let a = device_store("acc", "dev-a");
        let t1: ThreadId = "t1".into();
        record_reminder(&a, &acc, &t1, Some(1)).unwrap();
        record_needs_reply(&a, &acc, &t1, true).unwrap();
        record_follow_up(&a, &acc, &t1, Some(1)).unwrap();
        record_thread_triage(&a, &acc, &t1, Some(&["l1".to_string()])).unwrap();
        record_account_field(&a, &acc, ACCOUNT_FIELD_DISPLAY_NAME, "Peter").unwrap();
        record_account_field(&a, &acc, ACCOUNT_FIELD_COLOR, "sky").unwrap();
        record_account_field(&a, &acc, ACCOUNT_FIELD_SIGNATURE, "--").unwrap();
        let label = a.create_triage_label("Bills").unwrap();
        record_triage_label(&a, &label.id, Some("Bills")).unwrap();
        for (name, value) in [
            ("ai.model", serde_json::json!("gpt-4o-mini")),
            ("triage.enabled", serde_json::json!(true)),
            ("auto_summarize", serde_json::json!(false)),
            ("pin_list", serde_json::json!(true)),
            ("hover_actions", serde_json::json!(["pin"])),
            ("swipe_actions", serde_json::json!(["archive"])),
            ("sidebar_hidden", serde_json::json!(["spam"])),
            ("label_colors", serde_json::json!({ "label:x": "mint" })),
        ] {
            a.set_pref(name, Some(&value)).unwrap();
            record_pref(&a, name, Some(value)).unwrap();
        }
        sync_account(&*remote, &a, &acc).await.unwrap();

        let files = remote.list(&acc).await.unwrap();
        assert_eq!(files.len(), 1);
        let bytes = remote.download(&acc, &files[0].id).await.unwrap();
        let text = String::from_utf8(bytes.clone()).unwrap();
        for forbidden in ["api_key", "refresh_token", "access_token", "client_secret"] {
            assert!(!text.contains(forbidden), "state file mentions {forbidden}");
        }
        let snapshot: Snapshot = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(snapshot.entries.len(), 16);
        let families = [
            REMINDER_PREFIX,
            NEEDS_REPLY_PREFIX,
            FOLLOW_UP_PREFIX,
            THREAD_TRIAGE_PREFIX,
            ACCOUNT_PREFIX,
            TRIAGE_LABEL_PREFIX,
            PREF_PREFIX,
        ];
        for e in &snapshot.entries {
            assert!(
                families.iter().any(|f| e.key.starts_with(f)),
                "unknown key family: {}",
                e.key
            );
        }
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
