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
    let isStarred: Bool
    let hasAttachment: Bool
    let priority: TriageLevel?
    let triageLabelIds: [String]
    /// Gmail label ids over the thread (INBOX, STARRED, Label_…).
    let labels: [String]

    var isConversation: Bool { messageCount > 1 }
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

struct MailLabelItem: Identifiable, Hashable {
    let id: String
    let accountId: String
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
        case .all: "All mail"
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
        case .starred: "star"
        case .drafts: "doc"
        case .sent: "paperplane"
        case .archive: "archivebox"
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

    /// Views where "archive" means "done" and rows should slide out.
    var archivesOut: Bool {
        switch self {
        case .inbox, .starred, .label, .scheduled, .needReply: true
        default: false
        }
    }

    static let folders: [MailView] = [
        .inbox, .scheduled, .needReply, .starred, .drafts, .sent, .archive, .all, .spam, .trash,
    ]
}

struct SendDraft: Hashable {
    var to: [String] = []
    var cc: [String] = []
    var bcc: [String] = []
    var subject: String = ""
    var bodyText: String = ""
    var replyToThreadId: String?
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

    func accounts() throws -> [MailAccount]
    func accountStates() throws -> [AccountState]
    func labels() throws -> [MailLabelItem]
    func unreadCounts(accountId: String?) throws -> [String: Int]
    /// Newest first; `before` is the previous page's last `lastMessageAt`.
    func threads(in view: MailView, accountId: String?, before: Date?, limit: Int) throws -> [ThreadRow]
    func search(_ query: String, limit: Int) throws -> [ThreadRow]
    func thread(id: String) async throws -> ThreadDetail?

    func perform(_ action: MailAction, accountId: String) async throws
    func setReminder(threadId: String, at date: Date?, onlyIfNoReply: Bool) throws
    func setNeedsReply(threadId: String, _ value: Bool) throws
    func removeAccount(id: String) throws

    func syncAll() async throws -> Bool
    func beginOAuth(loginHint: String?) throws -> OAuthStart
    /// Resolves with the email that signed in.
    func finishOAuth(callbackURL: URL) async throws -> String
}
