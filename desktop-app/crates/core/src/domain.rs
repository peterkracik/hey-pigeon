//! Domain types. Adapters translate provider shapes into these; the core and
//! frontend never see Gmail's wire format.
//! Debug is derived deliberately only where no body/address content leaks.

use serde::{Deserialize, Serialize};

/// Gmail-native id prefixed internally with the account id (see DESIGN.md).
pub type AccountId = String;
pub type ThreadId = String;
pub type MessageId = String;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Account {
    pub id: AccountId,
    pub email: String,
    pub display_name: String,
    pub color: String,
    /// Gmail `historyId` checkpoint captured before backfill; None until first sync.
    pub history_id: Option<String>,
    /// Profile photo URL (Google userinfo), when the provider offers one.
    #[serde(default)]
    pub avatar_url: Option<String>,
    /// Appended to composed mail from this account.
    #[serde(default)]
    pub signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Thread {
    pub id: ThreadId,
    pub account_id: AccountId,
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
    /// Bare address of the latest sender — avatar lookups in the list.
    #[serde(default)]
    pub last_from_addr: String,
    /// Local-only "remind me" schedule (epoch ms). Never synced to Gmail —
    /// stores must preserve it across provider re-upserts.
    #[serde(default)]
    pub scheduled_at: Option<i64>,
    /// Union of Gmail label ids over the thread's messages (INBOX, SENT,
    /// STARRED, user Label_* ids…). Drives the folder/label queries.
    #[serde(default)]
    pub labels: Vec<String>,
    /// True if any message in the thread carries a MIME part with a
    /// filename (i.e. an attachment). Drives the list-row paperclip icon.
    #[serde(default)]
    pub has_attachment: bool,
    /// Local-only AI triage priority (Jev). Never synced to Gmail — same
    /// contract as `scheduled_at`.
    #[serde(default)]
    pub priority: Option<Priority>,
    /// Local-only AI triage labels (Jev), by `TriageLabel::id`. Distinct
    /// from `labels` (real Gmail label ids) — never written to Gmail.
    #[serde(default)]
    pub triage_label_ids: Vec<String>,
    /// Local-only "needs reply" flag — the user marked this thread as
    /// waiting on their answer. Never synced to Gmail (same contract as
    /// `scheduled_at`: stores preserve it across provider re-upserts, and it
    /// travels between devices through the cross-device sync map).
    #[serde(default)]
    pub needs_reply: bool,
    /// Local-only "follow up if no reply" marker: when set, `scheduled_at`
    /// is a follow-up reminder that clears itself once someone else writes
    /// in this thread after this instant (epoch ms). Same contract as
    /// `scheduled_at`: never synced to Gmail, preserved across provider
    /// re-upserts, travels between devices through the sync map.
    #[serde(default)]
    pub follow_up_since: Option<i64>,
    /// Local-only AI proposal for a new unread email: "Need reply" or
    /// "Remind me" at a date the model read in it. Same contract as
    /// `priority`: never synced to Gmail or between devices (each device
    /// can analyze), preserved across provider re-upserts. Cleared once
    /// the user accepts or dismisses it, or flags the thread themselves.
    #[serde(default)]
    pub suggestion: Option<Suggestion>,
}

/// What the AI proposes for a new unread email. The user accepts it (one
/// tap sets the flag or the reminder) or dismisses it; nothing changes on
/// its own.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Suggestion {
    /// Someone is waiting on the user's answer.
    NeedsReply,
    /// Bring the thread back at `at` (epoch ms): a meeting, a deadline, a
    /// delivery the email names.
    Remind { at: i64 },
}

/// Current wall-clock time as epoch milliseconds — the unit `scheduled_at`
/// and the other local-only timestamps use. A snoozed thread ("remind me
/// later") is one whose `scheduled_at` is still in the future by this clock.
pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// AI-assigned urgency (Jev triage). Ordered spam→high for sorting — Spam
/// is a distinct bottom tier ("don't bother showing this a priority at
/// all"), not just a lower number than Low.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "lowercase")]
pub enum Priority {
    Spam,
    Low,
    Medium,
    High,
}

impl Priority {
    pub fn as_str(&self) -> &'static str {
        match self {
            Priority::Spam => "spam",
            Priority::Low => "low",
            Priority::Medium => "medium",
            Priority::High => "high",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "spam" => Some(Priority::Spam),
            "low" => Some(Priority::Low),
            "medium" => Some(Priority::Medium),
            "high" => Some(Priority::High),
            _ => None,
        }
    }
}

/// A user-defined local triage category (Jev auto-label). App-local only —
/// never a real Gmail label, unlike `Label`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TriageLabel {
    pub id: String,
    pub name: String,
}

