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
}

/// Same folder semantics as the SQLite adapter's SQL (keep in lockstep).
fn matches_filter(t: &Thread, filter: &ThreadFilter) -> bool {
    let has = |l: &str| t.labels.iter().any(|x| x == l);
    // Junk only when trashed/spam AND out of the inbox — a partially-trashed
    // thread keeps INBOX and stays in All/Starred/Sent/label views.
    let junk = (has("TRASH") || has("SPAM")) && !has("INBOX");
    match filter {
        ThreadFilter::Inbox => t.is_inbox && !t.is_archived,
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
            Mutation::Send { .. } => {}
        };
        let id = match mutation {
            Mutation::Archive { thread_id }
            | Mutation::MarkRead { thread_id, .. }
            | Mutation::Star { thread_id, .. }
            | Mutation::ModifyLabel { thread_id, .. }
            | Mutation::Trash { thread_id } => thread_id,
            // Nothing changes locally for outgoing mail (no Sent view in M1).
            Mutation::Send { .. } => return Ok(()),
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
                    labels: vec!["INBOX".to_string()],
                    // Every 5th sample thread carries an attachment — just
                    // enough variety to eyeball the icon in Fake-backend dev mode.
                    has_attachment: i % 5 == 0,
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
        Ok(HistoryPage { changes, next_page_token: None, latest_history_id: latest })
    }

    async fn fetch_bodies(
        &self,
        _account_id: &AccountId,
        thread_id: &ThreadId,
    ) -> Result<Vec<Message>, MailError> {
        Ok(self
            .threads
            .iter()
            .find(|(t, _)| &t.id == thread_id)
            .map(|(_, msgs)| msgs.clone())
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
            labels: labels.iter().map(|s| s.to_string()).collect(),
            has_attachment: false,
        }
    }

    // Mirrors the SQLite adapter's star/modify-label tests — keep in lockstep.
    #[test]
    fn memstore_star_and_modify_label_flip_labels_only() {
        let s = MemStore::default();
        s.upsert_thread(&thread("t1", &["INBOX"])).unwrap();
        let star = |on: bool| Mutation::Star { thread_id: "t1".to_string(), starred: on };
        s.apply_local(&star(true)).unwrap();
        let t = s.get_thread(&"t1".to_string()).unwrap().unwrap();
        assert_eq!(t.labels, ["INBOX", "STARRED"]);
        assert!(t.is_inbox && !t.is_archived, "star must not move the thread");
        assert_eq!(s.list_threads(None, &ThreadFilter::Starred, None, 10).unwrap().len(), 1);
        s.apply_local(&star(true)).unwrap(); // idempotent — no duplicate label
        assert_eq!(s.get_thread(&"t1".to_string()).unwrap().unwrap().labels, ["INBOX", "STARRED"]);
        s.apply_local(&star(false)).unwrap();
        assert_eq!(s.get_thread(&"t1".to_string()).unwrap().unwrap().labels, ["INBOX"]);
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
}
