// The Mail app-intent domain's entities (docs/ios-intelligence.md, step 3
// and "iOS 27 › the .mail.thread schema"): what lets the new Siri
// understand "reply to Anna's email" with no custom phrase, because the
// system already knows what a mail app's message, draft, mailbox, account
// and — since iOS 27 — thread are. `MailAccountEntity` and the
// `.mail.thread` `MailThreadEntity` live in Entities.swift.
//
// A `MailMessageEntity` is a real message when the store holds the thread's
// messages (id `<threadId>#<messageId>`), else the thread's latest message
// built from the row alone (id = the thread id) — so a thread Siri names
// before it was ever opened still resolves, with no network. Either way the
// intents act on the thread (`threadId`), which is what the app does. Its
// body is never filled in — bodies stay in the engine.

import AppIntents
import Foundation

// MARK: - Mailbox

/// One folder of one account: `<accountId>|<folder>`.
@AppEntity(schema: .mail.mailbox)
struct MailboxEntity {
    static let defaultQuery = MailboxQuery()
    /// The folders that are a mailbox in Gmail's sense.
    static let folders: [MailFolder] = [.inbox, .archive, .starred, .drafts, .sent, .spam, .trash]

    let id: String
    var name: String
    var account: MailAccountEntity

    init(folder: MailFolder, account: MailAccount) {
        id = account.id + "|" + folder.rawValue
        name = folder.view.title
        self.account = MailAccountEntity(account)
    }

    var folder: MailFolder? { id.split(separator: "|").last.flatMap { MailFolder(rawValue: String($0)) } }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(account.emailAddress)", image: .init(systemName: folder?.view.systemImage ?? "tray"))
    }

    /// Where a row lives, from its Gmail labels.
    static func of(_ row: ThreadRow, account: MailAccount) -> MailboxEntity {
        let folder: MailFolder
        if row.labels.contains("TRASH") { folder = .trash }
        else if row.labels.contains("SPAM") { folder = .spam }
        else if row.labels.contains("DRAFT") { folder = .drafts }
        else if row.labels.contains("INBOX") { folder = .inbox }
        else if row.labels.contains("SENT") && row.messageCount == 1 { folder = .sent }
        else { folder = .archive }
        return MailboxEntity(folder: folder, account: account)
    }
}

struct MailboxQuery: EntityQuery {
    @MainActor
    private func all() async throws -> [MailboxEntity] {
        try await IntentSupport.model().accounts.flatMap { a in MailboxEntity.folders.map { MailboxEntity(folder: $0, account: a) } }
    }

    func entities(for identifiers: [String]) async throws -> [MailboxEntity] {
        try await all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [MailboxEntity] {
        try await all()
    }
}

// MARK: - Message

@AppEntity(schema: .mail.message)
struct MailMessageEntity {
    static let defaultQuery = MailMessageQuery()

    /// `<threadId>#<messageId>` for a stored message; the thread id alone
    /// for the thread-as-latest-message shape.
    let id: String
    /// The thread the intents act on.
    let threadId: String
    var to: [IntentPerson]
    var cc: [IntentPerson]
    var bcc: [IntentPerson]
    var subject: String?
    /// Never filled: the body stays in the engine (README "No backend").
    var body: AttributedString?
    var attachments: [IntentFile]
    var sender: IntentPerson
    var dateSent: Date
    var dateReceived: Date
    var isRead: Bool
    var isJunk: Bool
    var isFlagged: Bool
    var account: MailAccountEntity
    var mailbox: MailboxEntity

    /// The thread's latest message, from the row alone.
    init(_ row: ThreadRow, account: MailAccount) {
        id = row.id
        threadId = row.id
        to = []
        cc = []
        bcc = []
        subject = row.subject.isEmpty ? nil : row.subject
        body = nil
        attachments = []
        sender = .mail(row.lastFromAddress, name: Self.senderName(row))
        dateSent = row.lastMessageAt
        dateReceived = row.lastMessageAt
        isRead = row.isRead
        isJunk = row.labels.contains("SPAM")
        isFlagged = row.isPinned
        self.account = MailAccountEntity(account)
        mailbox = MailboxEntity.of(row, account: account)
    }

