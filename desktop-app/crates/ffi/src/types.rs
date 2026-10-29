//! FFI records/enums mirroring the core domain types, plus the conversions.
//! Kept as explicit copies (not `uniffi` derives on the core types) so the
//! core stays free of binding concerns — same reason `ipc.ts` re-declares
//! the shapes on the TypeScript side.
//!
//! Naming: `MailThread` / `MailMessage` / `MailLabel` rather than the core's
//! names, because `Thread`, `Message` and `Label` already exist in
//! Foundation / SwiftUI and would be ambiguous at every use site in Swift.

use heypigeon_core::domain;

#[derive(Debug, Clone, uniffi::Record)]
pub struct Account {
    pub id: String,
    pub email: String,
    pub display_name: String,
    /// One of sky | lavender | mint | amber | coral (DESIGN.md account dot).
    pub color: String,
    pub avatar_url: Option<String>,
    pub signature: String,
}

impl From<domain::Account> for Account {
    fn from(a: domain::Account) -> Self {
        Self {
            id: a.id,
            email: a.email,
            display_name: a.display_name,
            color: a.color,
            avatar_url: a.avatar_url,
            signature: a.signature,
        }
    }
}

/// AI-assigned urgency (Jev triage), spam→high.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Priority {
    Spam,
    Low,
    Medium,
    High,
}

