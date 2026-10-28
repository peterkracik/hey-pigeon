// App-side models: what the views read. The Rust engine's records are
// mapped into these (RustEngine.swift), the mock produces them directly —
// the same seam `data.ts` / `ipc.ts` form on the desktop side.

import Foundation

enum AccountColor: String, CaseIterable, Hashable {
    case sky, lavender, mint, amber, coral
}

struct MailAccount: Identifiable, Hashable {
    let id: String
    let email: String
    let displayName: String
    let color: AccountColor
    let avatarURL: URL?
    let signature: String
}

/// Jev triage urgency, spam→high.
enum TriageLevel: String, Hashable, Comparable {
    case spam, low, medium, high
    private var rank: Int {
        switch self {
        case .spam: 0
        case .low: 1
        case .medium: 2
        case .high: 3
        }
    }
    static func < (lhs: TriageLevel, rhs: TriageLevel) -> Bool { lhs.rank < rhs.rank }
}

struct ThreadRow: Identifiable, Hashable {
    let id: String
    let accountId: String
    let subject: String
    /// Preview line. For search results this is the highlighted FTS snippet.
    let snippet: String
    let lastMessageAt: Date
    let isRead: Bool
    /// Archived = "done" in this app's vocabulary.
    let isArchived: Bool
    let messageCount: Int
    /// "Priya Nair", "Priya, Me (3)".
    let fromSummary: String
    let lastFromAddress: String
    /// Local-only reminder ("remind me") — hides the row from the inbox until then.
    let scheduledAt: Date?
    /// The reminder is a "remind me if no reply" follow-up.
    let isFollowUp: Bool
    let needsReply: Bool
    /// Gmail star = the app's "pin".
    let isStarred: Bool
    let hasAttachment: Bool
    let priority: TriageLevel?
    /// Local Jev triage labels (Settings-managed), distinct from `labels`.
    let triageLabelIds: [String]
    /// Gmail label ids over the thread (INBOX, STARRED, Label_…).
    let labels: [String]

    var isConversation: Bool { messageCount > 1 }
    var isDone: Bool { isArchived }
    var isPinned: Bool { isStarred }
}

struct MessageItem: Identifiable, Hashable {
    let id: String
    let fromName: String
    let fromAddress: String
    let to: [String]
    let date: Date
    let snippet: String
    /// Sanitized by the core; still rendered with scripts off and remote
    /// images blocked (MessageBodyView).
    let bodyHTML: String?
    let bodyText: String?
    let isRead: Bool
    let isMine: Bool
}

struct ThreadDetail: Hashable {
    let thread: ThreadRow
    let messages: [MessageItem]
}

/// A user-created Gmail label (system labels map to folders).
struct MailLabelItem: Identifiable, Hashable {
    let id: String
    let accountId: String
    let name: String
}

/// One app-local Jev triage category (Settings "Triage" list) — the labels
/// in the bottom pill.
struct TriageLabelItem: Identifiable, Hashable {
    let id: String
    let name: String
}

struct AccountState: Identifiable, Hashable {
    let id: String
    let isConnected: Bool
    /// pending | ok | unavailable | auth_expired | error
    let syncState: String
    let syncDetail: String?
    let lastSyncAt: Date?
}

/// Engine-side view of the push relay: registered or not, and when each
/// account's Gmail watch lease runs out unless renewed (the engine renews
/// on every sync once less than 6 days remain).
struct PushState: Hashable {
    let enabled: Bool
    let relayURL: String?
    let topic: String?
    let accounts: [PushAccountState]
}

struct PushAccountState: Identifiable, Hashable {
    let id: String
    let watchExpiresAt: Date?
}

struct AIStatus: Hashable {
    let configured: Bool
    let providerId: String?
    let model: String?
}

struct AIModel: Identifiable, Hashable {
    let id: String
    let label: String
}

struct TriageStatus: Hashable {
    let configured: Bool
    let enabled: Bool
    let lastError: String?
}

