//! In-memory fakes for every port (DESIGN.md: "fakes over mocks").
//! Used by core tests, adapter contract tests, and the app's --fake-mail dev mode.

use std::collections::HashMap;
use std::sync::Mutex;

use crate::domain::*;
use crate::ports::*;

pub fn sample_account(id: &str) -> Account {
    Account {
        id: id.to_string(),
        email: format!("{id}@example.com"),
        display_name: id.to_uppercase(),
        color: "sky".to_string(),
        history_id: None,
        avatar_url: None,
        signature: String::new(),
    }
}

// ---------------------------------------------------------------- MemStore

/// In-memory `Store`. Interior mutability so it can be shared like the SQLite
/// adapter will be.
#[derive(Default)]
pub struct MemStore {
    inner: Mutex<MemStoreInner>,
}

#[derive(Default)]
struct MemStoreInner {
    accounts: HashMap<AccountId, Account>,
    threads: HashMap<ThreadId, Thread>,
    messages: HashMap<MessageId, Message>,
    labels: HashMap<AccountId, Vec<Label>>,
    outbox: Vec<OutboxItem>,
    next_outbox_id: i64,
    device_id: Option<String>,
    /// account → key → entry (the cross-device LWW map).
    sync_kv: HashMap<AccountId, HashMap<String, SyncEntry>>,
    sync_meta: HashMap<(AccountId, String), String>,
    triage_labels: Vec<TriageLabel>,
    next_triage_label_id: i64,
    /// thread → `msg_count` at its last Jev classification. Missing/stale
    /// (≠ current `msg_count`) means `list_threads_needing_triage` returns it.
    triage_versions: HashMap<ThreadId, i64>,
    /// Threads whose triage labels were manually edited — `set_thread_triage`
    /// must leave them alone until `reset_triage` clears the pin.
    triage_labels_manual: std::collections::HashSet<ThreadId>,
    /// App-wide preferences (`Store::get_pref` & co.).
    prefs: std::collections::BTreeMap<String, serde_json::Value>,
}

impl MemStore {
    /// A store posing as one specific device — two of these over one
    /// `MemTransport` simulate two Macs.
    pub fn with_device_id(device_id: &str) -> Self {
        let s = Self::default();
        s.inner.lock().unwrap().device_id = Some(device_id.to_string());
        s
    }

    /// Disconnect an account: its row, threads, messages and sync state go
    /// (mirrors the SQLite adapter's `delete_account`). App-wide data
    /// (triage labels, prefs) stays — it belongs to the install, not the
    /// account.
    pub fn delete_account(&self, account_id: &str) {
        let mut g = self.inner.lock().unwrap();
        g.accounts.remove(account_id);
        g.threads.retain(|_, t| t.account_id != account_id);
        g.messages.retain(|_, m| m.account_id != account_id);
        g.labels.remove(account_id);
        g.sync_kv.remove(account_id);
        g.sync_meta.retain(|(a, _), _| a != account_id);
    }
}

/// Same folder semantics as the SQLite adapter's SQL (keep in lockstep).
/// True while a thread's "remind me" schedule is still in the future.
fn is_snoozed(t: &Thread) -> bool {
    t.scheduled_at.is_some_and(|at| at > now_ms())
}

fn matches_filter(t: &Thread, filter: &ThreadFilter) -> bool {
    let has = |l: &str| t.labels.iter().any(|x| x == l);
    // Junk only when trashed/spam AND out of the inbox — a partially-trashed
    // thread keeps INBOX and stays in All/Starred/Sent/label views.
    let junk = (has("TRASH") || has("SPAM")) && !has("INBOX");
    match filter {
        // "Remind me later" = snooze: a thread scheduled for a future
        // instant stays out of the inbox until that instant passes (it
        // still lives in Scheduled / All). Keep in lockstep with the SQLite
        // adapter's thread_filter_sql.
        ThreadFilter::Inbox => t.is_inbox && !t.is_archived && !is_snoozed(t),
        ThreadFilter::All => !junk,
        ThreadFilter::Starred => has("STARRED") && !junk,
        ThreadFilter::Sent => has("SENT") && !junk,
        // A trashed draft belongs to Trash only (Gmail hides it from Drafts).
        ThreadFilter::Drafts => has("DRAFT") && !has("TRASH"),
        ThreadFilter::Archive => t.is_archived,
        ThreadFilter::Spam => has("SPAM"),
        ThreadFilter::Trash => has("TRASH"),
        ThreadFilter::Label(id) => has(id) && !junk,
    }
}

impl Store for MemStore {
    fn upsert_account(&self, account: &Account) -> Result<(), StoreError> {
        let mut g = self.inner.lock().unwrap();
        g.accounts.insert(account.id.clone(), account.clone());
        Ok(())
    }

