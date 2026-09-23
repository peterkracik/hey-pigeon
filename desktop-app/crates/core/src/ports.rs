//! Ports (traits). One per external dependency that realistically changes.
//! The whitelist lives in DESIGN.md — nothing else earns a trait.

use crate::domain::*;
use serde::{Deserialize, Serialize};

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

    /// Rename a user label (Gmail `users.labels.patch`). Default errors so
    /// providers without label management stay honest (no silent success).
    fn update_label(
        &self,
        account_id: &AccountId,
        label_id: &str,
        new_name: &str,
    ) -> impl std::future::Future<Output = Result<(), MailError>> + Send {
        let _ = (account_id, label_id, new_name);
        async { Err(MailError::Provider("label management not supported".into())) }
    }

    /// Delete a user label (Gmail `users.labels.delete`). Default errors —
    /// see `update_label`.
    fn delete_label(
        &self,
        account_id: &AccountId,
        label_id: &str,
    ) -> impl std::future::Future<Output = Result<(), MailError>> + Send {
        let _ = (account_id, label_id);
        async { Err(MailError::Provider("label management not supported".into())) }
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
    /// user opens a thread whose bodies are not local yet. This is also the
    /// only sync tier that returns the MIME parts tree (list/backfill only
    /// ever fetch `format=metadata`, which omits `parts` entirely), so it's
    /// the sole place `has_attachment` can be (re)computed accurately; the
    /// caller is expected to persist it onto the thread.
    fn fetch_bodies(
        &self,
        account_id: &AccountId,
        thread_id: &ThreadId,
    ) -> impl std::future::Future<Output = Result<(bool, Vec<Message>), MailError>> + Send;

    /// Apply one local mutation remotely (used by the outbox drain).
    fn apply(
        &self,
        account_id: &AccountId,
        mutation: &Mutation,
    ) -> impl std::future::Future<Output = Result<(), MailError>> + Send;
}

#[derive(Debug, thiserror::Error)]
pub enum AiError {
    #[error("invalid or revoked API key")]
    AuthInvalid,
    #[error("rate limited, retry after {retry_after_secs:?}s")]
    RateLimited { retry_after_secs: Option<u64> },
    #[error("network: {0}")]
    Network(String),
    #[error("provider: {0}")]
    Provider(String),
}

