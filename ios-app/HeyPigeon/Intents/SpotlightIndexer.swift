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
// The store is read off the main actor (`MailEngine.readInBackground`),
// and what each thread looked like when it was indexed is kept on disk
// (`Fingerprints`): a refresh reads only the threads that moved. Both
// used to happen on the main thread after every sync, from scratch after
// every launch — the messages of a thousand threads, bodies included — and
// the inbox froze for seconds while it ran.
//
// Body text is searchable but Spotlight returns only the attributes it
// was given at query time, so the tool reads full items back through the
// `CSSearchableIndexDelegate` below (`searchableItems(forIdentifiers:)`),
// built from the store on demand.

import CoreSpotlight
import Foundation

enum SpotlightIndexer {
    static let perAccount = 500
    /// Threads indexed per refresh, at most. A first index, or one after
    /// Spotlight lost its copy, covers a large mailbox over a few syncs
    /// instead of reading a thousand threads' messages in one go.
    static let perRefresh = 300

    /// The fingerprints of the indexed threads, by id, loaded from disk on
    /// first use and written back a moment after each change.
    @MainActor private static var loaded: [String: Int]?
    @MainActor private static var saveTask: Task<Void, Never>?

    @MainActor
    private static var fingerprints: [String: Int] {
        get {
            if let loaded { return loaded }
            let map = Fingerprints.load()
            loaded = map
            return map
        }
        set {
            loaded = newValue
            saveSoon()
        }
    }