/// One Gmail label (user-created only — system labels map to folders).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Label {
    pub account_id: AccountId,
    pub id: String,
    pub name: String,
}

/// Folder/label filter for thread list queries. String form (IPC):
/// `inbox|starred|sent|drafts|archive|spam|trash|all|label:<id>`.
#[derive(Debug, Clone, PartialEq, Default)]
pub enum ThreadFilter {
    #[default]
    Inbox,
    Starred,
    Sent,
    Drafts,
    Archive,
    Spam,
    Trash,
    All,
    Label(String),
}

impl ThreadFilter {
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "inbox" => Self::Inbox,
            "starred" => Self::Starred,
            "sent" => Self::Sent,
            "drafts" => Self::Drafts,
            "archive" => Self::Archive,
            "spam" => Self::Spam,
            "trash" => Self::Trash,
            "all" => Self::All,
            _ => Self::Label(s.strip_prefix("label:")?.to_string()),
        })
    }
}

#[derive(Clone, Serialize, Deserialize, PartialEq)]
pub struct Message {
    pub id: MessageId,
    pub thread_id: ThreadId,
    pub account_id: AccountId,
    pub from_addr: String,
    pub to_addrs: Vec<String>,
    /// Epoch milliseconds.
    pub date: i64,
    pub snippet: String,
    pub body_html: Option<String>,
    pub body_text: Option<String>,
    pub label_ids: Vec<String>,
    pub is_read: bool,
}

// Log hygiene: no bodies or addresses in Debug output (DESIGN.md Security).
impl std::fmt::Debug for Message {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Message")
            .field("id", &self.id)
            .field("thread_id", &self.thread_id)
            .field("date", &self.date)
            .field("is_read", &self.is_read)
            .finish_non_exhaustive()
    }
}

/// A local, optimistic change queued for the provider (outbox pattern).
#[derive(Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Mutation {
    Archive {
        thread_id: ThreadId,
    },
    /// Reverse of Archive: restore a thread to the inbox (re-add INBOX,
    /// flip is_archived/is_inbox back). Gmail has no separate endpoint for
    /// this — it's the same threads.modify label flip, just addLabelIds.
    Unarchive {
        thread_id: ThreadId,
    },
    MarkRead {
        thread_id: ThreadId,
        read: bool,
    },
    Trash {
        thread_id: ThreadId,
    },
    /// Gmail star (the app's "pin"). Sugar over a STARRED label flip —
    /// adapters route it through the same machinery as `ModifyLabel`.
    Star {
        thread_id: ThreadId,
        starred: bool,
    },
    /// Add/remove one label on a thread. Flags (is_inbox/is_archived) stay
    /// untouched — Archive/Trash own folder moves.
    ModifyLabel {
        thread_id: ThreadId,
        label_id: String,
        add: bool,
    },
    /// Outgoing mail. Rides the same outbox: optimistic, retried with backoff.
    Send {
        to: Vec<String>,
        #[serde(default)]
        cc: Vec<String>,
        #[serde(default)]
        bcc: Vec<String>,
        subject: String,
        body_text: String,
        /// Rich compose: HTML alternative part. None sends plain text only.
        #[serde(default)]
        body_html: Option<String>,
        /// Outgoing attachments (base64 content, ready for MIME).
        #[serde(default)]
        attachments: Vec<OutAttachment>,
        /// Reply threading: provider-side thread to attach the message to.
        #[serde(default)]
        reply_to_thread: Option<ThreadId>,
    },
    /// Create or update the Gmail draft for an open composer. `key` is the
    /// composer's own id (stable across saves), so repeated saves update one
    /// draft instead of piling up new ones.
    SaveDraft {
        key: String,
        to: Vec<String>,
        #[serde(default)]
        cc: Vec<String>,
        #[serde(default)]
        bcc: Vec<String>,
        subject: String,
        body_text: String,
        #[serde(default)]
        body_html: Option<String>,
        #[serde(default)]
        attachments: Vec<OutAttachment>,
        #[serde(default)]
        reply_to_thread: Option<ThreadId>,
    },
    /// Delete the draft saved under `key` (discarded or sent). A no-op when
    /// no such draft exists.
    DeleteDraft {
        key: String,
    },
}

/// A saved draft as the provider holds it, for reopening it in the
/// composer (to edit, send or discard).
#[derive(Clone, PartialEq)]
pub struct DraftContent {
    /// Provider message id of the draft. Used as the composer key, so the
    /// next save updates this draft instead of creating a second one.
    pub message_id: MessageId,
    pub to: Vec<String>,
    pub cc: Vec<String>,
    pub bcc: Vec<String>,
    pub subject: String,
    pub body_text: Option<String>,
    pub body_html: Option<String>,
    pub attachments: Vec<OutAttachment>,
}