/// One selectable model. `models()` is a static/local list — never a
/// network call (that's what `verify()` is for).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelInfo {
    pub id: String,
    pub label: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ChatRole {
    System,
    User,
    Assistant,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatMessage {
    pub role: ChatRole,
    pub content: String,
}

#[derive(Debug, Clone)]
pub struct CompletionRequest {
    pub model: String,
    pub messages: Vec<ChatMessage>,
}

/// AI backend (BYO API key, provider-pluggable — DESIGN.md "AI features").
/// Everything feature code calls goes through this trait, never a concrete
/// provider, so a second provider is one new adapter crate, zero feature
/// code changes.
pub trait AiProvider {
    /// Stable id, e.g. "openai".
    fn id(&self) -> &str;
    /// Selectable models; callers treat the first as the recommended default.
    fn models(&self) -> Vec<ModelInfo>;

    /// Run one completion request.
    /// ponytail: returns the whole response at once rather than a token
    /// stream — no caller needs incremental rendering yet (summarize/draft
    /// reply are a later milestone). Widen this to a
    /// `Stream<Item = Token>` when one lands; this is the one call site
    /// that changes.
    fn complete(
        &self,
        req: CompletionRequest,
    ) -> impl std::future::Future<Output = Result<String, AiError>> + Send;

    /// Confirm the configured credentials actually work — the
    /// "authenticate" step run once before a freshly pasted key is
    /// persisted (mirrors `MailProvider::profile` in the Gmail OAuth flow).
    /// Default: a minimal `complete()` call (costs a few tokens); adapters
    /// override with a free provider-native check when one exists.
    fn verify(&self) -> impl std::future::Future<Output = Result<(), AiError>> + Send
    where
        Self: Sync,
    {
        async move {
            let model = self
                .models()
                .into_iter()
                .next()
                .map(|m| m.id)
                .unwrap_or_default();
            self.complete(CompletionRequest {
                model,
                messages: vec![ChatMessage {
                    role: ChatRole::User,
                    content: "ping".to_string(),
                }],
            })
            .await
            .map(|_| ())
        }
    }
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

    /// Unread thread count for one folder/label filter (sidebar badges).
    /// Default: filters `list_threads` (correct but unindexed) so existing
    /// adapters keep compiling; the SQLite adapter overrides with a real
    /// COUNT query.
    fn count_unread(
        &self,
        account_id: Option<&AccountId>,
        filter: &ThreadFilter,
    ) -> Result<i64, StoreError> {
        Ok(self
            .list_threads(account_id, filter, None, u32::MAX)?
            .iter()
            .filter(|t| !t.is_read)
            .count() as i64)
    }

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

    // ---- AI triage (Jev): local-only labels + priority ----
    // Default impls keep pre-triage adapters compiling; the SQLite adapter
    // and MemStore implement all of them.

    /// All user-defined triage categories (Settings "Triage" list).
    fn list_triage_labels(&self) -> Result<Vec<TriageLabel>, StoreError> {
        Ok(Vec::new())
    }

    /// Create a new local triage category. Also invalidates every thread's
    /// triage version (see `list_threads_needing_triage`) so the new label
    /// gets a chance to match existing mail, not just future mail.
    fn create_triage_label(&self, name: &str) -> Result<TriageLabel, StoreError> {
        let _ = name;
        Err(StoreError("triage not supported by this store".into()))
    }

    fn rename_triage_label(&self, id: &str, new_name: &str) -> Result<(), StoreError> {
        let _ = (id, new_name);
        Err(StoreError("triage not supported by this store".into()))
    }

    /// Delete a triage category; must also strip it from every thread it
    /// was applied to (mirrors `Store::delete_label`'s Gmail-side cleanup).
    fn delete_triage_label(&self, id: &str) -> Result<(), StoreError> {
        let _ = id;
        Err(StoreError("triage not supported by this store".into()))
    }

    /// Threads whose triage is missing or stale: never classified, or a
    /// message arrived since (`msg_count` grew), or a label was added/
    /// removed/renamed since (`create_triage_label` bumps everyone stale).
    /// Bounded by `limit` — the caller polls this repeatedly, it does not
    /// need every stale thread at once.
    fn list_threads_needing_triage(&self, limit: u32) -> Result<Vec<Thread>, StoreError> {
        let _ = limit;
        Ok(Vec::new())
    }

    /// Persist one thread's Jev result: sets `priority` and records
    /// `at_msg_count` as the version this classification covers so
    /// `list_threads_needing_triage` stops returning it until the thread
    /// changes again. Wholesale-replaces `label_ids` (like `set_labels`)
    /// UNLESS the user has manually edited this thread's labels
    /// (`set_manual_triage_labels`) — a manual choice is sticky and must
    /// survive Jev re-classifying the thread for a new message.
    fn set_thread_triage(
        &self,
        thread_id: &ThreadId,
        label_ids: &[String],
        priority: Priority,
        at_msg_count: i64,
    ) -> Result<(), StoreError> {
        let _ = (thread_id, label_ids, priority, at_msg_count);
        Err(StoreError("triage not supported by this store".into()))
    }

    /// User-driven label edit (the footer "+" menu / badge ×). Wholesale-
    /// replaces the thread's triage labels AND marks them manually pinned,
    /// so future `set_thread_triage` calls leave them alone — only
    /// `reset_triage` ("Reanalyze all emails") clears the pin.
    fn set_manual_triage_labels(
        &self,
        thread_id: &ThreadId,
        label_ids: &[String],
    ) -> Result<(), StoreError> {
        let _ = (thread_id, label_ids);
        Err(StoreError("triage not supported by this store".into()))
    }

    /// Force every thread stale for triage (Settings "Reanalyze all
    /// emails"). Same mechanism `create_triage_label` already uses when a
    /// new label is added — doesn't clear existing labels/priority, they
    /// just get overwritten as `list_threads_needing_triage` reaches each
    /// thread again, bounded by the poller's per-tick cap. Also clears any
    /// manual label pins — an explicit "reanalyze everything" should give
    /// Jev a fresh shot rather than staying blocked by old manual edits.
    fn reset_triage(&self) -> Result<(), StoreError> {
        Ok(())
    }

    /// Apply a mutation locally (the optimistic half).
    fn apply_local(&self, mutation: &Mutation) -> Result<(), StoreError>;

    fn outbox_push(&self, account_id: &AccountId, mutation: &Mutation) -> Result<(), StoreError>;
    fn outbox_list(&self, limit: u32) -> Result<Vec<OutboxItem>, StoreError>;
    fn outbox_delete(&self, id: i64) -> Result<(), StoreError>;
    fn outbox_bump_attempts(&self, id: i64) -> Result<(), StoreError>;

    /// Set or clear a thread's "remind me" schedule (epoch ms). Local
    /// metadata, never sent to the mail provider — it travels between the
    /// user's devices via `SyncTransport` instead. Ok(false) = unknown
    /// thread (a reminder can arrive from another device before the
    /// thread itself is backfilled here; the caller retries later).
    fn set_schedule(
        &self,
        thread_id: &ThreadId,
        scheduled_at: Option<i64>,
    ) -> Result<bool, StoreError>;

    // ---- cross-device sync map (DESIGN.md "Cross-device sync") ----
    // Default impls keep pre-sync adapters compiling; the SQLite adapter
    // and MemStore implement all of them.

    /// Stable random id for this install, created on first call. Names this
    /// device's state file and breaks LWW timestamp ties.
    fn sync_device_id(&self) -> Result<String, StoreError> {
        Err(StoreError("sync not supported by this store".into()))
    }

    /// Every entry for one account, sorted by key (a deterministic order
    /// makes equal state serialize to equal bytes).
    fn sync_entries(&self, account_id: &AccountId) -> Result<Vec<SyncEntry>, StoreError> {
        let _ = account_id;
        Ok(Vec::new())
    }

    /// Last-writer-wins upsert: each entry replaces the stored one only if
    /// `SyncEntry::is_newer_than` it (or none is stored). Returns the keys
    /// whose stored entry changed.
    fn sync_merge(
        &self,
        account_id: &AccountId,
        entries: &[SyncEntry],
    ) -> Result<Vec<String>, StoreError> {
        let _ = (account_id, entries);
        Err(StoreError("sync not supported by this store".into()))
    }

    /// Small per-account bookkeeping for the sync loop (remote file id,
    /// fingerprints of what was last uploaded / downloaded).
    fn sync_meta_get(
        &self,
        account_id: &AccountId,
        key: &str,
    ) -> Result<Option<String>, StoreError> {
        let _ = (account_id, key);
        Ok(None)
    }

    fn sync_meta_set(
        &self,
        account_id: &AccountId,
        key: &str,
        value: &str,
    ) -> Result<(), StoreError> {
        let _ = (account_id, key, value);
        Err(StoreError("sync not supported by this store".into()))
    }
}

#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error("authentication expired or revoked")]
    AuthExpired,
    /// The account's grant lacks the sync scope, or the backing API is not
    /// enabled in the user's OAuth project. Needs a re-connect / setup
    /// step, not a retry — callers log once and stop hammering.
    #[error("sync unavailable: {0}")]
    Unavailable(String),
    /// The addressed remote file no longer exists (deleted out of band).
    #[error("remote file not found")]
    NotFound,
    #[error("network: {0}")]
    Network(String),
    #[error("provider: {0}")]
    Provider(String),
}