    /// Write the fingerprints once the changes pause (a thread opened drops
    /// its own; a refresh adds hundreds).
    @MainActor
    private static func saveSoon() {
        saveTask?.cancel()
        let map = loaded ?? [:]
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            Fingerprints.save(map)
        }
    }

    @MainActor
    static func refresh(_ model: AppModel) async {
        guard model.siriIndexEnabled else { return }
        let accounts = model.accounts
        let labels = model.labels
        let known = fingerprints
        guard let plan = try? await model.engine.readInBackground({ store in
            Self.plan(store, accounts: accounts, labels: labels, known: known, cap: perRefresh)
        }) else { return }
        let index = CSSearchableIndex.default()
        if !plan.threads.isEmpty { try? await index.indexAppEntities(plan.threads) }
        if !plan.messages.isEmpty { try? await index.indexAppEntities(plan.messages) }
        if !plan.droppedThreads.isEmpty { try? await index.deleteAppEntities(identifiedBy: plan.droppedThreads, ofType: MailThreadEntity.self) }
        if !plan.droppedMessages.isEmpty { try? await index.deleteAppEntities(identifiedBy: plan.droppedMessages, ofType: MailMessageEntity.self) }
        // Read again: a thread opened meanwhile dropped its own fingerprint.
        var map = fingerprints
        for id in plan.forgotten { map[id] = nil }
        map.merge(plan.fresh) { _, new in new }
        fingerprints = map
    }

    /// What one refresh tells Spotlight: the threads whose fingerprint
    /// moved (with their stored messages), up to `cap` of them, and the
    /// trashed or spam ones to drop.
    struct Plan: Sendable {
        var threads: [MailThreadEntity] = []
        var messages: [MailMessageEntity] = []
        var droppedThreads: [String] = []
        var droppedMessages: [String] = []
        /// Fingerprints to remember (indexed now) and to forget (gone).
        var fresh: [String: Int] = [:]
        var forgotten: [String] = []
        /// `cap` was reached; the next refresh carries on from the store.
        var more = false
    }

    /// The store's side of a refresh, from any thread: every account's
    /// newest threads against `known`, the fingerprints of the last one.
    static func plan(_ store: any StoreReader, accounts: [MailAccount], labels: [MailLabelItem],
                     known: [String: Int], cap: Int) -> Plan {
        // Gmail label id → name per account, once, instead of a scan of
        // every label for every row.
        var names: [String: String] = [:]
        for l in labels { names[l.accountId + "|" + l.id] = l.name }
        var plan = Plan()
        var budget = cap
        for account in accounts {
            let rows = (try? store.threads(in: .all, accountId: account.id, before: nil, limit: perAccount)) ?? []
            for row in rows {
                let labelNames = row.labels.compactMap { names[row.accountId + "|" + $0] }
                let print = fingerprint(row, labelNames: labelNames, account: account)
                let gone = row.labels.contains("TRASH") || row.labels.contains("SPAM")
                // Unchanged since the last refresh: nothing to tell Spotlight.
                if !gone, known[row.id] == print { continue }
                // Junk that was never indexed: nothing to drop (on the first
                // pass Spotlight may still hold it from before).
                if gone, known[row.id] == nil, !known.isEmpty { continue }
                guard budget > 0 else {
                    plan.more = true
                    return plan
                }
                budget -= 1
                let detail = try? store.threadLocal(id: row.id)
                let thread = MailThreadEntity(row, account: account, detail: detail, labelNames: labelNames)
                let stored = thread.messages.filter(\.isStoredMessage)
                if gone {
                    plan.droppedThreads.append(row.id)
                    plan.droppedMessages += stored.map(\.id)
                    plan.forgotten.append(row.id)
                } else {
                    plan.threads.append(thread)
                    plan.messages += stored.suffix(messagesPerThread)
                    plan.fresh[row.id] = print
                }
            }
        }
        return plan
    }

    /// Everything the index shows of a thread: the row itself (flags,
    /// snippet, labels, message count), its label names and the account's
    /// name. Bodies are not in it; `invalidate` covers a thread whose
    /// bodies just arrived. Stable across launches — `Hasher` is seeded per
    /// process — so the fingerprints kept on disk still match.
    static func fingerprint(_ row: ThreadRow, labelNames: [String], account: MailAccount?) -> Int {
        var parts: [String] = [
            row.id, row.accountId, row.subject, row.snippet, String(row.lastMessageAt.timeIntervalSince1970),
            String(row.isRead), String(row.isArchived), String(row.messageCount), row.fromSummary, row.lastFromAddress,
            row.scheduledAt.map { String($0.timeIntervalSince1970) } ?? "", String(row.isFollowUp),
            String(row.needsReply), String(row.isStarred), String(row.hasAttachment), row.priority?.rawValue ?? "",
            row.triageLabelIds.joined(separator: ","), row.labels.joined(separator: ","),
            row.suggestion.map { String(describing: $0) } ?? "", row.bundleId ?? "",
        ]
        parts += labelNames
        parts.append(account?.displayName ?? "")
        parts.append(account?.email ?? "")
        return Int(bitPattern: UInt(truncatingIfNeeded: fnv1a(parts.joined(separator: "\u{1F}"))))
    }

    /// 64-bit FNV-1a: small and stable, for the fingerprints.
    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }

    /// The thread's message bodies are now in the store (it was opened):
    /// the next refresh indexes their text.
    @MainActor
    static func invalidate(threadId: String) {
        fingerprints[threadId] = nil
    }

    /// Forget every fingerprint: the next refresh indexes every thread.
    @MainActor
    static func invalidateAll() {
        fingerprints = [:]
    }

    /// The fingerprints on disk, next to the store: lost or unreadable, the
    /// next refresh indexes everything again, as it used to after every
    /// launch.
    enum Fingerprints {
        static var defaultURL: URL? {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("HeyPigeon", isDirectory: true)
                .appendingPathComponent("spotlight-fingerprints.json", isDirectory: false)
        }

        static func load(from url: URL? = defaultURL) -> [String: Int] {
            guard let url, let data = try? Data(contentsOf: url) else { return [:] }
            return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
        }

        static func save(_ map: [String: Int], to url: URL? = defaultURL) {
            guard let url, let data = try? JSONEncoder().encode(map) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// The newest stored messages of a thread that go in as message items;
    /// the thread item carries the rest of the text up to its own cap.
    static let messagesPerThread = 20

    /// One thread as the index sees it: the row, the account, the label
    /// names, and the stored messages (bodies when they are local). For a
    /// handful of ids on demand (the delegate below); a refresh plans its
    /// own off the main actor.
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
        fingerprints = [:]
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
