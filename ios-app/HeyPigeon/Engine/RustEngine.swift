// MailEngine over the UniFFI `Engine` (desktop-app/crates/ffi). Pure
// mapping: every record becomes its app-side model here and nowhere else.

import Foundation
import HeyPigeonCore

@MainActor
final class RustEngine: MailEngine {
    var onThreadsUpdated: (() -> Void)?
    var onAccountDisconnected: ((String) -> Void)?

    private let engine: Engine
    private var listener: Listener?

    /// `dataDir` is the app's Application Support directory; the database,
    /// the body/attachment cache and (off Apple targets) the dev secret file
    /// live there. Tokens go to the Keychain.
    init(dataDir: URL, clientId: String) throws {
        engine = try Engine.open(
            dataDir: dataDir.path,
            oauth: OauthClient(clientId: clientId, clientSecret: nil)
        )
        let l = Listener(owner: self)
        listener = l
        engine.setListener(listener: l)
    }

    // Engine callbacks arrive on Rust threads; hop to the main actor.
    private final class Listener: EngineListener, @unchecked Sendable {
        weak var owner: RustEngine?
        init(owner: RustEngine) { self.owner = owner }
        func onThreadsUpdated() {
            Task { @MainActor [weak owner] in owner?.onThreadsUpdated?() }
        }
        func onAccountDisconnected(accountId: String) {
            Task { @MainActor [weak owner] in owner?.onAccountDisconnected?(accountId) }
        }
    }

    func accounts() throws -> [MailAccount] {
        try engine.listAccounts().map(MailAccount.init)
    }

    func accountStates() throws -> [AccountState] {
        try engine.accountStatus().map { s in
            AccountState(
                id: s.accountId,
                isConnected: s.connection == .connected,
                syncState: {
                    switch s.sync {
                    case .pending: "pending"
                    case .ok: "ok"
                    case .unavailable: "unavailable"
                    case .authExpired: "auth_expired"
                    case .error: "error"
                    }
                }(),
                syncDetail: s.syncDetail,
                lastSyncAt: s.lastSyncAt.map(Date.init(epochMs:))
            )
        }
    }

    func labels() throws -> [MailLabelItem] {
        try engine.listLabels().map { MailLabelItem(id: $0.id, accountId: $0.accountId, name: $0.name) }
    }

    func unreadCounts(accountId: String?) throws -> [String: Int] {
        try engine.unreadCounts(accountId: accountId).mapValues(Int.init)
    }

    func threads(in view: MailView, accountId: String?, before: Date?, limit: Int) throws -> [ThreadRow] {
        let rows: [MailThread]
        switch view {
        case .scheduled:
            rows = try engine.listScheduled().filter { accountId == nil || $0.accountId == accountId }
        case .needReply:
            rows = try engine.listNeedsReply().filter { accountId == nil || $0.accountId == accountId }
        default:
            rows = try engine.listThreads(
                filter: view.filter, accountId: accountId,
                before: before.map(\.epochMs), limit: UInt32(limit)
            )
        }
        return rows.map(ThreadRow.init)
    }

    func search(_ query: String, limit: Int) throws -> [ThreadRow] {
        try engine.search(query: query, limit: UInt32(limit)).map { hit in
            ThreadRow(hit.thread, snippet: hit.snippet.highlightMarkersStripped)
        }
    }

    func thread(id: String) async throws -> ThreadDetail? {
        guard let t = try await engine.getThread(threadId: id) else { return nil }
        let me = t.thread.accountId
        return ThreadDetail(thread: ThreadRow(t.thread), messages: t.messages.map { MessageItem($0, myEmail: me) })
    }

    func perform(_ action: MailAction, accountId: String) async throws {
        try await engine.mutate(accountId: accountId, mutation: action.mutation)
    }

    func setReminder(threadId: String, at date: Date?, onlyIfNoReply: Bool) throws {
        try engine.setSchedule(threadId: threadId, scheduledAt: date.map(\.epochMs), followUp: onlyIfNoReply)
    }

    func setNeedsReply(threadId: String, _ value: Bool) throws {
        try engine.setNeedsReply(threadId: threadId, needsReply: value)
    }

    func removeAccount(id: String) throws {
        try engine.removeAccount(accountId: id)
    }

    func syncAll() async throws -> Bool {
        try await engine.syncAll()
    }

