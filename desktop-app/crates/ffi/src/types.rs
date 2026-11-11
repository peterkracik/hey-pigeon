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
    /// The AI's proposal for this new unread email, waiting for the user
    /// to accept or dismiss it. Local-only.
    pub suggestion: Option<ThreadSuggestion>,
    /// The bundle this thread belongs to (`MailBundle::id`), if any.
    pub bundle_id: Option<String>,
}

/// What the AI proposes for a new unread email (`domain::Suggestion`).
/// Also the answer type of `AiBackend::suggest`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ThreadSuggestion {
    /// Someone is waiting on the user's answer: flag it "Need reply".
    NeedsReply,
    /// Bring it back at `at` (epoch ms): "Remind me" on a date the email
    /// names (a meeting, a deadline, a delivery).
    Remind { at: i64 },
}

impl From<domain::Suggestion> for ThreadSuggestion {
    fn from(s: domain::Suggestion) -> Self {
        match s {
            domain::Suggestion::NeedsReply => Self::NeedsReply,
            domain::Suggestion::Remind { at } => Self::Remind { at },
        }
    }
}

impl From<ThreadSuggestion> for domain::Suggestion {
    fn from(s: ThreadSuggestion) -> Self {
        match s {
            ThreadSuggestion::NeedsReply => Self::NeedsReply,
            ThreadSuggestion::Remind { at } => Self::Remind { at },
        }
    }
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
            suggestion: t.suggestion.map(Into::into),
            bundle_id: t.bundle_id,
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
    /// The Cc header, entry by entry, in the same form as `to_addrs`
    /// (`Name <addr>` or a bare address). Empty for mail synced before the
    /// header was kept, until its thread is next fetched in full (the
    /// first `get_thread` after the update does that).
    pub cc_addrs: Vec<String>,
    /// The Reply-To header's entries, in the same form; empty when the
    /// sender set none (and, like `cc_addrs`, for older mail until its
    /// thread is next fetched in full). A reply goes there instead of to
    /// `from_addr`.
    pub reply_to_addrs: Vec<String>,
    /// Epoch milliseconds.
    pub date: i64,
    pub snippet: String,
    /// The HTML body, sanitized by the core (`heypigeon_core::sanitize`,
    /// an allowlist over a real HTML parse) before it gets here — when it
    /// is stored, or on the way out for a body an older build stored as
    /// received.
    ///
    /// Gone: `<script>`, every `on…` handler, forms and their controls,
    /// frames, `<object>` / `<embed>` / `<applet>`, `<link>`, `<meta>`,
    /// `<base>`, the `<title>` and its text, SVG and MathML, comments,
    /// and any URL that is not `http`, `https`, `mailto` or `tel` on a
    /// link (`javascript:` and the rest) or `http`, `https`, `cid:` or
    /// `data:image/…` on a picture.
    ///
    /// Kept, as the sender wrote them: links (`<a href>` with its full
    /// URL, plus `rel="noopener noreferrer"`; `target` is dropped),
    /// pictures (`src="cid:…"` byte for byte), tables and the layout
    /// attributes mail leans on (`width`, `height`, `align`, `valign`,
    /// `bgcolor`, `border`, `cellpadding`, `cellspacing`, `colspan`,
    /// `rowspan`, `background`), `<font>`, `<center>`, `class` and `id`
    /// unprefixed (`gmail_quote`) — except names beginning `hp-`, which
    /// are the app's and which mail loses — inline `style` (minus
    /// `position` and
    /// anything that could run script) and `<style>` blocks (minus
    /// `@import`; `url(…)` stays, so remote pictures in CSS load or not
    /// by the view's content security policy). A full document comes as
    /// its content, the `<body>`'s attributes on a `<div>` around it.
    ///
    /// A tracking pixel is replaced by
    /// `<span class="hp-tracker" style="display:none"></span>`, exactly
    /// that text and only ever written by the sanitizer: count it for
    /// "n trackers blocked". A body that has one ends in a comment,
    /// `<!--hp-seal:…-->`, by which the sanitizer knows its own output
    /// again; it shows nothing and needs no handling.
    ///
    /// This is one layer of two. The shell's view is the other: the
    /// mail's JavaScript off, a content security policy, remote images
    /// blocked until the user allows them, navigation handed out. Keep
    /// both — still never put this string in a page that runs scripts
    /// without that policy.
    pub body_html: Option<String>,
    pub body_text: Option<String>,
    pub label_ids: Vec<String>,
    pub is_read: bool,
    /// The raw `List-Unsubscribe` header (`<mailto:…>, <https://…>`), when
    /// the sender offers one.
    pub list_unsubscribe: Option<String>,
    /// `List-Unsubscribe-Post: List-Unsubscribe=One-Click` (RFC 8058): a
    /// POST to the https link unsubscribes, no page needs to open.
    pub list_unsubscribe_one_click: bool,
}