    fn list_accounts(&self) -> Result<Vec<Account>, StoreError> {
        let g = self.inner.lock().unwrap();
        let mut v: Vec<_> = g.accounts.values().cloned().collect();
        v.sort_by(|a, b| a.id.cmp(&b.id));
        Ok(v)
    }

    fn set_history_id(&self, account_id: &AccountId, history_id: &str) -> Result<(), StoreError> {
        let mut g = self.inner.lock().unwrap();
        let acc = g
            .accounts
            .get_mut(account_id)
            .ok_or_else(|| StoreError(format!("unknown account {account_id}")))?;
        acc.history_id = Some(history_id.to_string());
        Ok(())
    }

    fn upsert_thread(&self, thread: &Thread) -> Result<(), StoreError> {
        let mut g = self.inner.lock().unwrap();
        let mut t = thread.clone();
        // Match SQLite: scheduled_at is local-only metadata — a provider
        // re-upsert (backfill/delta) must not clobber it.
        if let Some(old) = g.threads.get(&t.id) {
            if t.scheduled_at.is_none() {
                t.scheduled_at = old.scheduled_at;
            }
            // Same contract for Jev triage (priority/triage_label_ids): the
            // provider never sets these, so a fresh upsert always carries
            // the empty default — preserve whatever Jev last computed.
            t.priority = old.priority;
            t.triage_label_ids = old.triage_label_ids.clone();
            // needs_reply too: local-only, a provider upsert always carries
            // the `false` default.
            t.needs_reply = old.needs_reply;
            t.follow_up_since = old.follow_up_since;
        }
        g.threads.insert(t.id.clone(), t);
        Ok(())
    }

    fn upsert_message(&self, message: &Message) -> Result<(), StoreError> {
        let mut g = self.inner.lock().unwrap();
        let mut m = message.clone();
        // Match SQLite: a metadata-tier re-upsert must not wipe lazily
        // fetched bodies.
        if let Some(old) = g.messages.get(&m.id) {
            if m.body_html.is_none() {
                m.body_html = old.body_html.clone();
            }
            if m.body_text.is_none() {
                m.body_text = old.body_text.clone();
            }
        }
        g.messages.insert(m.id.clone(), m);
        Ok(())
    }

    fn delete_message(&self, message_id: &MessageId) -> Result<(), StoreError> {
        let mut g = self.inner.lock().unwrap();
        g.messages.remove(message_id);
        Ok(())
    }

    fn delete_thread(&self, thread_id: &ThreadId) -> Result<(), StoreError> {
        let mut g = self.inner.lock().unwrap();
        g.threads.remove(thread_id);
        g.messages.retain(|_, m| &m.thread_id != thread_id);
        Ok(())
    }

    fn list_threads(
        &self,
        account_id: Option<&AccountId>,
        filter: &ThreadFilter,
        before: Option<i64>,
        limit: u32,
    ) -> Result<Vec<Thread>, StoreError> {
        let g = self.inner.lock().unwrap();
        let mut v: Vec<_> = g
            .threads
            .values()
            .filter(|t| matches_filter(t, filter))
            .filter(|t| account_id.is_none_or(|a| &t.account_id == a))
            .filter(|t| before.is_none_or(|b| t.last_msg_at < b))
            .cloned()
            .collect();
        v.sort_by(|a, b| b.last_msg_at.cmp(&a.last_msg_at));
        v.truncate(limit as usize);
        Ok(v)
    }

    fn get_thread(&self, thread_id: &ThreadId) -> Result<Option<Thread>, StoreError> {
        Ok(self.inner.lock().unwrap().threads.get(thread_id).cloned())
    }

    fn list_messages(&self, thread_id: &ThreadId) -> Result<Vec<Message>, StoreError> {
        let g = self.inner.lock().unwrap();
        let mut v: Vec<_> = g
            .messages
            .values()
            .filter(|m| &m.thread_id == thread_id)
            .cloned()
            .collect();
        v.sort_by_key(|m| m.date);
        Ok(v)
    }

    fn set_labels(&self, account_id: &AccountId, labels: &[Label]) -> Result<(), StoreError> {
        let mut g = self.inner.lock().unwrap();
        g.labels.insert(account_id.clone(), labels.to_vec());
        Ok(())
    }

    fn list_labels(&self) -> Result<Vec<Label>, StoreError> {
        let g = self.inner.lock().unwrap();
        let mut v: Vec<Label> = g.labels.values().flatten().cloned().collect();
        v.sort_by(|a, b| (&a.account_id, &a.id).cmp(&(&b.account_id, &b.id)));
        Ok(v)
    }