/// What the root list shows. The folder set mirrors the desktop sidebar.
enum MailView: Hashable {
    case inbox, scheduled, needReply, starred, drafts, sent, archive, all, spam, trash
    case label(id: String, name: String)

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .scheduled: "Scheduled"
        case .needReply: "Need reply"
        case .starred: "Starred"
        case .drafts: "Drafts"
        case .sent: "Sent"
        case .archive: "Archive"
        case .all: "All emails"
        case .spam: "Spam"
        case .trash: "Trash"
        case .label(_, let name): name
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: "tray"
        case .scheduled: "clock"
        case .needReply: "arrowshape.turn.up.left"
        case .starred: "pin"
        case .drafts: "doc"
        case .sent: "paperplane"
        case .archive: "checkmark.square"
        case .all: "envelope.open"
        case .spam: "xmark.bin"
        case .trash: "trash"
        case .label: "tag"
        }
    }

    /// Key in the engine's unread-count map.
    var countKey: String {
        switch self {
        case .inbox: "inbox"
        case .scheduled: "scheduled"
        case .needReply: "needreply"
        case .starred: "starred"
        case .drafts: "drafts"
        case .sent: "sent"
        case .archive: "archive"
        case .all: "all"
        case .spam: "spam"
        case .trash: "trash"
        case .label(let id, _): "label:\(id)"
        }
    }

    /// Views where "done" removes the row from what is shown.
    var archivesOut: Bool {
        switch self {
        case .inbox, .starred, .label, .scheduled, .needReply: true
        default: false
        }
    }

    /// Sidebar folders in the desktop's order (Scheduled and Need reply are tabs).
    static let folders: [MailView] = [
        .starred, .sent, .drafts, .archive, .all, .spam, .trash,
    ]
}

/// A person the Search tab filters on (From / To): `address` goes into the
/// query, `name` is what the filter button shows.
struct SearchPerson: Hashable, Codable {
    let name: String
    let address: String
}

/// A From / To picker entry: the person and the account they last wrote to.
struct PersonSuggestion: Identifiable {
    let person: SearchPerson
    let accountId: String
    var id: String { person.address }
}

/// The Search tab's filter buttons. They compose into the core's operators
/// (core/src/search.rs: from:, to:, is:unread, account:) so the field only
/// holds the words the user typed.
struct SearchFilters: Hashable, Codable {
    var from: SearchPerson?
    var to: SearchPerson?
    var unreadOnly = false
    var accountId: String?

    var isEmpty: Bool { from == nil && to == nil && !unreadOnly && accountId == nil }

    var operators: [String] {
        var ops: [String] = []
        if let from { ops.append("from:\(from.address)") }
        if let to { ops.append("to:\(to.address)") }
        if unreadOnly { ops.append("is:unread") }
        if let accountId { ops.append("account:\(accountId)") }
        return ops
    }
}

/// One entry of the Search tab's "Recent" list (kept on this device).
struct RecentSearch: Hashable, Codable, Identifiable {
    var text: String
    var filters: SearchFilters
    var id: RecentSearch { self }
}

/// The bottom bar — the desktop rail, one to one: Inbox · Scheduled · Need reply · Search.
enum MainTab: Hashable {
    case inbox, scheduled, needReply, search
    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .scheduled: "Scheduled"
        case .needReply: "Need reply"
        case .search: "Search"
        }
    }
    var systemImage: String {
        switch self {
        case .inbox: "tray"
        case .scheduled: "clock"
        case .needReply: "arrowshape.turn.up.left"
        case .search: "magnifyingglass"
        }
    }
}

/// The row actions a swipe tier can be set to (Settings "Swipe actions" —
/// the desktop's "Hover actions", same keys). Mark done lives on the long
/// right swipe by default, like the desktop's always-present checkbox.
enum RowAction: String, CaseIterable, Identifiable, Hashable {
    case done, delete, remind, needReply = "needreply", pin, read = "unread"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .done: "Mark done"
        case .delete: "Delete"
        case .remind: "Remind me"
        case .needReply: "Need reply"
        case .pin: "Pin"
        case .read: "Read / unread"
        }
    }
    var systemImage: String {
        switch self {
        case .done: "checkmark"
        case .delete: "trash"
        case .remind: "clock"
        case .needReply: "arrowshape.turn.up.left"
        case .pin: "pin"
        case .read: "envelope.open"
        }
    }
}

struct DraftAttachment: Hashable, Identifiable {
    var id: String { filename + "\(size)" }
    let filename: String
    let mimeType: String
    let size: Int
    /// Standard base64 content.
    let dataBase64: String
}

struct SendDraft: Hashable {
    var to: [String] = []
    var cc: [String] = []
    var bcc: [String] = []
    var subject: String = ""
    var bodyText: String = ""
    /// Rich body when formatting was applied — the MIME html part.
    var bodyHTML: String?
    /// The editor's attributed body as it was sent, so a send that is undone
    /// reopens the composer with its formatting intact. Never serialized.
    var bodyRich: AttributedString?
    var attachments: [DraftAttachment] = []
    var replyToThreadId: String?
    /// Account that received the thread (replies go out from it).
    var fromAccountId: String?
    /// Plain-text transcript of the thread being replied to (AI context).
    var history: String?
    /// The composer's id: its Gmail draft is saved and deleted under it.
    var draftKey = UUID().uuidString
    /// A Gmail draft was saved for it (a send or a discard deletes it).
    var draftSaved = false
}