impl From<domain::Message> for MailMessage {
    fn from(m: domain::Message) -> Self {
        // A body with the flag was sanitized when it was stored. One
        // without was stored as received by an older build: it is cleaned
        // here, each time, until the thread's next full fetch stores it
        // clean (the first `get_thread` does that; `get_thread_local`
        // alone never fetches).
        let body_html = if m.body_fetched {
            m.body_html
        } else {
            m.body_html.as_deref().map(heypigeon_core::sanitize::html)
        };
        Self {
            id: m.id,
            thread_id: m.thread_id,
            account_id: m.account_id,
            from_addr: m.from_addr,
            to_addrs: m.to_addrs,
            cc_addrs: m.cc_addrs,
            reply_to_addrs: m.reply_to_addrs,
            date: m.date,
            snippet: m.snippet,
            body_html,
            body_text: m.body_text,
            label_ids: m.label_ids,
            is_read: m.is_read,
            list_unsubscribe: m.list_unsubscribe,
            list_unsubscribe_one_click: m.list_unsubscribe_one_click,
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

/// One change still waiting for Gmail (`Engine::list_outbox`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OutboxEntry {
    /// The row's id, for `retry_outbox` / `discard_outbox`.
    pub id: i64,
    pub account_id: String,
    /// What kind of change: `send`, `draft`, `delete_draft`, `archive`,
    /// `unarchive`, `read`, `trash`, `untrash`, `star`, `label`, `spam`.
    pub kind: String,
    /// What it is about, for a person: `To ana@x.com · Subject` for
    /// outgoing mail and drafts (`To ana@x.com +2 · …` with more
    /// recipients), the thread's subject for a change to a thread (its id
    /// when the store no longer has the thread), `Draft` for a draft
    /// being deleted.
    pub summary: String,
    /// How many times Gmail refused it. (Being offline does not count.)
    pub attempts: u32,
    /// Refused so often that it is no longer retried on its own: it waits
    /// for `retry_outbox` or `discard_outbox`.
    pub failed: bool,
    /// Why the last try did not go through, in words; None before the
    /// first failure.
    pub last_error: Option<String>,
}

/// An address the account may send from (`Engine::list_send_as`): its
/// own, or a "Send mail as" alias it has verified in Gmail.
#[derive(Debug, Clone, uniffi::Record)]
pub struct SendAsAddress {
    pub email: String,
    /// The display name the address sends under; empty when none is set.
    pub name: String,
    /// The address Gmail uses when a send names none.
    pub is_default: bool,
}

impl From<domain::SendAs> for SendAsAddress {
    fn from(a: domain::SendAs) -> Self {
        Self {
            email: a.email,
            name: a.name,
            is_default: a.is_default,
        }
    }
}

/// One suggestion for a recipient field (`Engine::search_contacts`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ContactSuggestion {
    /// Display name; empty when only the address is known.
    pub name: String,
    pub email: String,
    /// Google contact photo, when the People API has one.
    pub photo_url: Option<String>,
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

/// One attachment of a stored message, where to fetch it and what it is.
/// Bytes come separately through `Engine::fetch_attachment`, which caches
/// the file under the data directory.
#[derive(Debug, Clone, uniffi::Record)]
pub struct MailAttachment {
    pub thread_id: String,
    pub message_id: String,
    pub attachment_id: String,
    pub filename: String,
    pub mime_type: String,
    /// Bytes as the provider reports them; 0 when unknown.
    pub size: i64,
    /// Content-ID without angle brackets, for the body's `cid:` images.
    pub content_id: Option<String>,
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
    /// Sanitized like `MailMessage::body_html` (see there): no script, no
    /// event handlers, links and pictures kept. The composer may load it
    /// into its own page.
    pub body_html: Option<String>,
    pub attachments: Vec<OutAttachment>,
    /// The thread it replies to; None for a stand-alone draft.
    pub reply_to_thread: Option<String>,
    /// The address the draft was written from, when that is not the
    /// account's own: one of its send-as aliases (`list_send_as`), to put
    /// back in the composer's From. None for the account's own address.
    pub from_addr: Option<String>,
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
        /// Reply threading: thread to attach the message to. The core adds
        /// `In-Reply-To` / `References` from that thread's newest message,
        /// so the reply threads in the recipient's mail client too.
        reply_to_thread: Option<String>,
        /// Send from this address — one of `list_send_as` — instead of the
        /// account's default. None = the default.
        from_addr: Option<String>,
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
        /// As on `Send`.
        from_addr: Option<String>,
    },
    /// Delete the draft saved under `key`; a no-op when there is none.
    DeleteDraft {
        key: String,
    },
    /// Take a thread out of Trash, back into the inbox.
    Untrash {
        thread_id: String,
    },
    /// `spam` true: move the thread to Spam. False ("Not spam"): back to
    /// the inbox.
    MarkSpam {
        thread_id: String,
        spam: bool,
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
                from_addr,
            } => Self::Send {
                to,
                cc,
                bcc,
                subject,
                body_text,
                body_html,
                attachments: attachments.into_iter().map(Into::into).collect(),
                reply_to_thread,
                from_addr: from_addr.filter(|a| !a.trim().is_empty()),
                // Filled when the mutation is queued (`Engine::mutate`).
                in_reply_to: None,
                references: None,
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
                from_addr,
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
                from_addr: from_addr.filter(|a| !a.trim().is_empty()),
                in_reply_to: None,
                references: None,
            },
            Mutation::DeleteDraft { key } => Self::DeleteDraft { key },
            Mutation::Untrash { thread_id } => Self::Untrash { thread_id },
            Mutation::MarkSpam { thread_id, spam } => Self::MarkSpam { thread_id, spam },
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
    /// The selected model of the preferred provider when it takes a key,
    /// else ChatGPT's (synced preference). `ai_selected_model` reads any.
    pub model: Option<String>,
    /// The preferred provider (`pref:ai.provider`), whether or not it can answer.
    pub preferred_provider_id: String,
    /// The shell registered an on-device backend (Apple Intelligence available).
    pub on_device_available: bool,
    /// An OpenAI key is stored on this device.
    pub openai_configured: bool,
    /// The keyed providers ("openai", "anthropic", "gemini") with a key on
    /// this device.
    pub keyed_provider_ids: Vec<String>,
    /// Ids of the shell backends registered on this device, in registration
    /// order ("apple", "apple-cloud", …). `provider_id` is one of these or
    /// a keyed provider.
    pub available_provider_ids: Vec<String>,
    /// Who answers when the preferred provider cannot, in order
    /// (`pref:ai.fallback`; default on device → Apple's cloud → the keyed
    /// providers).
    pub fallback_order: Vec<String>,
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
    /// The shell backends that can classify on this device ("apple",
    /// "apple-cloud", …), then the keyed providers with a key; "jev" is
    /// added when its key is stored.
    pub available_classifier_ids: Vec<String>,
}

/// The background analysis pass (auto-triage) as the shell shows it: of
/// the emails this pass found stale, how many are classified, and whether
/// a round is working right now. A pass starts when a round finds stale
/// mail and ends when none is left; mail arriving meanwhile joins it.
/// `total == 0` means there is nothing to analyze.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, uniffi::Record)]
pub struct AnalysisPass {
    pub done: u32,
    pub total: u32,
    pub running: bool,
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

/// The system prompts the engine sends, so the shell's evaluation harness
/// scores the prompt the app really runs (and variants of it) instead of
/// a copy that drifts.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiPrompts {
    pub summary: String,
    pub thread_summary: String,
    pub draft_reply: String,
    pub edit: String,
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

/// Who is writing to whom, for the writing assistant: the model writes as
/// the sender, addresses the recipients and keeps to the conversation's
/// language. Every field is optional — the composer sends what it knows.
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct AiWriteContext {
    /// The sender's display name (the user, "Me" in a transcript).
    pub sender_name: Option<String>,
    pub sender_email: Option<String>,
    /// To and Cc, as typed — addresses, or names when the composer knows them.
    pub recipients: Vec<String>,
    pub subject: Option<String>,
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
    /// The caller named the provider it had shown the user, and another
    /// one would answer now. Nothing was sent; the payload is the id of
    /// the provider that would have answered.
    #[error("the AI provider changed to {0}; nothing was sent")]
    ProviderChanged(String),
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