    fn list_triage_labels(&self) -> Result<Vec<TriageLabel>, StoreError> {
        let g = self.inner.lock().unwrap();
        let mut v = g.triage_labels.clone();
        v.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(v)
    }

    fn create_triage_label(&self, name: &str) -> Result<TriageLabel, StoreError> {
        // Ids travel between devices, so a plain counter would collide (two
        // installs both minting "1"). The SQLite adapter uses a random id;
        // here the device id prefix is the fake of that.
        let device = self.sync_device_id()?;
        let mut g = self.inner.lock().unwrap();
        if g.triage_labels
            .iter()
            .any(|l| l.name.eq_ignore_ascii_case(name))
        {
            return Err(StoreError(format!("triage label '{name}' already exists")));
        }
        g.next_triage_label_id += 1;
        let label = TriageLabel {
            id: format!("{device}-{}", g.next_triage_label_id),
            name: name.to_string(),
        };
        g.triage_labels.push(label.clone());
        // A new label may match mail already synced, not just future mail —
        // make everyone stale so the poller gradually reclassifies (bounded
        // by its own per-tick limit).
        g.triage_versions.clear();
        Ok(label)
    }

    fn rename_triage_label(&self, id: &str, new_name: &str) -> Result<(), StoreError> {
        let mut g = self.inner.lock().unwrap();
        let label = g
            .triage_labels
            .iter_mut()
            .find(|l| l.id == id)
            .ok_or_else(|| StoreError(format!("unknown triage label {id}")))?;
        label.name = new_name.to_string();
        Ok(())
    }

    fn delete_triage_label(&self, id: &str) -> Result<(), StoreError> {
        let mut g = self.inner.lock().unwrap();
        g.triage_labels.retain(|l| l.id != id);
        for t in g.threads.values_mut() {
            t.triage_label_ids.retain(|l| l != id);
        }
        Ok(())
    }

    fn upsert_triage_label(&self, label: &TriageLabel) -> Result<(), StoreError> {
        let mut g = self.inner.lock().unwrap();
        match g.triage_labels.iter_mut().find(|l| l.id == label.id) {
            Some(existing) => existing.name = label.name.clone(),
            None => {
                g.triage_labels.push(label.clone());
                // New label: everyone stale, same as `create_triage_label`.
                g.triage_versions.clear();
            }
        }
        Ok(())
    }

    fn clear_manual_triage_labels(&self, thread_id: &ThreadId) -> Result<bool, StoreError> {
        let mut g = self.inner.lock().unwrap();
        if !g.threads.contains_key(thread_id) {
            return Ok(false);
        }
        g.triage_labels_manual.remove(thread_id);
        g.triage_versions.remove(thread_id);
        Ok(true)
    }

    fn get_pref(&self, name: &str) -> Result<Option<serde_json::Value>, StoreError> {
        Ok(self.inner.lock().unwrap().prefs.get(name).cloned())
    }

    fn set_pref(&self, name: &str, value: Option<&serde_json::Value>) -> Result<(), StoreError> {
        let mut g = self.inner.lock().unwrap();
        match value {
            Some(v) => {
                g.prefs.insert(name.to_string(), v.clone());
            }
            None => {
                g.prefs.remove(name);
            }
        }
        Ok(())
    }

    fn list_prefs(&self) -> Result<Vec<(String, serde_json::Value)>, StoreError> {
        let g = self.inner.lock().unwrap();
        Ok(g.prefs
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect())
    }

    fn reset_triage(&self) -> Result<(), StoreError> {
        let mut g = self.inner.lock().unwrap();
        g.triage_versions.clear();
        g.triage_labels_manual.clear();
        Ok(())
    }

    fn list_threads_needing_triage(&self, limit: u32) -> Result<Vec<Thread>, StoreError> {
        let g = self.inner.lock().unwrap();
        let mut v: Vec<Thread> = g
            .threads
            .values()
            .filter(|t| g.triage_versions.get(&t.id) != Some(&t.msg_count))
            .cloned()
            .collect();
        v.sort_by(|a, b| b.last_msg_at.cmp(&a.last_msg_at));
        v.truncate(limit as usize);
        Ok(v)
    }

    fn set_thread_triage(
        &self,
        thread_id: &ThreadId,
        label_ids: &[String],
        priority: Priority,
        at_msg_count: i64,
    ) -> Result<(), StoreError> {
        let mut g = self.inner.lock().unwrap();
        let manual = g.triage_labels_manual.contains(thread_id);
        let t = g
            .threads
            .get_mut(thread_id)
            .ok_or_else(|| StoreError(format!("unknown thread {thread_id}")))?;
        // A manually-pinned thread keeps its user-chosen labels — only
        // priority/version move (matches SqliteStore's CASE).
        if !manual {
            t.triage_label_ids = label_ids.to_vec();
        }
        t.priority = Some(priority);
        g.triage_versions.insert(thread_id.clone(), at_msg_count);
        Ok(())
    }

