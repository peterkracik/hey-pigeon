// The Spotlight index is how the new Siri's personal context learns about
// the inbox ("did Anna reply about the invoice?"), how Spotlight finds a
// thread, and — on iOS 27 — what "Ask my inbox" reads through
// `SpotlightSearchTool` (AI/InboxAsk.swift). Rebuilt after every sync, like
// the reminder notifications: the newest 500 threads of each account,
// subject · sender · one preview line · participants · labels, and the
// text of the newest messages when the store already has it (threads
// opened before; never a fetch for the index's sake). Trash and spam are
// dropped. Settings › Siri & Search turns it off and drains it.
//
// Body text is searchable but Spotlight returns only the attributes it
// was given at query time, so the tool reads full items back through the
// `CSSearchableIndexDelegate` below (`searchableItems(forIdentifiers:)`),
// built from the store on demand.

import CoreSpotlight
import Foundation

enum SpotlightIndexer {
    static let perAccount = 500

    @MainActor
    static func refresh(_ model: AppModel) async {
        guard model.siriIndexEnabled else { return }
        var keep: [MailThreadEntity] = []
        var drop: [String] = []
        for account in model.accounts {
            let rows = (try? model.engine.threads(in: .all, accountId: account.id, before: nil, limit: perAccount)) ?? []
            for row in rows {
                if row.labels.contains("TRASH") || row.labels.contains("SPAM") {
                    drop.append(row.id)
                } else {
                    keep.append(entity(for: row, in: model))
                }
            }
        }
        let index = CSSearchableIndex.default()
        if !keep.isEmpty { try? await index.indexAppEntities(keep) }
        if !drop.isEmpty { try? await index.deleteAppEntities(identifiedBy: drop, ofType: MailThreadEntity.self) }
    }

    /// One thread as the index sees it: the row, the account, the label
    /// names, and the stored messages (bodies when they are local).
    @MainActor
    static func entity(for row: ThreadRow, in model: AppModel) -> MailThreadEntity {
        let detail = try? model.engine.threadLocal(id: row.id)
        let names = row.labels.compactMap { id in model.labels.first { $0.id == id && $0.accountId == row.accountId }?.name }
        return MailThreadEntity(row, account: model.account(for: row), detail: detail, labelNames: names)
    }

    /// Settings turned the index off, or an account was removed: forget it
    /// all; the next refresh (if on) rebuilds from the store.
    static func clear() async {
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
final class SpotlightIndexDelegate: NSObject, CSSearchableIndexDelegate {
    static let shared = SpotlightIndexDelegate()

    func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void) {
        Task { @MainActor in
            if let model = AppModel.current { await SpotlightIndexer.refresh(model) }
            acknowledgementHandler()
        }
    }

    func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexSearchableItemsWithIdentifiers identifiers: [String], acknowledgementHandler: @escaping () -> Void) {
        Task { @MainActor in
            let items = Self.items(for: identifiers)
            if !items.isEmpty { try? await searchableIndex.indexSearchableItems(items) }
            acknowledgementHandler()
        }
    }

    /// The items for these ids, from the store (iOS 27: what the search tool
    /// reads after a hit). Off when the Settings toggle is off, so nothing
    /// leaves the store while the user has the index drained.
    func searchableItems(forIdentifiers identifiers: [String]) async -> [CSSearchableItem] {
        await Self.items(for: identifiers)
    }

    @MainActor
    private static func items(for identifiers: [String]) -> [CSSearchableItem] {
        guard let model = AppModel.current, model.siriIndexEnabled else { return [] }
        return identifiers.compactMap { id in
            guard let row = try? model.engine.threadRow(id: id),
                  !row.labels.contains("TRASH"), !row.labels.contains("SPAM") else { return nil }
            return SpotlightIndexer.entity(for: row, in: model).searchableItem
        }
    }
}
