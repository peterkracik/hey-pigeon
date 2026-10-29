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

/// The `.mail.thread` schema (iOS 27): a thread with its `messages`, so
/// Siri's model of the app matches the app's own shape instead of the
/// thread-as-message workaround alone. The extra properties are the row's
/// flags, for Shortcuts filters. Also what Spotlight indexes
/// (`IndexedEntity`), what syncs across the user's devices
/// (`SyncableEntity`: Gmail thread ids are stable everywhere) and private
/// by default (`OwnershipProvidingEntity`) — iOS 27 conformances below.
@AppEntity(schema: .mail.thread)
struct MailThreadEntity {
    static let defaultQuery = MailThreadQuery()

    let id: String
    /// The thread's messages: the stored ones when the store has them,
    /// else the latest-message shape alone (MailSchema.swift).
    var messages: [MailMessageEntity]
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
    /// For the Spotlight index only (never shown by Siri as a property):
    /// the participants with their addresses, the Gmail label names, and
    /// the body text of the newest messages when the store has it — what
    /// makes "what did the landlord say about the deposit" answerable by
    /// `SpotlightSearchTool` on device. Capped so one thread cannot swamp
    /// the index.
    let participantNames: [String]
    let participantAddresses: [String]
    let labelNames: [String]
    let bodyText: String?

    static let bodyTextCap = 4_000

    init(_ row: ThreadRow, account: MailAccount?, detail: ThreadDetail? = nil, labelNames: [String] = []) {
        // Plain stored properties first: assigning an @Property goes through
        // the wrapper, which needs `self` whole (the first compile said so).
        id = row.id
        let resolved = account ?? MailAccount(id: row.accountId, email: row.accountId, displayName: row.accountId, color: .sky, avatarURL: nil, signature: "")
        if let detail, !detail.messages.isEmpty {
            messages = detail.messages.map { MailMessageEntity($0, in: detail, account: resolved) }
        } else {
            messages = [MailMessageEntity(row, account: resolved)]
        }
        senderAddress = row.lastFromAddress
        self.labelNames = labelNames
        let stored = detail?.messages ?? []
        var names: [String] = []
        var addresses: [String] = []
        for m in stored {
            if !m.isMine, !m.fromAddress.isEmpty, !addresses.contains(m.fromAddress) {
                addresses.append(m.fromAddress)
                names.append(m.fromName)
            }
            for a in m.to where a != "me" && !a.isEmpty && !addresses.contains(a) {
                addresses.append(a)
                names.append(a)
            }
        }
        participantNames = names
        participantAddresses = addresses
        bodyText = Self.indexableBody(stored)
        // Then the @Property ones.
        subject = row.subject.isEmpty ? "(no subject)" : row.subject
        from = row.fromSummary
        snippet = row.snippet
        receivedAt = row.lastMessageAt
        self.account = MailAccountEntity(resolved)
        isUnread = !row.isRead
        isPinned = row.isPinned
        needsReply = row.needsReply
        reminderAt = row.scheduledAt
        isDone = row.isDone
        hasAttachment = row.hasAttachment
    }