    fn set_manual_triage_labels(
        &self,
        thread_id: &ThreadId,
        label_ids: &[String],
    ) -> Result<(), StoreError> {
        let mut g = self.inner.lock().unwrap();
        let t = g
            .threads
            .get_mut(thread_id)
            .ok_or_else(|| StoreError(format!("unknown thread {thread_id}")))?;
        t.triage_label_ids = label_ids.to_vec();
        g.triage_labels_manual.insert(thread_id.clone());
        Ok(())
    }

    fn apply_local(&self, mutation: &Mutation) -> Result<(), StoreError> {
        let mut g = self.inner.lock().unwrap();
        // Match SQLite: the optimistic apply also flips the thread-level
        // labels so folder queries agree before the next delta sync.
        let apply = |t: &mut Thread| match mutation {
            Mutation::Archive { .. } => {
                t.is_archived = true;
                t.is_inbox = false;
                t.labels.retain(|l| l != "INBOX");
            }
            Mutation::Unarchive { .. } => {
                t.is_archived = false;
                t.is_inbox = true;
                if !t.labels.iter().any(|l| l == "INBOX") {
                    t.labels.push("INBOX".to_string());
                }
            }
            Mutation::MarkRead { read, .. } => t.is_read = *read,
            Mutation::Trash { .. } => {
                t.is_inbox = false;
                t.is_archived = false;
                t.labels.retain(|l| l != "INBOX");
                if !t.labels.iter().any(|l| l == "TRASH") {
                    t.labels.push("TRASH".to_string());
                }
            }
            // Star/ModifyLabel: pure label flips, flags untouched (matches
            // SqliteStore::flip_label).
            Mutation::Star { starred, .. } => {
                t.labels.retain(|l| l != "STARRED");
                if *starred {
                    t.labels.push("STARRED".to_string());
                }
            }
            Mutation::ModifyLabel { label_id, add, .. } => {
                t.labels.retain(|l| l != label_id);
                if *add {
                    t.labels.push(label_id.clone());
                }
            }
            Mutation::Send { .. } | Mutation::SaveDraft { .. } | Mutation::DeleteDraft { .. } => {}
        };
        let id = match mutation {
            Mutation::Archive { thread_id }
            | Mutation::Unarchive { thread_id }
            | Mutation::MarkRead { thread_id, .. }
            | Mutation::Star { thread_id, .. }
            | Mutation::ModifyLabel { thread_id, .. }
            | Mutation::Trash { thread_id } => thread_id,
            // Nothing changes locally for outgoing mail (no Sent view in M1).
            Mutation::Send { .. } | Mutation::SaveDraft { .. } | Mutation::DeleteDraft { .. } => {
                return Ok(())
            }
        };
        let t = g
            .threads
            .get_mut(id)
            .ok_or_else(|| StoreError(format!("unknown thread {id}")))?;
        apply(t);
        Ok(())
    }

    fn outbox_push(&self, account_id: &AccountId, mutation: &Mutation) -> Result<(), StoreError> {
        let mut g = self.inner.lock().unwrap();
        g.next_outbox_id += 1;
        let id = g.next_outbox_id;
        g.outbox.push(OutboxItem {
            id,
            account_id: account_id.clone(),
            mutation: mutation.clone(),
            attempts: 0,
            created_at: 0,
        });
        Ok(())
    }

    fn outbox_list(&self, limit: u32) -> Result<Vec<OutboxItem>, StoreError> {
        let g = self.inner.lock().unwrap();
        Ok(g.outbox.iter().take(limit as usize).cloned().collect())
    }

    fn outbox_delete(&self, id: i64) -> Result<(), StoreError> {
        let mut g = self.inner.lock().unwrap();
        g.outbox.retain(|i| i.id != id);
        Ok(())
    }

    fn outbox_bump_attempts(&self, id: i64) -> Result<(), StoreError> {
        let mut g = self.inner.lock().unwrap();
        if let Some(item) = g.outbox.iter_mut().find(|i| i.id == id) {
            item.attempts += 1;
        }
        Ok(())
    }

    fn set_schedule(
        &self,
        thread_id: &ThreadId,
        scheduled_at: Option<i64>,
    ) -> Result<bool, StoreError> {
        let mut g = self.inner.lock().unwrap();
        match g.threads.get_mut(thread_id) {
            Some(t) => {
                t.scheduled_at = scheduled_at;
                Ok(true)
            }
            None => Ok(false),
        }
    }

