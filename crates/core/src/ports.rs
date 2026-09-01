//! Ports (traits). One per external dependency that realistically changes.
//! The whitelist lives in DESIGN.md — nothing else earns a trait.

use crate::domain::*;

#[derive(Debug, thiserror::Error)]
pub enum MailError {
    #[error("authentication expired or revoked")]
    AuthExpired,
    #[error("rate limited, retry after {retry_after_secs:?}s")]
    RateLimited { retry_after_secs: Option<u64> },
    #[error("history id too old, full re-sync required")]
    HistoryExpired,
    #[error("network: {0}")]
    Network(String),
    #[error("provider: {0}")]
    Provider(String),
}

#[derive(Debug, thiserror::Error)]
#[error("store: {0}")]
pub struct StoreError(pub String);

/// One page of thread metadata from the provider.
#[derive(Debug, Clone)]
pub struct ThreadPage {
    pub threads: Vec<(Thread, Vec<Message>)>,
    pub next_page_token: Option<String>,
}

/// One change from the provider's history feed since a checkpoint.
#[derive(Debug, Clone)]
pub enum HistoryChange {
    /// New mail. The adapter refetches the whole thread (metadata tier) —
    /// the history feed itself carries no headers, and the fresh thread
    /// snapshot makes applying the change a plain upsert.
    MessageAdded {
        thread: Thread,
        messages: Vec<Message>,
    },
    MessageDeleted {
        thread_id: ThreadId,
        message_id: MessageId,
    },
    LabelsAdded {
        thread_id: ThreadId,
        message_id: MessageId,
        labels: Vec<String>,
    },
    LabelsRemoved {
        thread_id: ThreadId,
        message_id: MessageId,
        labels: Vec<String>,
    },
}

/// One page of the provider's history feed.
#[derive(Debug, Clone)]
pub struct HistoryPage {
    pub changes: Vec<HistoryChange>,
    pub next_page_token: Option<String>,
    /// Checkpoint to store once the whole feed has been applied.
    pub latest_history_id: String,
}

/// Mail backend (Gmail REST in v1). Async because it's all network.
pub trait MailProvider {
    fn profile(
        &self,
        account_id: &AccountId,
    ) -> impl std::future::Future<Output = Result<Profile, MailError>> + Send;

    /// List threads (with message metadata) newer than `window_days`, newest first.
    fn list_recent(
        &self,
        account_id: &AccountId,
        window_days: u32,
        page_token: Option<String>,
    ) -> impl std::future::Future<Output = Result<ThreadPage, MailError>> + Send;

    /// The account's labels (Gmail `users.labels.list`), user-created only
    /// — system labels are folders, not sidebar labels. Default: none, so
    /// providers without label support keep compiling (DESIGN.md: new
    /// capability = method with default).
    fn list_labels(
        &self,
        account_id: &AccountId,
    ) -> impl std::future::Future<Output = Result<Vec<Label>, MailError>> + Send {
        let _ = account_id;
        async { Ok(Vec::new()) }
    }

    /// Changes since `start_history_id` (Gmail `users.history.list`).
    /// Must return `MailError::HistoryExpired` when the checkpoint is too
    /// old for the provider (Gmail 404) — the caller re-runs backfill.
    fn list_history(
        &self,
        account_id: &AccountId,
        start_history_id: &str,
        page_token: Option<String>,
    ) -> impl std::future::Future<Output = Result<HistoryPage, MailError>> + Send;

    /// Full messages (with bodies) for one thread — fetched lazily when the
    /// user opens a thread whose bodies are not local yet.
    fn fetch_bodies(
        &self,
        account_id: &AccountId,
        thread_id: &ThreadId,
    ) -> impl std::future::Future<Output = Result<Vec<Message>, MailError>> + Send;

    /// Apply one local mutation remotely (used by the outbox drain).
    fn apply(
        &self,
        account_id: &AccountId,
        mutation: &Mutation,
    ) -> impl std::future::Future<Output = Result<(), MailError>> + Send;
}

/// Local persistence (SQLite in v1). Sync trait: rusqlite is synchronous and
/// call sites wrap access in a single writer.
/// All writes are idempotent upserts keyed on provider-native ids.
pub trait Store {
    fn upsert_account(&self, account: &Account) -> Result<(), StoreError>;
    fn list_accounts(&self) -> Result<Vec<Account>, StoreError>;
    fn set_history_id(&self, account_id: &AccountId, history_id: &str) -> Result<(), StoreError>;

    fn upsert_thread(&self, thread: &Thread) -> Result<(), StoreError>;
    fn upsert_message(&self, message: &Message) -> Result<(), StoreError>;
    /// Remove one message (history `messageDeleted`). Missing id is a no-op.
    fn delete_message(&self, message_id: &MessageId) -> Result<(), StoreError>;
    /// Remove a thread and its messages (last message deleted/trashed).
    fn delete_thread(&self, thread_id: &ThreadId) -> Result<(), StoreError>;

    /// Thread list query: newest first, keyset pagination via `before`
    /// (epoch ms), scoped to one folder/label via `filter`.
    fn list_threads(
        &self,
        account_id: Option<&AccountId>,
        filter: &ThreadFilter,
        before: Option<i64>,
        limit: u32,
    ) -> Result<Vec<Thread>, StoreError>;
    fn get_thread(&self, thread_id: &ThreadId) -> Result<Option<Thread>, StoreError>;
    fn list_messages(&self, thread_id: &ThreadId) -> Result<Vec<Message>, StoreError>;

    /// Local full-text search: ranked threads + snippet preview (FTS5 in the
    /// SQLite adapter). Default impl returns nothing so existing adapters
    /// keep compiling (DESIGN.md: new capability = method with default).
    fn search(
        &self,
        query: &crate::search::SearchQuery,
        limit: u32,
    ) -> Result<Vec<SearchResult>, StoreError> {
        let _ = (query, limit);
        Ok(Vec::new())
    }

    /// Replace the stored label list for one account (sync refresh —
    /// deleted labels must disappear). Default no-op keeps existing
    /// adapters compiling.
    fn set_labels(&self, account_id: &AccountId, labels: &[Label]) -> Result<(), StoreError> {
        let _ = (account_id, labels);
        Ok(())
    }

    /// All stored labels across accounts (sidebar). Default: none.
    fn list_labels(&self) -> Result<Vec<Label>, StoreError> {
        Ok(Vec::new())
    }

    /// Apply a mutation locally (the optimistic half).
    fn apply_local(&self, mutation: &Mutation) -> Result<(), StoreError>;

    fn outbox_push(&self, account_id: &AccountId, mutation: &Mutation) -> Result<(), StoreError>;
    fn outbox_list(&self, limit: u32) -> Result<Vec<OutboxItem>, StoreError>;
    fn outbox_delete(&self, id: i64) -> Result<(), StoreError>;
    fn outbox_bump_attempts(&self, id: i64) -> Result<(), StoreError>;
}

/// OS keychain in release, file-backed in dev (macOS keychain re-prompts on
/// every unsigned rebuild otherwise).
pub trait SecretStore {
    fn get(&self, key: &str) -> Result<Option<String>, StoreError>;
    fn set(&self, key: &str, value: &str) -> Result<(), StoreError>;
    fn delete(&self, key: &str) -> Result<(), StoreError>;
}
