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
    MarkRead {
        thread_id: ThreadId,
        read: bool,
    },
    Trash {
        thread_id: ThreadId,
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
        /// Reply threading: provider-side thread to attach the message to.
        #[serde(default)]
        reply_to_thread: Option<ThreadId>,
    },
}

// Log hygiene: Send carries addresses/subject/body — redact them in Debug.
impl std::fmt::Debug for Mutation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Mutation::Archive { thread_id } => f
                .debug_struct("Archive")
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
            Mutation::Send {
                to,
                reply_to_thread,
                ..
            } => f
                .debug_struct("Send")
                .field("recipients", &to.len())
                .field("reply_to_thread", reply_to_thread)
                .finish_non_exhaustive(),
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