/// Optimistic changes queued for Gmail — same set as the desktop IPC.
enum MailAction: Hashable {
    case archive(threadId: String)
    case unarchive(threadId: String)
    case markRead(threadId: String, read: Bool)
    case trash(threadId: String)
    case star(threadId: String, starred: Bool)
    case modifyLabel(threadId: String, labelId: String, add: Bool)
    case send(SendDraft)
    case saveDraft(SendDraft)
    case deleteDraft(key: String)
}

struct OAuthStart: Hashable {
    let url: URL
    let callbackScheme: String
}

/// The engine the app talks to. Reads are synchronous and local; anything
/// that can touch the network is async.
@MainActor
protocol MailEngine: AnyObject {
    var onThreadsUpdated: (() -> Void)? { get set }
    var onAccountDisconnected: ((String) -> Void)? { get set }
    /// A sync round applied settings written on another device: account
    /// name/colour/signature, triage labels, prefs, the AI model or the
    /// triage switch. Re-read them. Never fires for this device's own
    /// edits, so it cannot race the optimistic UI.
    var onPrefsUpdated: (() -> Void)? { get set }

    func accounts() throws -> [MailAccount]
    func accountStates() throws -> [AccountState]
    func labels() throws -> [MailLabelItem]
    func triageLabels() throws -> [TriageLabelItem]
    func unreadCounts(accountId: String?) throws -> [String: Int]
    /// Newest first; `before` is the previous page's last `lastMessageAt`.
    func threads(in view: MailView, accountId: String?, before: Date?, limit: Int) throws -> [ThreadRow]
    func search(_ query: String, limit: Int) throws -> [ThreadRow]
    func thread(id: String) async throws -> ThreadDetail?
    /// The thread's saved Gmail draft, ready for the composer (keyed so its
    /// saves update that draft). Nil when the thread holds none.
    func draft(threadId: String) async throws -> SendDraft?

    func perform(_ action: MailAction, accountId: String) async throws
    func setReminder(threadId: String, at date: Date?, onlyIfNoReply: Bool) throws
    func setNeedsReply(threadId: String, _ value: Bool) throws
    func setManualTriageLabels(threadId: String, ids: [String]) throws

    func updateAccount(id: String, displayName: String?, color: AccountColor?, signature: String?) throws
    /// Async: with push on, the engine first forgets the device at the relay and stops the Gmail watch.
    func removeAccount(id: String) async throws
    /// App-wide preferences synced between the user's devices (`pref:<name>`
    /// keys in the same Drive channel as reminders): the engine's store is
    /// the truth. Values are JSON-compatible — Bool, String, [String].
    /// Missing = never set.
    func prefs() throws -> [String: Any]
    /// Set (`value` non-nil) or clear (`nil`) one preference.
    func setPref(_ name: String, _ value: Any?) throws
    func syncAll() async throws -> Bool
    /// One account only (a silent push names the mailbox that changed).
    func syncNow(accountId: String) async throws -> Bool
    func beginOAuth(loginHint: String?) throws -> OAuthStart
    /// Resolves with the email that signed in.
    func finishOAuth(callbackURL: URL) async throws -> String

    // AI provider (BYO OpenAI key). The key never comes back out.
    func aiStatus() throws -> AIStatus
    func aiModels() throws -> [AIModel]
    func setAIKey(_ key: String) async throws
    func removeAIKey() throws
    func setAIModel(_ model: String) throws
    func aiEditText(instruction: String, text: String, history: String?) async throws -> String
    func aiDraftReply(subject: String, history: String, notes: String?) async throws -> String
    func aiSummarizeThread(subject: String, items: [(from: String, snippet: String)]) async throws -> String
    func aiSummarizeGroup(items: [(from: String, subject: String, snippet: String)]) async throws -> String

    // Optional iOS push relay (relay/README.md). The Google access token used
    // to authenticate with the relay never leaves the engine.
    func registerPushToken(relayURL: String, deviceToken: String, environment: String) async throws
    func disablePush() async throws
    func pushStatus() throws -> PushState

    // Jev triage.
    func triageStatus() throws -> TriageStatus
    func setJevKey(_ key: String) async throws
    func removeJevKey() throws
    func setAutoTriage(_ enabled: Bool) throws
    func createTriageLabel(name: String) throws -> TriageLabelItem
    func renameTriageLabel(id: String, name: String) throws
    func deleteTriageLabel(id: String) throws
    func reanalyzeTriage() throws
}