    fn set_needs_reply(&self, thread_id: &ThreadId, needs_reply: bool) -> Result<bool, StoreError> {
        let mut g = self.inner.lock().unwrap();
        match g.threads.get_mut(thread_id) {
            Some(t) => {
                t.needs_reply = needs_reply;
                Ok(true)
            }
            None => Ok(false),
        }
    }

    fn set_follow_up(
        &self,
        thread_id: &ThreadId,
        follow_up_since: Option<i64>,
    ) -> Result<bool, StoreError> {
        let mut g = self.inner.lock().unwrap();
        match g.threads.get_mut(thread_id) {
            Some(t) => {
                t.follow_up_since = follow_up_since;
                Ok(true)
            }
            None => Ok(false),
        }
    }

    fn sync_device_id(&self) -> Result<String, StoreError> {
        let mut g = self.inner.lock().unwrap();
        if g.device_id.is_none() {
            // Deterministic-enough for tests; the SQLite adapter uses randomblob.
            let n = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0);
            g.device_id = Some(format!("mem-{n:x}"));
        }
        Ok(g.device_id.clone().unwrap())
    }

    fn sync_entries(&self, account_id: &AccountId) -> Result<Vec<SyncEntry>, StoreError> {
        let g = self.inner.lock().unwrap();
        let mut v: Vec<SyncEntry> = g
            .sync_kv
            .get(account_id)
            .map(|m| m.values().cloned().collect())
            .unwrap_or_default();
        v.sort_by(|a, b| a.key.cmp(&b.key));
        Ok(v)
    }

    fn sync_merge(
        &self,
        account_id: &AccountId,
        entries: &[SyncEntry],
    ) -> Result<Vec<String>, StoreError> {
        let mut g = self.inner.lock().unwrap();
        if !g.accounts.contains_key(account_id) {
            return Err(StoreError(format!("unknown account {account_id}")));
        }
        let map = g.sync_kv.entry(account_id.clone()).or_default();
        let mut changed = Vec::new();
        for e in entries {
            let wins = map.get(&e.key).map_or(true, |cur| e.is_newer_than(cur));
            if wins {
                map.insert(e.key.clone(), e.clone());
                changed.push(e.key.clone());
            }
        }
        Ok(changed)
    }

    fn sync_meta_get(
        &self,
        account_id: &AccountId,
        key: &str,
    ) -> Result<Option<String>, StoreError> {
        let g = self.inner.lock().unwrap();
        Ok(g.sync_meta
            .get(&(account_id.clone(), key.to_string()))
            .cloned())
    }

    fn sync_meta_set(
        &self,
        account_id: &AccountId,
        key: &str,
        value: &str,
    ) -> Result<(), StoreError> {
        let mut g = self.inner.lock().unwrap();
        g.sync_meta
            .insert((account_id.clone(), key.to_string()), value.to_string());
        Ok(())
    }
}

// ------------------------------------------------------------ MemTransport

/// In-memory `SyncTransport`: one shared "cloud" that several `MemStore`
/// devices sync through. Counts calls so tests can assert nothing is
/// re-downloaded or re-uploaded needlessly.
#[derive(Default)]
pub struct MemTransport {
    inner: Mutex<MemTransportInner>,
}

#[derive(Default)]
struct MemTransportInner {
    /// account → file id → (name, bytes)
    files: HashMap<AccountId, HashMap<String, (String, Vec<u8>)>>,
    next_id: u64,
    uploads: usize,
    downloads: usize,
    fail: bool,
}

impl MemTransport {
    pub fn uploads(&self) -> usize {
        self.inner.lock().unwrap().uploads
    }
    pub fn downloads(&self) -> usize {
        self.inner.lock().unwrap().downloads
    }
    pub fn file_count(&self, account_id: &AccountId) -> usize {
        self.inner
            .lock()
            .unwrap()
            .files
            .get(account_id)
            .map_or(0, |m| m.len())
    }
    /// Simulate the user wiping the app's data folder.
    pub fn clear(&self, account_id: &AccountId) {
        self.inner.lock().unwrap().files.remove(account_id);
    }
    /// Make every call fail with a network error (or stop doing so).
    pub fn fail(&self, fail: bool) {
        self.inner.lock().unwrap().fail = fail;
    }
}

fn mem_fingerprint(bytes: &[u8]) -> String {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    bytes.hash(&mut h);
    format!("{:016x}", h.finish())
}

impl SyncTransport for MemTransport {
    async fn list(&self, account_id: &AccountId) -> Result<Vec<RemoteFile>, SyncError> {
        let g = self.inner.lock().unwrap();
        if g.fail {
            return Err(SyncError::Network("fake outage".into()));
        }
        let mut v: Vec<RemoteFile> = g
            .files
            .get(account_id)
            .map(|m| {
                m.iter()
                    .map(|(id, (name, bytes))| RemoteFile {
                        id: id.clone(),
                        name: name.clone(),
                        fingerprint: mem_fingerprint(bytes),
                    })
                    .collect()
            })
            .unwrap_or_default();
        v.sort_by(|a, b| a.id.cmp(&b.id));
        Ok(v)
    }