    /// One stored message of a thread.
    init(_ m: MessageItem, in detail: ThreadDetail, account: MailAccount) {
        let row = detail.thread
        id = Self.id(threadId: row.id, messageId: m.id)
        threadId = row.id
        to = m.to.map { $0 == "me" ? .mail(account.email, name: account.displayName, isMe: true) : .mail($0, name: nil) }
        cc = []
        bcc = []
        subject = row.subject.isEmpty ? nil : row.subject
        body = nil
        attachments = []
        sender = m.isMine ? .mail(account.email, name: account.displayName, isMe: true) : .mail(m.fromAddress, name: m.fromName)
        dateSent = m.date
        dateReceived = m.date
        isRead = m.isRead
        isJunk = row.labels.contains("SPAM")
        isFlagged = row.isPinned
        self.account = MailAccountEntity(account)
        mailbox = MailboxEntity.of(row, account: account)
    }

    static func id(threadId: String, messageId: String) -> String { threadId + "#" + messageId }

    /// The thread behind an entity id of either shape.
    static func threadId(of entityId: String) -> String {
        entityId.split(separator: "#", maxSplits: 1).first.map(String.init) ?? entityId
    }

    static func messageId(of entityId: String) -> String? {
        let parts = entityId.split(separator: "#", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : nil
    }

    /// The thread's messages as entities when the store has them, else the
    /// latest-message shape alone.
    @MainActor
    static func messages(of row: ThreadRow, in model: AppModel) -> [MailMessageEntity] {
        guard let account = model.account(for: row) else { return [] }
        if let detail = try? model.engine.threadLocal(id: row.id), !detail.messages.isEmpty {
            return detail.messages.map { MailMessageEntity($0, in: detail, account: account) }
        }
        return [MailMessageEntity(row, account: account)]
    }

    /// "Ana, Me (4)" → "Ana"; the address when the summary has no name.
    static func senderName(_ row: ThreadRow) -> String {
        let first = row.fromSummary.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return first.isEmpty || first == "Me" ? row.lastFromAddress : first
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(subject ?? "(no subject)")",
            subtitle: "\(Self.personLabel(sender)) · \(Formatters.rowTime(dateReceived))",
            image: .init(systemName: isRead ? "envelope.open" : "envelope.badge")
        )
    }

    static func personLabel(_ p: IntentPerson) -> String {
        if case .displayName(let n) = p.name { return n }
        return p.emailAddress ?? ""
    }
}

/// Resolves ids of both shapes, free text through the engine's search, and
/// "this email" as the open thread's latest message.
struct MailMessageQuery: EntityStringQuery {
    @MainActor
    private func make(_ rows: [ThreadRow], _ model: AppModel) -> [MailMessageEntity] {
        rows.compactMap { row in model.account(for: row).map { MailMessageEntity(row, account: $0) } }
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [MailMessageEntity] {
        let model = try await IntentSupport.model()
        return identifiers.compactMap { id in
            let threadId = MailMessageEntity.threadId(of: id)
            guard let row = try? model.engine.threadRow(id: threadId), let account = model.account(for: row) else { return nil }
            if let messageId = MailMessageEntity.messageId(of: id) {
                guard let detail = try? model.engine.threadLocal(id: threadId),
                      let m = detail.messages.first(where: { $0.id == messageId }) else { return nil }
                return MailMessageEntity(m, in: detail, account: account)
            }
            return MailMessageEntity(row, account: account)
        }
    }

    /// Siri resolving what is on screen wants titles fast: rows from the
    /// store, no messages, no network (iOS 27).
    @MainActor
    func displayRepresentations(for identifiers: [String], requestedComponents: DisplayRepresentation.Components) async throws -> [String: DisplayRepresentation] {
        let model = try await IntentSupport.model()
        var out: [String: DisplayRepresentation] = [:]
        for id in identifiers {
            guard let row = try? model.engine.threadRow(id: MailMessageEntity.threadId(of: id)) else { continue }
            out[id] = DisplayRepresentation(
                title: "\(row.subject.isEmpty ? "(no subject)" : row.subject)",
                subtitle: "\(MailMessageEntity.senderName(row)) · \(Formatters.rowTime(row.lastMessageAt))",
                image: .init(systemName: row.isRead ? "envelope.open" : "envelope.badge")
            )
        }
        return out
    }

    @MainActor
    func entities(matching string: String) async throws -> [MailMessageEntity] {
        let model = try await IntentSupport.model()
        return make((try? model.engine.search(string, limit: 20)) ?? [], model)
    }

    @MainActor
    func suggestedEntities() async throws -> [MailMessageEntity] {
        let model = try await IntentSupport.model()
        return make((try? model.engine.threads(in: .inbox, accountId: nil, before: nil, limit: 20)) ?? [], model)
    }

    @MainActor
    func defaultResult() async -> MailMessageEntity? {
        guard let model = AppModel.current, let open = model.openThread else { return nil }
        return MailMessageEntity.messages(of: open, in: model).last
    }
}

// MARK: - Draft

/// A composer draft. Its id is the draft's key: the open composer's
/// (`SendDraft.draftKey`) or, for a saved Gmail draft, the draft's message
/// id as the engine reports it.
@AppEntity(schema: .mail.draft)
struct MailDraftEntity {
    static let defaultQuery = MailDraftQuery()