/// One file in the account's hidden sync folder. `fingerprint` changes
/// whenever the content does (Drive: md5Checksum) so unchanged files are
/// never re-downloaded.
#[derive(Debug, Clone, PartialEq)]
pub struct RemoteFile {
    pub id: String,
    pub name: String,
    pub fingerprint: String,
}

/// Blob store for the per-device sync state files, scoped per account
/// (Drive `appDataFolder` in v1 — DESIGN.md "Cross-device sync"). The core
/// only needs list / download / upload of small named files; anything
/// with those three (iCloud, WebDAV, a directory) can replace it.
pub trait SyncTransport {
    fn list(
        &self,
        account_id: &AccountId,
    ) -> impl std::future::Future<Output = Result<Vec<RemoteFile>, SyncError>> + Send;

    fn download(
        &self,
        account_id: &AccountId,
        file_id: &str,
    ) -> impl std::future::Future<Output = Result<Vec<u8>, SyncError>> + Send;

    /// Create (`file_id` None) or replace (`Some`) one file's content.
    /// Must return `SyncError::NotFound` when replacing a file that is
    /// gone, so the caller can fall back to creating it.
    fn upload(
        &self,
        account_id: &AccountId,
        file_id: Option<&str>,
        name: &str,
        bytes: Vec<u8>,
    ) -> impl std::future::Future<Output = Result<RemoteFile, SyncError>> + Send;
}

/// OS keychain in release, file-backed in dev (macOS keychain re-prompts on
/// every unsigned rebuild otherwise).
pub trait SecretStore {
    fn get(&self, key: &str) -> Result<Option<String>, StoreError>;
    fn set(&self, key: &str, value: &str) -> Result<(), StoreError>;
    fn delete(&self, key: &str) -> Result<(), StoreError>;
}