    func beginOAuth(loginHint: String?) throws -> OAuthStart {
        let s = try engine.beginOauth(loginHint: loginHint, redirectUri: nil)
        guard let url = URL(string: s.url) else { throw URLError(.badURL) }
        return OAuthStart(url: url, callbackScheme: s.callbackScheme)
    }

    func finishOAuth(callbackURL: URL) async throws -> String {
        try await engine.finishOauth(callbackUrl: callbackURL.absoluteString)
    }
}

// MARK: - Mapping

private extension Date {
    init(epochMs: Int64) { self.init(timeIntervalSince1970: Double(epochMs) / 1000) }
    var epochMs: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}

private extension String {
    /// core::search wraps matches in U+E000 / U+E001; the row shows plain text.
    var highlightMarkersStripped: String {
        replacingOccurrences(of: "\u{E000}", with: "").replacingOccurrences(of: "\u{E001}", with: "")
    }
}

private extension MailAccount {
    init(_ a: Account) {
        self.init(
            id: a.id, email: a.email, displayName: a.displayName,
            color: AccountColor(rawValue: a.color) ?? .sky,
            avatarURL: a.avatarUrl.flatMap(URL.init(string:)), signature: a.signature
        )
    }
}

private extension ThreadRow {
    init(_ t: MailThread, snippet: String? = nil) {
        self.init(
            id: t.id, accountId: t.accountId, subject: t.subject, snippet: snippet ?? t.snippet,
            lastMessageAt: Date(epochMs: t.lastMsgAt), isRead: t.isRead, isArchived: t.isArchived,
            messageCount: Int(t.msgCount), fromSummary: t.fromSummary, lastFromAddress: t.lastFromAddr,
            scheduledAt: t.scheduledAt.map(Date.init(epochMs:)),
            isFollowUp: t.followUpSince != nil && t.scheduledAt != nil,
            needsReply: t.needsReply, isStarred: t.labels.contains("STARRED"),
            hasAttachment: t.hasAttachment,
            priority: t.priority.map {
                switch $0 {
                case .spam: .spam
                case .low: .low
                case .medium: .medium
                case .high: .high
                }
            },
            triageLabelIds: t.triageLabelIds, labels: t.labels
        )
    }
}

private extension MessageItem {
    init(_ m: MailMessage, myEmail: String) {
        let address = m.fromAddr.firstMatchInAngleBrackets ?? m.fromAddr
        let name = m.fromAddr.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        self.init(
            id: m.id,
            fromName: name.isEmpty ? address : name.trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
            fromAddress: address,
            to: m.toAddrs.map { a in
                let addr = a.firstMatchInAngleBrackets ?? a
                return addr.caseInsensitiveCompare(myEmail) == .orderedSame ? "me" : addr
            },
            date: Date(epochMs: m.date), snippet: m.snippet,
            bodyHTML: m.bodyHtml, bodyText: m.bodyText, isRead: m.isRead,
            isMine: m.fromAddr.localizedCaseInsensitiveContains(myEmail)
        )
    }
}

private extension String {
    var firstMatchInAngleBrackets: String? {
        guard let open = firstIndex(of: "<"), let close = self[open...].firstIndex(of: ">") else { return nil }
        return String(self[index(after: open)..<close])
    }
}

private extension MailView {
    var filter: ThreadFilter {
        switch self {
        case .inbox, .scheduled, .needReply: .inbox
        case .starred: .starred
        case .drafts: .drafts
        case .sent: .sent
        case .archive: .archive
        case .all: .all
        case .spam: .spam
        case .trash: .trash
        case .label(let id, _): .label(id: id)
        }
    }
}

private extension MailAction {
    var mutation: Mutation {
        switch self {
        case .archive(let id): .archive(threadId: id)
        case .unarchive(let id): .unarchive(threadId: id)
        case .markRead(let id, let read): .markRead(threadId: id, read: read)
        case .trash(let id): .trash(threadId: id)
        case .star(let id, let starred): .star(threadId: id, starred: starred)
        case .modifyLabel(let id, let label, let add): .modifyLabel(threadId: id, labelId: label, add: add)
        case .send(let d):
            .send(to: d.to, cc: d.cc, bcc: d.bcc, subject: d.subject, bodyText: d.bodyText,
                  bodyHtml: nil, attachments: [], replyToThread: d.replyToThreadId)
        }
    }
}