impl From<domain::Priority> for Priority {
    fn from(p: domain::Priority) -> Self {
        match p {
            domain::Priority::Spam => Self::Spam,
            domain::Priority::Low => Self::Low,
            domain::Priority::Medium => Self::Medium,
            domain::Priority::High => Self::High,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct MailThread {
    pub id: String,
    pub account_id: String,
    pub subject: String,
    pub snippet: String,
    /// Epoch milliseconds of the newest message.
    pub last_msg_at: i64,
    pub is_read: bool,
    pub is_inbox: bool,
    pub is_archived: bool,
    pub msg_count: i64,
    /// "Priya Nair", "Priya, Me (3)" — precomputed for list rendering.
    pub from_summary: String,
    /// Bare address of the latest sender — avatar lookups.
    pub last_from_addr: String,
    /// Local-only "remind me" schedule (epoch ms). Never synced to Gmail.
    pub scheduled_at: Option<i64>,
    /// Union of Gmail label ids over the thread's messages (INBOX, STARRED, Label_*).
    pub labels: Vec<String>,
    pub has_attachment: bool,
    pub priority: Option<Priority>,
    pub triage_label_ids: Vec<String>,
    /// Local-only "needs reply" flag.
    pub needs_reply: bool,
    /// Local-only "remind me if no reply" marker (epoch ms it was armed).
    pub follow_up_since: Option<i64>,
}

impl From<domain::Thread> for MailThread {
    fn from(t: domain::Thread) -> Self {
        Self {
            id: t.id,
            account_id: t.account_id,
            subject: t.subject,
            snippet: t.snippet,
            last_msg_at: t.last_msg_at,
            is_read: t.is_read,
            is_inbox: t.is_inbox,
            is_archived: t.is_archived,
            msg_count: t.msg_count,
            from_summary: t.from_summary,
            last_from_addr: t.last_from_addr,
            scheduled_at: t.scheduled_at,
            labels: t.labels,
            has_attachment: t.has_attachment,
            priority: t.priority.map(Into::into),
            triage_label_ids: t.triage_label_ids,
            needs_reply: t.needs_reply,
            follow_up_since: t.follow_up_since,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct MailMessage {
    pub id: String,
    pub thread_id: String,
    pub account_id: String,
    pub from_addr: String,
    pub to_addrs: Vec<String>,
    /// Epoch milliseconds.
    pub date: i64,
    pub snippet: String,
    /// Sanitized HTML (ammonia, in the Gmail adapter) — still render it in
    /// a non-scripting web view with remote images blocked (DESIGN.md).
    pub body_html: Option<String>,
    pub body_text: Option<String>,
    pub label_ids: Vec<String>,
    pub is_read: bool,
}

impl From<domain::Message> for MailMessage {
    fn from(m: domain::Message) -> Self {
        Self {
            id: m.id,
            thread_id: m.thread_id,
            account_id: m.account_id,
            from_addr: m.from_addr,
            to_addrs: m.to_addrs,
            date: m.date,
            snippet: m.snippet,
            body_html: m.body_html,
            body_text: m.body_text,
            label_ids: m.label_ids,
            is_read: m.is_read,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ThreadWithMessages {
    pub thread: MailThread,
    pub messages: Vec<MailMessage>,
}

/// One local FTS hit: the thread plus a highlighted preview line. Highlight
/// markers are U+E000 / U+E001 around each match (core::search).
#[derive(Debug, Clone, uniffi::Record)]
pub struct SearchHit {
    pub thread: MailThread,
    pub snippet: String,
}

impl From<domain::SearchResult> for SearchHit {
    fn from(r: domain::SearchResult) -> Self {
        Self {
            thread: r.thread.into(),
            snippet: r.snippet,
        }
    }
}

/// One user-created Gmail label (system labels map to folders).
#[derive(Debug, Clone, uniffi::Record)]
pub struct MailLabel {
    pub account_id: String,
    pub id: String,
    pub name: String,
}

impl From<domain::Label> for MailLabel {
    fn from(l: domain::Label) -> Self {
        Self {
            account_id: l.account_id,
            id: l.id,
            name: l.name,
        }
    }
}

/// One app-local Jev triage category.
#[derive(Debug, Clone, uniffi::Record)]
pub struct TriageLabel {
    pub id: String,
    pub name: String,
}

impl From<domain::TriageLabel> for TriageLabel {
    fn from(l: domain::TriageLabel) -> Self {
        Self {
            id: l.id,
            name: l.name,
        }
    }
}

/// One outgoing attachment (standard base64 content).
#[derive(Debug, Clone, uniffi::Record)]
pub struct OutAttachment {
    pub filename: String,
    pub mime_type: String,
    pub data_b64: String,
}

impl From<OutAttachment> for domain::OutAttachment {
    fn from(a: OutAttachment) -> Self {
        Self {
            filename: a.filename,
            mime_type: a.mime_type,
            data_b64: a.data_b64,
        }
    }
}

impl From<domain::OutAttachment> for OutAttachment {
    fn from(a: domain::OutAttachment) -> Self {
        Self {
            filename: a.filename,
            mime_type: a.mime_type,
            data_b64: a.data_b64,
        }
    }
}

/// A saved Gmail draft, reopened in the composer. `message_id` is the
/// composer key: saving or deleting under it targets this draft.
#[derive(Debug, Clone, uniffi::Record)]
pub struct DraftContent {
    pub message_id: String,
    pub account_id: String,
    pub to: Vec<String>,
    pub cc: Vec<String>,
    pub bcc: Vec<String>,
    pub subject: String,
    pub body_text: Option<String>,
    pub body_html: Option<String>,
    pub attachments: Vec<OutAttachment>,
    /// The thread it replies to; None for a stand-alone draft.
    pub reply_to_thread: Option<String>,
}

/// A local, optimistic change queued for Gmail (outbox pattern) — the same
/// set as `BackendMutation` in `ipc.ts`.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum Mutation {
    Archive {
        thread_id: String,
    },
    Unarchive {
        thread_id: String,
    },
    MarkRead {
        thread_id: String,
        read: bool,
    },
    Trash {
        thread_id: String,
    },
    /// Gmail star (the app's "pin").
    Star {
        thread_id: String,
        starred: bool,
    },
    ModifyLabel {
        thread_id: String,
        label_id: String,
        add: bool,
    },
    Send {
        to: Vec<String>,
        cc: Vec<String>,
        bcc: Vec<String>,
        subject: String,
        body_text: String,
        /// Rich compose: HTML alternative part. None sends plain text only.
        body_html: Option<String>,
        attachments: Vec<OutAttachment>,
        /// Reply threading: thread to attach the message to.
        reply_to_thread: Option<String>,
    },
    /// Create/update the Gmail draft of an open composer; `key` is the
    /// composer's stable id.
    SaveDraft {
        key: String,
        to: Vec<String>,
        cc: Vec<String>,
        bcc: Vec<String>,
        subject: String,
        body_text: String,
        body_html: Option<String>,
        attachments: Vec<OutAttachment>,
        reply_to_thread: Option<String>,
    },
    /// Delete the draft saved under `key`; a no-op when there is none.
    DeleteDraft {
        key: String,
    },
}

impl From<Mutation> for domain::Mutation {
    fn from(m: Mutation) -> Self {
        match m {
            Mutation::Archive { thread_id } => Self::Archive { thread_id },
            Mutation::Unarchive { thread_id } => Self::Unarchive { thread_id },
            Mutation::MarkRead { thread_id, read } => Self::MarkRead { thread_id, read },
            Mutation::Trash { thread_id } => Self::Trash { thread_id },
            Mutation::Star { thread_id, starred } => Self::Star { thread_id, starred },
            Mutation::ModifyLabel {
                thread_id,
                label_id,
                add,
            } => Self::ModifyLabel {
                thread_id,
                label_id,
                add,
            },
            Mutation::Send {
                to,
                cc,
                bcc,
                subject,
                body_text,
                body_html,
                attachments,
                reply_to_thread,
            } => Self::Send {
                to,
                cc,
                bcc,
                subject,
                body_text,
                body_html,
                attachments: attachments.into_iter().map(Into::into).collect(),
                reply_to_thread,
            },
            Mutation::SaveDraft {
                key,
                to,
                cc,
                bcc,
                subject,
                body_text,
                body_html,
                attachments,
                reply_to_thread,
            } => Self::SaveDraft {
                key,
                to,
                cc,
                bcc,
                subject,
                body_text,
                body_html,
                attachments: attachments.into_iter().map(Into::into).collect(),
                reply_to_thread,
            },
            Mutation::DeleteDraft { key } => Self::DeleteDraft { key },
        }
    }
}

/// Folder/label filter for `list_threads`. Mirrors core `ThreadFilter`.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum ThreadFilter {
    Inbox,
    Starred,
    Sent,
    Drafts,
    Archive,
    Spam,
    Trash,
    All,
    Label { id: String },
}

impl From<ThreadFilter> for domain::ThreadFilter {
    fn from(f: ThreadFilter) -> Self {
        match f {
            ThreadFilter::Inbox => Self::Inbox,
            ThreadFilter::Starred => Self::Starred,
            ThreadFilter::Sent => Self::Sent,
            ThreadFilter::Drafts => Self::Drafts,
            ThreadFilter::Archive => Self::Archive,
            ThreadFilter::Spam => Self::Spam,
            ThreadFilter::Trash => Self::Trash,
            ThreadFilter::All => Self::All,
            ThreadFilter::Label { id } => Self::Label(id),
        }
    }
}

/// Whether the account's Google grant still works. `Disconnected` = Google
/// rejected the stored token (revoked, expired, password changed) or none
/// is stored: mail is stale until the user reconnects.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ConnectionState {
    Connected,
    Disconnected,
}

/// Cross-device (Drive appDataFolder) sync outcome for one account.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SyncState {
    /// No round has finished since the engine opened.
    Pending,
    Ok,
    /// Scope missing / Drive API not enabled — needs a re-connect or a setup
    /// step (`detail` says which), not a retry.
    Unavailable,
    AuthExpired,
    Error,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AccountStatus {
    pub account_id: String,
    pub connection: ConnectionState,
    pub sync: SyncState,
    pub sync_detail: Option<String>,
    /// Epoch ms of the last successful cross-device sync round, any run.
    pub last_sync_at: Option<i64>,
}

/// State of the optional iOS push relay (push.rs). `enabled` means a device
/// token is registered with a relay and the engine renews Gmail watches.
#[derive(Debug, Clone, uniffi::Record)]
pub struct PushStatus {
    pub enabled: bool,
    pub relay_url: Option<String>,
    /// Pub/Sub topic the relay reported; what `users.watch` points at.
    pub topic: Option<String>,
    pub accounts: Vec<PushAccountStatus>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct PushAccountStatus {
    pub account_id: String,
    /// Epoch ms when Gmail stops publishing unless renewed; None = no watch.
    pub watch_expires_at_ms: Option<i64>,
}

/// Whether an AI provider can answer and which one — the stored key itself
/// is never returned. `provider_id` is the one that answers right now
/// (`"apple"` for the shell's on-device backend, `"openai"` for the key):
/// the preferred one when it can, else whichever can.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiStatus {
    pub configured: bool,
    pub provider_id: Option<String>,
    /// The selected OpenAI model (synced preference).
    pub model: Option<String>,
    /// The preferred provider (`pref:ai.provider`), whether or not it can answer.
    pub preferred_provider_id: String,
    /// The shell registered an on-device backend (Apple Intelligence available).
    pub on_device_available: bool,
    /// An OpenAI key is stored on this device.
    pub openai_configured: bool,
}

/// One selectable model of an AI provider.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiModel {
    pub id: String,
    pub label: String,
}

/// Auto-triage: a classifier can run (`configured`), background
/// classification is on, which classifier is preferred (`"apple"` on
/// device, `"jev"`), and the last failure.
#[derive(Debug, Clone, uniffi::Record)]
pub struct TriageStatus {
    pub configured: bool,
    pub enabled: bool,
    pub last_error: Option<String>,
    /// `pref:triage.classifier`, resolved to a default when unset.
    pub classifier_id: String,
    pub on_device_available: bool,
    pub jev_configured: bool,
}

/// What the on-device classifier decided for one email.
#[derive(Debug, Clone, uniffi::Record)]
pub struct TriageVerdict {
    pub priority: Priority,
    /// Ids from the labels it was given; anything else is dropped.
    pub label_ids: Vec<String>,
}

impl From<Priority> for domain::Priority {
    fn from(p: Priority) -> Self {
        match p {
            Priority::Spam => Self::Spam,
            Priority::Low => Self::Low,
            Priority::Medium => Self::Medium,
            Priority::High => Self::High,
        }
    }
}

/// One email's contribution to a group summary — subject + snippet only,
/// never the full body.
#[derive(Debug, Clone, uniffi::Record)]
pub struct SummaryItem {
    pub from: String,
    pub subject: String,
    pub snippet: String,
}

/// One message's contribution to a thread summary — sender + trimmed body
/// text, never the raw HTML.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ThreadSummaryItem {
    pub from: String,
    pub snippet: String,
}

/// Google OAuth client the shell was built with. iOS clients have no secret.
#[derive(Debug, Clone, uniffi::Record)]
pub struct OauthClient {
    pub client_id: String,
    pub client_secret: Option<String>,
}

/// A consent flow waiting for its redirect. Open `url` in an
/// `ASWebAuthenticationSession` whose callback scheme is `callback_scheme`,
/// then hand the callback URL to `Engine::finish_oauth`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct OauthSession {
    pub url: String,
    pub redirect_uri: String,
    /// Scheme part of `redirect_uri` (what `ASWebAuthenticationSession` wants).
    pub callback_scheme: String,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum EngineError {
    #[error("store: {0}")]
    Store(String),
    #[error("mail: {0}")]
    Mail(String),
    /// Google rejected the stored grant — the account needs reconnecting.
    #[error("account disconnected: {0}")]
    AuthExpired(String),
    #[error("oauth: {0}")]
    Oauth(String),
    #[error("{0}")]
    Invalid(String),
    /// An AI provider / Jev call failed (network, bad key, provider error).
    #[error("ai: {0}")]
    Ai(String),
}

impl From<heypigeon_core::ports::StoreError> for EngineError {
    fn from(e: heypigeon_core::ports::StoreError) -> Self {
        Self::Store(e.to_string())
    }
}

impl From<heypigeon_core::ports::MailError> for EngineError {
    fn from(e: heypigeon_core::ports::MailError) -> Self {
        match e {
            heypigeon_core::ports::MailError::AuthExpired => {
                Self::AuthExpired("Google rejected the stored grant".into())
            }
            other => Self::Mail(other.to_string()),
        }
    }
}

impl From<heypigeon_core::sync::SyncError> for EngineError {
    fn from(e: heypigeon_core::sync::SyncError) -> Self {
        match e {
            heypigeon_core::sync::SyncError::Mail(m) => m.into(),
            heypigeon_core::sync::SyncError::Store(s) => s.into(),
        }
    }
}

impl From<heypigeon_core::outbox::OutboxError> for EngineError {
    fn from(e: heypigeon_core::outbox::OutboxError) -> Self {
        Self::Store(e.to_string())
    }
}

impl From<heypigeon_core::devsync::DevSyncError> for EngineError {
    fn from(e: heypigeon_core::devsync::DevSyncError) -> Self {
        Self::Store(e.to_string())
    }
}

impl From<heypigeon_adapter_gmail::oauth::OauthError> for EngineError {
    fn from(e: heypigeon_adapter_gmail::oauth::OauthError) -> Self {
        Self::Oauth(e.to_string())
    }
}
