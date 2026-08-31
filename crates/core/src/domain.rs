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
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Mutation {
    Archive { thread_id: ThreadId },
    MarkRead { thread_id: ThreadId, read: bool },
    Trash { thread_id: ThreadId },
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

/// Provider profile snapshot fetched at connect/sync time.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Profile {
    pub email: String,
    pub history_id: String,
}
