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

    /// Inbox list query: newest first, keyset pagination via `before` (epoch ms).
    fn list_threads(
        &self,
        account_id: Option<&AccountId>,
        before: Option<i64>,
        limit: u32,
    ) -> Result<Vec<Thread>, StoreError>;
    fn get_thread(&self, thread_id: &ThreadId) -> Result<Option<Thread>, StoreError>;
    fn list_messages(&self, thread_id: &ThreadId) -> Result<Vec<Message>, StoreError>;

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