    async fn download(&self, account_id: &AccountId, file_id: &str) -> Result<Vec<u8>, SyncError> {
        let mut g = self.inner.lock().unwrap();
        if g.fail {
            return Err(SyncError::Network("fake outage".into()));
        }
        g.downloads += 1;
        g.files
            .get(account_id)
            .and_then(|m| m.get(file_id))
            .map(|(_, b)| b.clone())
            .ok_or(SyncError::NotFound)
    }

    async fn upload(
        &self,
        account_id: &AccountId,
        file_id: Option<&str>,
        name: &str,
        bytes: Vec<u8>,
    ) -> Result<RemoteFile, SyncError> {
        let mut g = self.inner.lock().unwrap();
        if g.fail {
            return Err(SyncError::Network("fake outage".into()));
        }
        g.uploads += 1;
        let id = match file_id {
            Some(id) => {
                if !g.files.get(account_id).is_some_and(|m| m.contains_key(id)) {
                    return Err(SyncError::NotFound);
                }
                id.to_string()
            }
            None => {
                g.next_id += 1;
                format!("f{}", g.next_id)
            }
        };
        let fingerprint = mem_fingerprint(&bytes);
        g.files
            .entry(account_id.clone())
            .or_default()
            .insert(id.clone(), (name.to_string(), bytes));
        Ok(RemoteFile {
            id,
            name: name.to_string(),
            fingerprint,
        })
    }
}

// ------------------------------------------------------------ FakeProvider

/// In-memory `MailProvider` with deterministic sample data and failure toggles.
pub struct FakeProvider {
    account_id: AccountId,
    threads: Vec<(Thread, Vec<Message>)>,
    page_size: usize,
    applied: Mutex<Vec<(AccountId, Mutation)>>,
    fail_applies: Mutex<bool>,
    history: Mutex<Vec<HistoryChange>>,
    latest_history_id: Mutex<String>,
    history_expired: Mutex<bool>,
    /// Push watch bookkeeping: every `watch` call, every `stop_watch` call,
    /// the expiration the next `watch` reports, and a failure toggle.
    watch_calls: Mutex<Vec<(AccountId, String)>>,
    stop_calls: Mutex<Vec<AccountId>>,
    watch_expiration_ms: Mutex<i64>,
    fail_watch: Mutex<bool>,
}

impl FakeProvider {
    /// `n` threads, one message each, newest first, paged by `page_size`.
    pub fn with_sample_data(account_id: &str, n: usize, page_size: usize) -> Self {
        let base_ms: i64 = 1_756_600_000_000; // fixed epoch for determinism
        let threads = (0..n)
            .map(|i| {
                let tid = format!("{account_id}:t{i}");
                let last_msg_at = base_ms - (i as i64) * 3_600_000;
                let thread = Thread {
                    id: tid.clone(),
                    account_id: account_id.to_string(),
                    subject: format!("Sample thread {i}"),
                    snippet: format!("Snippet for thread {i}…"),
                    last_msg_at,
                    is_read: i % 3 != 0,
                    is_inbox: true,
                    is_archived: false,
                    msg_count: 1,
                    from_summary: format!("Sender {i}"),
                    last_from_addr: format!("sender{i}@example.com"),
                    scheduled_at: None,
                    needs_reply: false,
                    follow_up_since: None,
                    labels: vec!["INBOX".to_string()],
                    // Every 5th sample thread carries an attachment — just
                    // enough variety to eyeball the icon in Fake-backend dev mode.
                    has_attachment: i % 5 == 0,
                    priority: None,
                    triage_label_ids: Vec::new(),
                };
                let message = Message {
                    id: format!("{tid}:m0"),
                    thread_id: tid,
                    account_id: account_id.to_string(),
                    from_addr: format!("sender{i}@example.com"),
                    to_addrs: vec![format!("{account_id}@example.com")],
                    date: last_msg_at,
                    snippet: format!("Snippet for thread {i}…"),
                    body_html: None,
                    body_text: Some(format!("Body of sample thread {i}.")),
                    label_ids: vec!["INBOX".to_string()],
                    is_read: i % 3 != 0,
                };
                (thread, vec![message])
            })
            .collect();
        Self {
            account_id: account_id.to_string(),
            threads,
            page_size,
            applied: Mutex::new(Vec::new()),
            fail_applies: Mutex::new(false),
            history: Mutex::new(Vec::new()),
            latest_history_id: Mutex::new("hist-1".to_string()),
            history_expired: Mutex::new(false),
            watch_calls: Mutex::new(Vec::new()),
            stop_calls: Mutex::new(Vec::new()),
            watch_expiration_ms: Mutex::new(0),
            fail_watch: Mutex::new(false),
        }
    }

