// What the system can name: a thread, an account, a Gmail label and a
// folder. These are the nouns of every Siri / Shortcuts / Spotlight /
// widget entry point (docs/ios-intelligence.md). Thin copies of the models
// the app already has, carrying only what the system needs to show and
// disambiguate — bodies never leave the engine.

import AppIntents
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

// MARK: - Thread

struct MailThreadEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Email")
    static let defaultQuery = MailThreadQuery()

    let id: String
    @Property(title: "Subject") var subject: String
    @Property(title: "From") var from: String
    @Property(title: "Preview") var snippet: String
    @Property(title: "Received") var receivedAt: Date
    @Property(title: "Account") var account: MailAccountEntity
    @Property(title: "Unread") var isUnread: Bool
    @Property(title: "Pinned") var isPinned: Bool
    @Property(title: "Needs reply") var needsReply: Bool
    @Property(title: "Reminder") var reminderAt: Date?
    @Property(title: "Done") var isDone: Bool
    @Property(title: "Has attachment") var hasAttachment: Bool

    /// The sender's address, for the Spotlight index only.
    let senderAddress: String

    init(_ row: ThreadRow, account: MailAccount?) {
        id = row.id
        subject = row.subject.isEmpty ? "(no subject)" : row.subject
        from = row.fromSummary
        snippet = row.snippet
        receivedAt = row.lastMessageAt
        self.account = MailAccountEntity(account ?? MailAccount(
            id: row.accountId, email: row.accountId, displayName: row.accountId, color: .sky, avatarURL: nil, signature: ""
        ))
        isUnread = !row.isRead
        isPinned = row.isPinned
        needsReply = row.needsReply
        reminderAt = row.scheduledAt
        isDone = row.isDone
        hasAttachment = row.hasAttachment
        senderAddress = row.lastFromAddress
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(subject)",
            subtitle: "\(from) · \(Formatters.rowTime(receivedAt))",
            image: .init(systemName: isUnread ? "envelope.badge" : "envelope.open")
        )
    }

    /// What Spotlight (and, through it, Siri's personal context) learns:
    /// subject, sender, one preview line, when, which account. No body.
    var attributeSet: CSSearchableItemAttributeSet {
        let a = CSSearchableItemAttributeSet(contentType: .emailMessage)
        a.title = subject
        a.contentDescription = snippet
        a.authorNames = [from]
        a.authorEmailAddresses = senderAddress.isEmpty ? nil : [senderAddress]
        a.contentCreationDate = receivedAt
        a.contentModificationDate = receivedAt
        a.containerIdentifier = account.id
        a.containerTitle = account.name
        a.domainIdentifier = account.id
        return a
    }
}

/// Siri resolves "the one from Anna", "this email" (the open thread) and
/// free text through the app's own search; Shortcuts pick from the inbox.
struct MailThreadQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [MailThreadEntity] {
        let model = try await IntentSupport.model()
        return identifiers.compactMap { id in
            (try? model.engine.threadRow(id: id)).flatMap { $0 }.map { MailThreadEntity($0, account: model.account(for: $0)) }
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [MailThreadEntity] {
        let model = try await IntentSupport.model()
        let rows = (try? model.engine.search(string, limit: 20)) ?? []
        return rows.map { MailThreadEntity($0, account: model.account(for: $0)) }
    }

    @MainActor
    func suggestedEntities() async throws -> [MailThreadEntity] {
        let model = try await IntentSupport.model()
        let rows = (try? model.engine.threads(in: .inbox, accountId: nil, before: nil, limit: 20)) ?? []
        return rows.map { MailThreadEntity($0, account: model.account(for: $0)) }
    }

    /// "Remind me about this": the thread on screen, when one is open.
    @MainActor
    func defaultResult() async -> MailThreadEntity? {
        guard let model = AppModel.current, let open = model.openThread else { return nil }
        return MailThreadEntity(open, account: model.account(for: open))
    }
}

// MARK: - Account

struct MailAccountEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Account")
    static let defaultQuery = MailAccountQuery()

