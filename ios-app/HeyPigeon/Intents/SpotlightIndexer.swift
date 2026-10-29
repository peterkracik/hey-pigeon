// The Spotlight index is how the new Siri's personal context learns about
// the inbox ("did Anna reply about the invoice?"), how Spotlight finds a
// thread, and — on iOS 27 — what "Ask my inbox" reads through
// `SpotlightSearchTool` (AI/InboxAsk.swift). Rebuilt after every sync, like
// the reminder notifications: the newest 500 threads of each account,
// subject · sender · one preview line · participants · labels, and the
// text of the newest messages when the store already has it (threads
// opened before; never a fetch for the index's sake). Alongside each
// thread, its stored messages as `.mail.message` items (MailSchema.swift):
// Siri's model of mail is message-shaped, and a message item is what lets
// "the email from Anna about the deposit" land on Hey Pigeon's mail rather
// than Apple Mail's when both are indexed. Trash and spam are dropped.
// Settings › Siri & Search turns it off and drains it.
//
// Body text is searchable but Spotlight returns only the attributes it
// was given at query time, so the tool reads full items back through the
// `CSSearchableIndexDelegate` below (`searchableItems(forIdentifiers:)`),
// built from the store on demand.

import CoreSpotlight
import Foundation

enum SpotlightIndexer {
    static let perAccount = 500

    /// What each thread looked like when it was last indexed, by id: a
    /// refresh re-indexes only the threads whose fingerprint moved instead
    /// of reading every thread's messages from the store after every sync.
    /// In memory, so the first refresh after a launch indexes everything.
    @MainActor private static var indexed: [String: Int] = [:]

    @MainActor
    static func refresh(_ model: AppModel) async {
        guard model.siriIndexEnabled else { return }
        let labelNames = labelNameMap(model)
        var keep: [MailThreadEntity] = []
        var keepMessages: [MailMessageEntity] = []
        var drop: [String] = []
        var dropMessages: [String] = []
        var fresh: [String: Int] = [:]
        for account in model.accounts {
            let rows = (try? model.engine.threads(in: .all, accountId: account.id, before: nil, limit: perAccount)) ?? []
            for row in rows {
                let names = labelNames(row)
                let print = fingerprint(row, labelNames: names, account: account)
                let gone = row.labels.contains("TRASH") || row.labels.contains("SPAM")
                // Unchanged since the last refresh: nothing to tell Spotlight.
                if !gone, indexed[row.id] == print { continue }
                let thread = entity(for: row, in: model, labelNames: names)
                let stored = thread.messages.filter(\.isStoredMessage)
                if gone {
                    if indexed[row.id] != nil || indexed.isEmpty {
                        drop.append(row.id)
                        dropMessages += stored.map(\.id)
                    }
                    indexed[row.id] = nil
                } else {
                    keep.append(thread)
                    keepMessages += stored.suffix(messagesPerThread)
                    fresh[row.id] = print
                }
            }
        }
        let index = CSSearchableIndex.default()
        if !keep.isEmpty { try? await index.indexAppEntities(keep) }
        if !keepMessages.isEmpty { try? await index.indexAppEntities(keepMessages) }
        if !drop.isEmpty { try? await index.deleteAppEntities(identifiedBy: drop, ofType: MailThreadEntity.self) }
        if !dropMessages.isEmpty { try? await index.deleteAppEntities(identifiedBy: dropMessages, ofType: MailMessageEntity.self) }
        indexed.merge(fresh) { _, new in new }
    }

    /// Everything the index shows of a thread: the row itself (flags,
    /// snippet, labels, message count), its label names and the account's
    /// name. Bodies are not in it; `invalidate` covers a thread whose
    /// bodies just arrived.
    static func fingerprint(_ row: ThreadRow, labelNames: [String], account: MailAccount?) -> Int {
        var h = Hasher()
        h.combine(row)
        h.combine(labelNames)
        h.combine(account?.displayName)
        h.combine(account?.email)
        return h.finalize()
    }

    /// The thread's message bodies are now in the store (it was opened):
    /// the next refresh indexes their text.
    @MainActor
    static func invalidate(threadId: String) {
        indexed[threadId] = nil
    }

    /// Forget every fingerprint: the next refresh indexes every thread.
    @MainActor
    static func invalidateAll() {
        indexed = [:]
    }

    /// The newest stored messages of a thread that go in as message items;
    /// the thread item carries the rest of the text up to its own cap.
    static let messagesPerThread = 20