    /// Queue a history change and advance the fake's latest history id.
    pub fn push_history(&self, change: HistoryChange, new_history_id: &str) {
        self.history.lock().unwrap().push(change);
        *self.latest_history_id.lock().unwrap() = new_history_id.to_string();
    }

    /// Make `list_history` return `HistoryExpired` (Gmail 404 on an old id).
    pub fn expire_history(&self) {
        *self.history_expired.lock().unwrap() = true;
    }

    pub fn applied_mutations(&self) -> Vec<(AccountId, Mutation)> {
        self.applied.lock().unwrap().clone()
    }

    pub fn fail_applies(&self, fail: bool) {
        *self.fail_applies.lock().unwrap() = fail;
    }

    /// Expiration (epoch ms) the next `watch` call reports.
    pub fn set_watch_expiration(&self, expiration_ms: i64) {
        *self.watch_expiration_ms.lock().unwrap() = expiration_ms;
    }

    /// Make `watch` / `stop_watch` fail with a provider error.
    pub fn fail_watch(&self, fail: bool) {
        *self.fail_watch.lock().unwrap() = fail;
    }

    pub fn watch_calls(&self) -> Vec<(AccountId, String)> {
        self.watch_calls.lock().unwrap().clone()
    }

    pub fn stop_calls(&self) -> Vec<AccountId> {
        self.stop_calls.lock().unwrap().clone()
    }
}

impl MailProvider for FakeProvider {
    async fn profile(&self, _account_id: &AccountId) -> Result<Profile, MailError> {
        Ok(Profile {
            email: format!("{}@example.com", self.account_id),
            history_id: "hist-1".to_string(),
        })
    }

    async fn list_labels(&self, account_id: &AccountId) -> Result<Vec<Label>, MailError> {
        Ok(vec![
            Label {
                account_id: account_id.clone(),
                id: "Label_1".to_string(),
                name: "Projects".to_string(),
            },
            Label {
                account_id: account_id.clone(),
                id: "Label_2".to_string(),
                name: "Invoices".to_string(),
            },
        ])
    }

    async fn list_recent(
        &self,
        _account_id: &AccountId,
        _window_days: u32,
        page_token: Option<String>,
    ) -> Result<ThreadPage, MailError> {
        let start: usize = page_token
            .as_deref()
            .map(|t| t.parse().unwrap_or(0))
            .unwrap_or(0);
        let end = (start + self.page_size).min(self.threads.len());
        let next = (end < self.threads.len()).then(|| end.to_string());
        Ok(ThreadPage {
            threads: self.threads[start..end].to_vec(),
            next_page_token: next,
        })
    }

    async fn list_before(
        &self,
        _account_id: &AccountId,
        before_ms: i64,
        page_token: Option<String>,
    ) -> Result<ThreadPage, MailError> {
        let older: Vec<_> = self
            .threads
            .iter()
            .filter(|(t, _)| t.last_msg_at < before_ms)
            .cloned()
            .collect();
        let start: usize = page_token
            .as_deref()
            .map(|t| t.parse().unwrap_or(0))
            .unwrap_or(0);
        let end = (start + self.page_size).min(older.len());
        let next = (end < older.len()).then(|| end.to_string());
        Ok(ThreadPage {
            threads: older[start..end].to_vec(),
            next_page_token: next,
        })
    }

    async fn list_history(
        &self,
        _account_id: &AccountId,
        start_history_id: &str,
        _page_token: Option<String>,
    ) -> Result<HistoryPage, MailError> {
        if *self.history_expired.lock().unwrap() {
            return Err(MailError::HistoryExpired);
        }
        let latest = self.latest_history_id.lock().unwrap().clone();
        // Caught up — empty feed, like Gmail's cheap no-op response.
        let changes = if start_history_id == latest {
            Vec::new()
        } else {
            self.history.lock().unwrap().clone()
        };
        Ok(HistoryPage {
            changes,
            next_page_token: None,
            latest_history_id: latest,
        })
    }

    async fn fetch_bodies(
        &self,
        _account_id: &AccountId,
        thread_id: &ThreadId,
    ) -> Result<(bool, Vec<Message>), MailError> {
        Ok(self
            .threads
            .iter()
            .find(|(t, _)| &t.id == thread_id)
            .map(|(t, msgs)| (t.has_attachment, msgs.clone()))
            .unwrap_or_default())
    }