    let id: String
    @Property(title: "Email") var email: String
    @Property(title: "Name") var name: String

    init(_ a: MailAccount) {
        id = a.id
        email = a.email
        name = a.displayName
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(email)", image: .init(systemName: "person.crop.circle"))
    }
}

struct MailAccountQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [MailAccountEntity] {
        let model = try await IntentSupport.model()
        return model.accounts.filter { identifiers.contains($0.id) }.map(MailAccountEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [MailAccountEntity] {
        try await IntentSupport.model().accounts.map(MailAccountEntity.init)
    }
}

// MARK: - Gmail label

struct MailLabelEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Label")
    static let defaultQuery = MailLabelQuery()

    /// `<accountId>|<labelId>`: label ids repeat across accounts.
    let id: String
    let accountId: String
    let labelId: String
    @Property(title: "Name") var name: String

    init(_ l: MailLabelItem) {
        id = l.accountId + "|" + l.id
        accountId = l.accountId
        labelId = l.id
        name = l.name
    }

    var item: MailLabelItem { MailLabelItem(id: labelId, accountId: accountId, name: name) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(accountId)", image: .init(systemName: "tag"))
    }
}

struct MailLabelQuery: EntityStringQuery {
    @MainActor
    private func all() async throws -> [MailLabelEntity] {
        try await IntentSupport.model().labels
            .filter { !$0.id.hasPrefix("CATEGORY_") }
            .map(MailLabelEntity.init)
    }

    func entities(for identifiers: [String]) async throws -> [MailLabelEntity] {
        try await all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [MailLabelEntity] {
        try await all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [MailLabelEntity] {
        try await all()
    }
}

// MARK: - Folder

/// The sidebar's folders and the two tabs, as a fixed list the system can
/// put in a phrase: "Open Scheduled in Hey Pigeon".
enum MailFolder: String, AppEnum {
    case inbox, scheduled, needReply, starred, drafts, sent, archive, all, spam, trash

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Folder")
    static let caseDisplayRepresentations: [MailFolder: DisplayRepresentation] = [
        .inbox: "Inbox",
        .scheduled: "Scheduled",
        .needReply: "Need reply",
        .starred: "Starred",
        .drafts: "Drafts",
        .sent: "Sent",
        .archive: "Archive",
        .all: "All emails",
        .spam: "Spam",
        .trash: "Trash",
    ]

    var view: MailView {
        switch self {
        case .inbox: .inbox
        case .scheduled: .scheduled
        case .needReply: .needReply
        case .starred: .starred
        case .drafts: .drafts
        case .sent: .sent
        case .archive: .archive
        case .all: .all
        case .spam: .spam
        case .trash: .trash
        }
    }
}

/// The Remind sheet's presets as something Siri can offer in a list.
enum RemindWhen: String, AppEnum {
    case laterToday, tomorrow, thisWeekend, nextWeek, inAMonth, pickDate

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "When")
    static let caseDisplayRepresentations: [RemindWhen: DisplayRepresentation] = [
        .laterToday: "Later today",
        .tomorrow: "Tomorrow",
        .thisWeekend: "This weekend",
        .nextWeek: "Next week",
        .inAMonth: "In a month",
        .pickDate: "Pick a date…",
    ]

    var preset: ReminderPreset? {
        switch self {
        case .laterToday: .laterToday
        case .tomorrow: .tomorrow
        case .thisWeekend: .thisWeekend
        case .nextWeek: .nextWeek
        case .inAMonth: .inAMonth
        case .pickDate: nil
        }
    }

    /// The presets that make sense right now ("Later today" only before 18:00), then "Pick a date…".
    static func offered(now: Date = Date()) -> [RemindWhen] {
        allCases.filter { $0 == .pickDate || $0.preset?.date(now: now) != nil }
    }
}