    /// Newest messages first, plain text, until the cap: the end of a long
    /// thread is what a question is usually about.
    static func indexableBody(_ messages: [MessageItem]) -> String? {
        var out: [String] = []
        var used = 0
        for m in messages.reversed() {
            guard let text = m.bodyText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let main = MessageBodyView.splitQuoted(text)?.main ?? text
            let line = "\(m.isMine ? "Me" : m.fromName): \(main)"
            let room = bodyTextCap - used
            guard room > 40 else { break }
            let piece = line.count > room ? String(line.prefix(room)) : line
            out.insert(piece, at: 0)
            used += piece.count + 2
        }
        return out.isEmpty ? nil : out.joined(separator: "\n\n")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(subject)",
            subtitle: "\(from) · \(Formatters.rowTime(receivedAt))",
            image: .init(systemName: isUnread ? "envelope.badge" : "envelope.open")
        )
    }

    /// What Spotlight (and, through it, Siri's personal context and the
    /// on-device "Ask my inbox" tool) learns: subject, sender, one preview
    /// line, when, which account, the participants and labels, and — when
    /// the store has it — the text of the newest messages as `textContent`
    /// (searchable, read back only through the index delegate). All on
    /// this device, behind Settings › Siri & Search.
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
        a.accountIdentifier = account.id
        a.accountHandles = [account.emailAddress]
        if !participantNames.isEmpty {
            a.recipientNames = participantNames
            a.recipientEmailAddresses = participantAddresses
        }
        if !labelNames.isEmpty { a.keywords = labelNames }
        a.mailboxIdentifiers = [isDone ? "archive" : "inbox"]
        a.textContent = bodyText
        return a
    }

    /// The item the index delegate hands back for `SpotlightSearchTool`:
    /// the full attribute set, associated with this entity.
    var searchableItem: CSSearchableItem {
        let item = CSSearchableItem(uniqueIdentifier: id, domainIdentifier: account.id, attributeSet: attributeSet)
        item.associateAppEntity(self, priority: 0)
        return item
    }
}

extension MailThreadEntity: IndexedEntity {}

/// Gmail thread ids are the same on every device the account is on, so a
/// Siri conversation started on the iPhone can go on with the iPad or Mac
/// build later (iOS 27).
extension MailThreadEntity: SyncableEntity {}

/// Mail is the user's own: private by default, said explicitly, so Siri
/// asks before shared-content actions only where it should (iOS 27).
extension MailThreadEntity: OwnershipProvidingEntity {
    var ownership: EntityOwnership { .unknown }
}

/// Siri resolves "the one from Anna", "this email" (the open thread) and
/// free text through the app's own search; Shortcuts pick from the inbox.
/// Ids resolve with the stored messages (no network); the display
/// representations alone come from the rows, fast, for Siri reading what
/// is on screen (iOS 27).
struct MailThreadQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [MailThreadEntity] {
        let model = try await IntentSupport.model()
        return identifiers.compactMap { id in
            (try? model.engine.threadRow(id: id)).flatMap { $0 }.map {
                MailThreadEntity($0, account: model.account(for: $0), detail: try? model.engine.threadLocal(id: $0.id))
            }
        }
    }

    @MainActor
    func displayRepresentations(for identifiers: [String], requestedComponents: DisplayRepresentation.Components) async throws -> [String: DisplayRepresentation] {
        let model = try await IntentSupport.model()
        var out: [String: DisplayRepresentation] = [:]
        for id in identifiers {
            guard let row = try? model.engine.threadRow(id: id) else { continue }
            out[id] = DisplayRepresentation(
                title: "\(row.subject.isEmpty ? "(no subject)" : row.subject)",
                subtitle: "\(row.fromSummary) · \(Formatters.rowTime(row.lastMessageAt))",
                image: .init(systemName: row.isRead ? "envelope.open" : "envelope.badge")
            )
        }
        return out
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

/// The `.mail.account` schema: `name` and `emailAddress` are its words.
@AppEntity(schema: .mail.account)
struct MailAccountEntity {
    static let defaultQuery = MailAccountQuery()

    let id: String
    var name: String
    var emailAddress: String

    init(_ a: MailAccount) {
        id = a.id
        name = a.displayName
        emailAddress = a.email
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(emailAddress)", image: .init(systemName: "person.crop.circle"))
    }
}

/// A string query, not a plain one: the Mail-schema intents take an account
/// as a parameter, and the metadata extractor refuses a schema parameter
/// Siri cannot resolve from speech ("my work account").
struct MailAccountQuery: EntityStringQuery {
    @MainActor
    private func all() async throws -> [MailAccountEntity] {
        try await IntentSupport.model().accounts.map(MailAccountEntity.init)
    }

    func entities(for identifiers: [String]) async throws -> [MailAccountEntity] {
        try await all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [MailAccountEntity] {
        try await all().filter {
            $0.name.localizedCaseInsensitiveContains(string) || $0.emailAddress.localizedCaseInsensitiveContains(string)
        }
    }

    func suggestedEntities() async throws -> [MailAccountEntity] {
        try await all()
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