// Log hygiene: addresses, subject and body stay out of Debug output.
impl std::fmt::Debug for DraftContent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DraftContent")
            .field("message_id", &self.message_id)
            .field("attachments", &self.attachments.len())
            .finish_non_exhaustive()
    }
}

/// One attachment of a stored message, as the provider's parts tree names
/// it: where to fetch it (`message_id` + `attachment_id`), what it is and
/// how big. Bytes are never kept here — `MailProvider::fetch_attachment`
/// brings them on demand and the shell caches the file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttachmentRef {
    pub message_id: MessageId,
    /// Provider id of the part. Gmail hands small parts inline instead;
    /// those carry `inline:<n>` (the n-th attachment part of the message).
    pub attachment_id: String,
    pub filename: String,
    pub mime_type: String,
    /// Bytes, as the provider reports it (0 when unknown).
    pub size: i64,
}

/// One attachment on an outgoing Send mutation.
#[derive(Clone, Serialize, Deserialize, PartialEq)]
pub struct OutAttachment {
    pub filename: String,
    pub mime_type: String,
    /// Standard base64 of the file content.
    pub data_b64: String,
}

// Log hygiene: never dump attachment bytes into logs.
impl std::fmt::Debug for OutAttachment {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OutAttachment")
            .field("filename", &self.filename)
            .field("mime_type", &self.mime_type)
            .field("b64_len", &self.data_b64.len())
            .finish()
    }
}

// Log hygiene: Send carries addresses/subject/body — redact them in Debug.
impl std::fmt::Debug for Mutation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Mutation::Archive { thread_id } => f
                .debug_struct("Archive")
                .field("thread_id", thread_id)
                .finish(),
            Mutation::Unarchive { thread_id } => f
                .debug_struct("Unarchive")
                .field("thread_id", thread_id)
                .finish(),
            Mutation::MarkRead { thread_id, read } => f
                .debug_struct("MarkRead")
                .field("thread_id", thread_id)
                .field("read", read)
                .finish(),
            Mutation::Trash { thread_id } => f
                .debug_struct("Trash")
                .field("thread_id", thread_id)
                .finish(),
            Mutation::Star { thread_id, starred } => f
                .debug_struct("Star")
                .field("thread_id", thread_id)
                .field("starred", starred)
                .finish(),
            // Label ids are opaque (Label_36 / system names) — safe to log.
            Mutation::ModifyLabel {
                thread_id,
                label_id,
                add,
            } => f
                .debug_struct("ModifyLabel")
                .field("thread_id", thread_id)
                .field("label_id", label_id)
                .field("add", add)
                .finish(),
            Mutation::Send {
                to,
                reply_to_thread,
                ..
            } => f
                .debug_struct("Send")
                .field("recipients", &to.len())
                .field("reply_to_thread", reply_to_thread)
                .finish_non_exhaustive(),
            Mutation::SaveDraft {
                key,
                reply_to_thread,
                ..
            } => f
                .debug_struct("SaveDraft")
                .field("key", key)
                .field("reply_to_thread", reply_to_thread)
                .finish_non_exhaustive(),
            Mutation::DeleteDraft { key } => {
                f.debug_struct("DeleteDraft").field("key", key).finish()
            }
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct OutboxItem {
    pub id: i64,
    pub account_id: AccountId,
    pub mutation: Mutation,
    pub attempts: i64,
    /// Epoch milliseconds.
    pub created_at: i64,
}

/// One local search hit: the thread plus an FTS5 snippet() preview line
/// (matches wrapped in `search::SNIPPET_START`/`SNIPPET_END` markers).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SearchResult {
    pub thread: Thread,
    pub snippet: String,
}

/// Provider profile snapshot fetched at connect/sync time.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Profile {
    pub email: String,
    pub history_id: String,
}

/// One key in the cross-device sync map (DESIGN.md "Cross-device sync"):
/// a last-writer-wins register. `value` None is a tombstone. Newer =
/// greater `(ts, device)` — the device id breaks exact-timestamp ties so
/// every replica converges on the same winner.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SyncEntry {
    pub key: String,
    #[serde(default)]
    pub value: Option<serde_json::Value>,
    /// Epoch milliseconds on the writing device.
    pub ts: i64,
    pub device: String,
}

impl SyncEntry {
    /// Does `self` beat `other` under last-writer-wins?
    pub fn is_newer_than(&self, other: &SyncEntry) -> bool {
        (self.ts, self.device.as_str()) > (other.ts, other.device.as_str())
    }
}