    async fn apply(&self, account_id: &AccountId, mutation: &Mutation) -> Result<(), MailError> {
        if *self.fail_applies.lock().unwrap() {
            return Err(MailError::Network("fake failure".to_string()));
        }
        self.applied
            .lock()
            .unwrap()
            .push((account_id.clone(), mutation.clone()));
        Ok(())
    }

    async fn watch(&self, account_id: &AccountId, topic: &str) -> Result<WatchState, MailError> {
        if *self.fail_watch.lock().unwrap() {
            return Err(MailError::Provider("fake watch failure".to_string()));
        }
        self.watch_calls
            .lock()
            .unwrap()
            .push((account_id.clone(), topic.to_string()));
        Ok(WatchState {
            history_id: self.latest_history_id.lock().unwrap().clone(),
            expiration_ms: *self.watch_expiration_ms.lock().unwrap(),
        })
    }

    async fn stop_watch(&self, account_id: &AccountId) -> Result<(), MailError> {
        if *self.fail_watch.lock().unwrap() {
            return Err(MailError::Provider("fake stop failure".to_string()));
        }
        self.stop_calls.lock().unwrap().push(account_id.clone());
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn thread(id: &str, labels: &[&str]) -> Thread {
        Thread {
            id: id.to_string(),
            account_id: "a1".to_string(),
            subject: String::new(),
            snippet: String::new(),
            last_msg_at: 1000,
            is_read: true,
            is_inbox: true,
            is_archived: false,
            msg_count: 1,
            from_summary: String::new(),
            last_from_addr: String::new(),
            scheduled_at: None,
            needs_reply: false,
            follow_up_since: None,
            labels: labels.iter().map(|s| s.to_string()).collect(),
            has_attachment: false,
            priority: None,
            triage_label_ids: Vec::new(),
        }
    }

    // Mirrors the SQLite adapter's star/modify-label tests — keep in lockstep.
    #[test]
    fn memstore_star_and_modify_label_flip_labels_only() {
        let s = MemStore::default();
        s.upsert_thread(&thread("t1", &["INBOX"])).unwrap();
        let star = |on: bool| Mutation::Star {
            thread_id: "t1".to_string(),
            starred: on,
        };
        s.apply_local(&star(true)).unwrap();
        let t = s.get_thread(&"t1".to_string()).unwrap().unwrap();
        assert_eq!(t.labels, ["INBOX", "STARRED"]);
        assert!(
            t.is_inbox && !t.is_archived,
            "star must not move the thread"
        );
        assert_eq!(
            s.list_threads(None, &ThreadFilter::Starred, None, 10)
                .unwrap()
                .len(),
            1
        );
        s.apply_local(&star(true)).unwrap(); // idempotent — no duplicate label
        assert_eq!(
            s.get_thread(&"t1".to_string()).unwrap().unwrap().labels,
            ["INBOX", "STARRED"]
        );
        s.apply_local(&star(false)).unwrap();
        assert_eq!(
            s.get_thread(&"t1".to_string()).unwrap().unwrap().labels,
            ["INBOX"]
        );
        let flip = |add: bool| Mutation::ModifyLabel {
            thread_id: "t1".to_string(),
            label_id: "Label_7".to_string(),
            add,
        };
        s.apply_local(&flip(true)).unwrap();
        assert_eq!(
            s.list_threads(None, &ThreadFilter::Label("Label_7".to_string()), None, 10)
                .unwrap()
                .len(),
            1
        );
        s.apply_local(&flip(false)).unwrap();
        let t = s.get_thread(&"t1".to_string()).unwrap().unwrap();
        assert_eq!(t.labels, ["INBOX"]);
        assert!(t.is_inbox && !t.is_archived);
    }

    #[test]
    fn future_schedule_hides_thread_from_inbox_until_due() {
        let s = MemStore::default();
        s.upsert_thread(&thread("later", &["INBOX"])).unwrap();
        s.upsert_thread(&thread("now", &["INBOX"])).unwrap();
        let inbox = |s: &MemStore| {
            let mut v: Vec<String> = s
                .list_threads(None, &ThreadFilter::Inbox, None, 10)
                .unwrap()
                .into_iter()
                .map(|t| t.id)
                .collect();
            v.sort();
            v
        };
        s.set_schedule(&"later".to_string(), Some(now_ms() + 86_400_000))
            .unwrap();
        s.set_schedule(&"now".to_string(), Some(now_ms() - 60_000))
            .unwrap();
        assert_eq!(inbox(&s), ["now"], "snoozed thread leaves the inbox");
        assert_eq!(
            s.list_threads(None, &ThreadFilter::All, None, 10)
                .unwrap()
                .len(),
            2,
            "All mail still shows it"
        );
        s.set_schedule(&"later".to_string(), None).unwrap();
        assert_eq!(
            inbox(&s),
            ["later", "now"],
            "clearing the schedule restores it"
        );
    }
}
