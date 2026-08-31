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
    outbox: Vec<OutboxItem>,
    next_outbox_id: i64,
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
        g.threads.insert(thread.id.clone(), thread.clone());
        Ok(())
    }

    fn upsert_message(&self, message: &Message) -> Result<(), StoreError> {
        let mut g = self.inner.lock().unwrap();
        g.messages.insert(message.id.clone(), message.clone());
        Ok(())
    }

    fn list_threads(
        &self,
        account_id: Option<&AccountId>,
        before: Option<i64>,
        limit: u32,
    ) -> Result<Vec<Thread>, StoreError> {
        let g = self.inner.lock().unwrap();
        let mut v: Vec<_> = g
            .threads
            .values()
            .filter(|t| t.is_inbox && !t.is_archived)
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

    fn apply_local(&self, mutation: &Mutation) -> Result<(), StoreError> {
        let mut g = self.inner.lock().unwrap();
        let apply = |t: &mut Thread| match mutation {
            Mutation::Archive { .. } => {
                t.is_archived = true;
                t.is_inbox = false;
            }
            Mutation::MarkRead { read, .. } => t.is_read = *read,
            Mutation::Trash { .. } => {
                t.is_inbox = false;
            }
        };
        let id = match mutation {
            Mutation::Archive { thread_id }
            | Mutation::MarkRead { thread_id, .. }
            | Mutation::Trash { thread_id } => thread_id,
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
        }
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