    /// Gmail label id → name per account, built once per refresh instead
    /// of a scan of every label for every row.
    @MainActor
    private static func labelNameMap(_ model: AppModel) -> (ThreadRow) -> [String] {
        var names: [String: String] = [:]
        for l in model.labels { names[l.accountId + "|" + l.id] = l.name }
        return { row in row.labels.compactMap { names[row.accountId + "|" + $0] } }
    }

    /// One thread as the index sees it: the row, the account, the label
    /// names, and the stored messages (bodies when they are local).
    @MainActor
    static func entity(for row: ThreadRow, in model: AppModel, labelNames: [String]? = nil) -> MailThreadEntity {
        let detail = try? model.engine.threadLocal(id: row.id)
        let names = labelNames ?? row.labels.compactMap { id in model.labels.first { $0.id == id && $0.accountId == row.accountId }?.name }
        return MailThreadEntity(row, account: model.account(for: row), detail: detail, labelNames: names)
    }

    /// Settings turned the index off, or an account was removed: forget it
    /// all; the next refresh (if on) rebuilds from the store.
    @MainActor
    static func clear() async {
        indexed = [:]
        try? await CSSearchableIndex.default().deleteAllSearchableItems()
    }

    /// Installed once at launch so Spotlight (and the search tool) can ask
    /// the app for items it does not hold itself.
    @MainActor
    static func installDelegate() {
        CSSearchableIndex.default().indexDelegate = SpotlightIndexDelegate.shared
    }
}

/// Spotlight's questions to the app: rebuild everything (after a restore or
/// an OS update), rebuild these ids, and — iOS 27 — hand back the full
/// items for ids a search returned, which is how `SpotlightSearchTool`
/// reads the body text the index only searched.
final class SpotlightIndexDelegate: NSObject, CSSearchableIndexDelegate, Sendable {
    static let shared = SpotlightIndexDelegate()

    // Spotlight's handler and index are not Sendable; each is used once,
    // from the one task the call starts.
    func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void) {
        nonisolated(unsafe) let done = acknowledgementHandler
        Task { @MainActor in
            if let model = AppModel.current {
                // Spotlight lost its copy: index everything again.
                SpotlightIndexer.invalidateAll()
                await SpotlightIndexer.refresh(model)
            }
            done()
        }
    }

    func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexSearchableItemsWithIdentifiers identifiers: [String], acknowledgementHandler: @escaping () -> Void) {
        nonisolated(unsafe) let done = acknowledgementHandler
        nonisolated(unsafe) let index = searchableIndex
        Task {
            let items = await Self.entries(for: identifiers).map(\.item)
            if !items.isEmpty { try? await index.indexSearchableItems(items) }
            done()
        }
    }

    /// The items for these ids, from the store (iOS 27: what the search tool
    /// reads after a hit). Off when the Settings toggle is off, so nothing
    /// leaves the store while the user has the index drained.
    func searchableItems(forIdentifiers identifiers: [String]) async -> [CSSearchableItem] {
        await Self.entries(for: identifiers).map(\.item)
    }

    /// What one id indexes as: entities are values and cross the actor
    /// boundary; the `CSSearchableItem` is made on the caller's side.
    private enum Entry: Sendable {
        case thread(MailThreadEntity)
        case message(MailMessageEntity)

        var item: CSSearchableItem {
            switch self {
            case .thread(let thread):
                return thread.searchableItem
            case .message(let message):
                let item = CSSearchableItem(uniqueIdentifier: message.id, domainIdentifier: message.account.id, attributeSet: message.attributeSet)
                item.associateAppEntity(message, priority: 0)
                return item
            }
        }
    }

    /// Thread ids and message ids (`<threadId>#<messageId>`) alike.
    @MainActor
    private static func entries(for identifiers: [String]) -> [Entry] {
        guard let model = AppModel.current, model.siriIndexEnabled else { return [] }
        return identifiers.compactMap { id in
            let threadId = MailMessageEntity.threadId(of: id)
            guard let row = try? model.engine.threadRow(id: threadId),
                  !row.labels.contains("TRASH"), !row.labels.contains("SPAM") else { return nil }
            let thread = SpotlightIndexer.entity(for: row, in: model)
            guard MailMessageEntity.messageId(of: id) != nil else { return .thread(thread) }
            return thread.messages.first(where: { $0.id == id }).map { .message($0) }
        }
    }
}
