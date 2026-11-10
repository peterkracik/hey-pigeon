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

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
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
    /// The bundle this thread belongs to (`Bundle::id`), if any. App-local
    /// like `triage_label_ids`; a thread is in at most one bundle.
    #[serde(default)]
    pub bundle_id: Option<String>,
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

/// A bundle: the mail about one specific thing — a trip, an order (or a
/// season of them), a project (docs/bundles.md). App-local like
/// `TriageLabel`: never a Gmail label, synced between devices through the
/// sync map (`bundle:<id>`), ids random so two devices never collide.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Bundle {
    pub id: String,
    pub name: String,
    pub kind: BundleKind,
    /// The user's one line ("everything about the Acme website"); empty
    /// when none. It goes into the model's prompt once assignment lands.
    #[serde(default)]
    pub description: String,
    pub status: BundleStatus,
    /// Who made it. An `Ai` bundle stays on this device (every device
    /// groups its own mail) until the user touches it — renames, archives,
    /// adds or removes an email — which makes it `User` and synced.
    #[serde(default)]
    pub origin: BundleOrigin,
    /// Epoch ms.
    pub created_at: i64,
    /// Epoch ms of the last edit to the bundle row (not its threads).
    pub updated_at: i64,
}

/// What a bundle is about. It decides which facts the bundle view leads
/// with and, later, when the bundle ends on its own.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum BundleKind {
    Trip,
    Shopping,
    Project,
    Other,
}

impl BundleKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            BundleKind::Trip => "trip",
            BundleKind::Shopping => "shopping",
            BundleKind::Project => "project",
            BundleKind::Other => "other",
        }
    }

    /// Unknown strings (a newer device's kind) read as `Other`.
    pub fn parse(s: &str) -> Self {
        match s {
            "trip" => BundleKind::Trip,
            "shopping" => BundleKind::Shopping,
            "project" => BundleKind::Project,
            _ => BundleKind::Other,
        }
    }
}

/// Active bundles show in the Bundles list and take new mail; archived
/// ones are kept for search and reopen when a linked email arrives.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum BundleStatus {
    Active,
    Archived,
}

impl BundleStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            BundleStatus::Active => "active",
            BundleStatus::Archived => "archived",
        }
    }

    pub fn parse(s: &str) -> Self {
        match s {
            "archived" => BundleStatus::Archived,
            _ => BundleStatus::Active,
        }
    }
}

/// Who made a bundle (`Bundle::origin`).
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum BundleOrigin {
    #[default]
    User,
    Ai,
}

impl BundleOrigin {
    pub fn as_str(&self) -> &'static str {
        match self {
            BundleOrigin::User => "user",
            BundleOrigin::Ai => "ai",
        }
    }

    pub fn parse(s: &str) -> Self {
        match s {
            "ai" => BundleOrigin::Ai,
            _ => BundleOrigin::User,
        }
    }
}

/// How a thread got into its bundle. `User` is sticky: nothing automatic
/// moves it. `Link` came from a shared booking ref, order or tracking
/// number (`bundles::extract_anchors`) with a thread already in the bundle.
/// `Ai` is the model's grouping of new mail.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum BundleSource {
    User,
    Link,
    Ai,
}