    let id: String
    var to: [IntentPerson]
    var cc: [IntentPerson]
    var bcc: [IntentPerson]
    var subject: String?
    var body: AttributedString?
    var attachments: [IntentFile]
    var account: MailAccountEntity

    init(_ d: SendDraft, account: MailAccount) {
        id = d.draftKey
        to = d.to.map { .mail($0, name: nil) }
        cc = d.cc.map { .mail($0, name: nil) }
        bcc = d.bcc.map { .mail($0, name: nil) }
        subject = d.subject.isEmpty ? nil : d.subject
        body = d.bodyText.isEmpty ? nil : (d.bodyRich ?? AttributedString(d.bodyText))
        attachments = []
        self.account = MailAccountEntity(account)
    }

    var displayRepresentation: DisplayRepresentation {
        let who = to.first.map(MailMessageEntity.personLabel) ?? "no recipient"
        return DisplayRepresentation(title: "\(subject ?? "(no subject)")", subtitle: "Draft to \(who)", image: .init(systemName: "doc"))
    }
}

/// A draft's key — the composer's, or the Gmail draft's message id — is
/// what the user's other devices see too (iOS 27 `SyncableEntity`).
extension MailDraftEntity: SyncableEntity {}

struct MailDraftQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [MailDraftEntity] {
        let model = try await IntentSupport.model()
        var out: [MailDraftEntity] = []
        for id in identifiers {
            if let d = model.composeDraft, d.draftKey == id, let a = model.draftAccount(d) {
                out.append(MailDraftEntity(d, account: a))
            } else if let found = await model.gmailDraft(key: id), let a = model.account(for: found.row) {
                out.append(MailDraftEntity(found.draft, account: a))
            }
        }
        return out
    }

    @MainActor
    func suggestedEntities() async throws -> [MailDraftEntity] {
        let model = try await IntentSupport.model()
        var out: [MailDraftEntity] = []
        if let d = model.composeDraft, let a = model.draftAccount(d) { out.append(MailDraftEntity(d, account: a)) }
        for found in await model.gmailDrafts(limit: 10) {
            if let a = model.account(for: found.row) { out.append(MailDraftEntity(found.draft, account: a)) }
        }
        return out
    }
}

// MARK: - People

extension IntentPerson {
    /// A person from an address and, when known, a display name; `isMe`
    /// marks the user's own account so "mail from me" resolves.
    static func mail(_ address: String, name: String?, isMe: Bool = false) -> IntentPerson {
        let handle = IntentPerson.Handle(emailAddress: address, label: .other)
        guard let name, !name.isEmpty, name != address else { return IntentPerson(handle: handle) }
        return IntentPerson(identifier: .applicationDefined(address), name: .displayName(name),
                            handle: handle, aliases: [], isMe: isMe, image: nil)
    }

    /// The first email address among the person's handles, if any.
    var emailAddress: String? {
        let handles = [handle].compactMap { $0 } + aliases
        for h in handles { if case .emailAddress(let a) = h.value { return a } }
        for h in handles { if case .applicationDefined(let a) = h.value, a.contains("@") { return a } }
        return nil
    }
}

extension Array where Element == IntentPerson {
    var emailAddresses: [String] { compactMap(\.emailAddress) }
}

extension AppModel {
    /// The account a draft sends from: its own, else the selected, else the first.
    func draftAccount(_ d: SendDraft) -> MailAccount? {
        accounts.first { $0.id == d.fromAccountId } ?? currentAccount ?? accounts.first
    }
}