impl BundleSource {
    pub fn as_str(&self) -> &'static str {
        match self {
            BundleSource::User => "user",
            BundleSource::Link => "link",
            BundleSource::Ai => "ai",
        }
    }

    pub fn parse(s: &str) -> Self {
        match s {
            "user" => BundleSource::User,
            "ai" => BundleSource::Ai,
            _ => BundleSource::Link,
        }
    }
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
    /// The folders the sidebar counts unread mail for, with the keys the
    /// shells read them under (`Store::unread_counts`): the folder names in
    /// lowercase. Labels join as `label:<id>`.
    pub const COUNTED_FOLDERS: [(&'static str, ThreadFilter); 8] = [
        ("inbox", ThreadFilter::Inbox),
        ("all", ThreadFilter::All),
        ("starred", ThreadFilter::Starred),
        ("sent", ThreadFilter::Sent),
        ("drafts", ThreadFilter::Drafts),
        ("archive", ThreadFilter::Archive),
        ("spam", ThreadFilter::Spam),
        ("trash", ThreadFilter::Trash),
    ];

    /// Whether `t` belongs to this folder or label: the folder rules in
    /// Rust. The in-memory store lists with it, and the SQLite store
    /// classifies the unread rows with it (`unread_counts`) instead of
    /// scanning the table once per folder. Keep in lockstep with the SQLite
    /// adapter's `thread_filter_sql`.
    pub fn matches(&self, t: &Thread) -> bool {
        let has = |l: &str| t.labels.iter().any(|x| x == l);
        // Junk only when trashed/spam AND out of the inbox — a partially-
        // trashed thread keeps INBOX and stays in All/Starred/Sent/label views.
        let junk = (has("TRASH") || has("SPAM")) && !has("INBOX");
        match self {
            // A reminder or "needs reply" moves a thread out of the inbox into
            // Scheduled / Need reply (it stays in All).
            ThreadFilter::Inbox => {
                t.is_inbox && !t.is_archived && t.scheduled_at.is_none() && !t.needs_reply
            }
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

#[derive(Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Message {
    pub id: MessageId,
    pub thread_id: ThreadId,
    pub account_id: AccountId,
    pub from_addr: String,
    pub to_addrs: Vec<String>,
    /// The Cc header, entry by entry, in the same form as `to_addrs`
    /// (`Name <addr>` or a bare address). Reply-all needs it. Empty for
    /// mail synced before the header was asked for, until its thread is
    /// opened again.
    #[serde(default)]
    pub cc_addrs: Vec<String>,
    /// The Reply-To header, entry by entry, in the same form. A reply goes
    /// there instead of to the sender (a list, a booking system writing
    /// from a no-reply address). Empty when the sender set none, and for
    /// mail stored before the header was kept until its thread is next
    /// fetched in full (its next open does that once).
    #[serde(default)]
    pub reply_to_addrs: Vec<String>,
    /// Epoch milliseconds.
    pub date: i64,
    pub snippet: String,
    /// The HTML body. Sanitized (`sanitize::html`) when `body_fetched` is
    /// set — providers clean it before they hand it over. A row without
    /// the flag that still has one was stored by a build that kept mail
    /// as received: it is sanitized on its way to a view, until the
    /// thread's next full fetch replaces it.
    pub body_html: Option<String>,
    pub body_text: Option<String>,
    pub label_ids: Vec<String>,
    pub is_read: bool,
    /// The RFC 822 `Message-ID` header, angle brackets included. A reply
    /// names it in `In-Reply-To` so other mail clients thread it.
    #[serde(default)]
    pub message_id_header: Option<String>,
    /// The message's own `References` header: a reply's `References` is
    /// this plus `message_id_header`.
    #[serde(default)]
    pub references_header: Option<String>,
    /// The raw `List-Unsubscribe` header (`<mailto:…>, <https://…>`), when
    /// the sender offers one.
    #[serde(default)]
    pub list_unsubscribe: Option<String>,
    /// `List-Unsubscribe-Post: List-Unsubscribe=One-Click` (RFC 8058): the
    /// https link accepts a POST and no page needs to open.
    #[serde(default)]
    pub list_unsubscribe_one_click: bool,
    /// True once the provider's full message was fetched. A message with no
    /// text at all (an attachment alone, an empty draft) has no body to
    /// show, so "has a body" cannot stand in for "was fetched": such a
    /// thread used to be fetched again on every open. It also says the
    /// stored `body_html` is sanitized (see there).
    #[serde(default)]
    pub body_fetched: bool,
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
        /// The address to send from, when it is not the account's own: one
        /// of its send-as aliases. None lets the provider use the default.
        /// (`serde(default)` on this and the two below: outbox rows written
        /// by older builds carry none of them.)
        #[serde(default)]
        from_addr: Option<String>,
        /// `In-Reply-To` / `References` for a reply, read from the message
        /// being answered when the mutation is queued (`outbox::reply_headers`).
        /// The provider-side thread id only threads the mail for the
        /// sender; these are what the recipient's mail client goes by.
        #[serde(default)]
        in_reply_to: Option<String>,
        #[serde(default)]
        references: Option<String>,
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
        /// Same three as on `Send`.
        #[serde(default)]
        from_addr: Option<String>,
        #[serde(default)]
        in_reply_to: Option<String>,
        #[serde(default)]
        references: Option<String>,
    },
    /// Delete the draft saved under `key` (discarded or sent). A no-op when
    /// no such draft exists.
    DeleteDraft {
        key: String,
    },
    /// Take a thread out of Trash and put it back in the inbox (the reverse
    /// of `Trash`, which is how mail gets there from this app).
    Untrash {
        thread_id: ThreadId,
    },
    /// `spam` true: move the thread to Spam. False ("Not spam"): back to
    /// the inbox.
    MarkSpam {
        thread_id: ThreadId,
        spam: bool,
    },
}

impl Mutation {
    /// The thread a mutation changes; None for outgoing mail and drafts,
    /// which change no stored thread.
    pub fn thread_id(&self) -> Option<&ThreadId> {
        match self {
            Mutation::Archive { thread_id }
            | Mutation::Unarchive { thread_id }
            | Mutation::MarkRead { thread_id, .. }
            | Mutation::Trash { thread_id }
            | Mutation::Star { thread_id, .. }
            | Mutation::ModifyLabel { thread_id, .. }
            | Mutation::Untrash { thread_id }
            | Mutation::MarkSpam { thread_id, .. } => Some(thread_id),
            Mutation::Send { .. } | Mutation::SaveDraft { .. } | Mutation::DeleteDraft { .. } => {
                None
            }
        }
    }

    /// Outgoing mail and draft changes: the ones whose caller waits for the
    /// provider's answer (a send that failed must be reported), where a
    /// label flip is done for the user the moment it is applied locally.
    pub fn is_outgoing(&self) -> bool {
        self.thread_id().is_none()
    }
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
    /// The part's Content-ID without the angle brackets: the HTML body
    /// shows it as `<img src="cid:…">` (signatures, inline pictures).
    pub content_id: Option<String>,
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
            Mutation::Untrash { thread_id } => f
                .debug_struct("Untrash")
                .field("thread_id", thread_id)
                .finish(),
            Mutation::MarkSpam { thread_id, spam } => f
                .debug_struct("MarkSpam")
                .field("thread_id", thread_id)
                .field("spam", spam)
                .finish(),
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

/// What the Bundles list shows next to a bundle's name, counted over its
/// threads (trash and spam left out, like `Store::list_bundle_threads`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct BundleStats {
    pub thread_count: u32,
    /// Threads still waiting in the inbox.
    pub open_count: u32,
    /// Epoch ms of the newest message in the bundle; 0 when it is empty.
    pub last_activity_at: i64,
}

/// An address the account may send from (Gmail "Send mail as"): its own,
/// or an alias it has verified.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SendAs {
    pub email: String,
    /// The display name the alias sends under; empty when none is set.
    pub name: String,
    pub is_default: bool,
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
