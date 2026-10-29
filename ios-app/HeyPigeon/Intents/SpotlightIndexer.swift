// The Spotlight index is how the new Siri's personal context learns about
// the inbox ("did Anna reply about the invoice?") and how Spotlight finds a
// thread. Rebuilt after every sync, like the reminder notifications: the
// newest 500 threads of each account, subject · sender · one preview line,
// never a body. Trash and spam are dropped. Settings › Siri & Search turns
// it off and drains it.

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
                    keep.append(MailThreadEntity(row, account: account))
                }
            }
        }
        let index = CSSearchableIndex.default()
        if !keep.isEmpty { try? await index.indexAppEntities(keep) }
        if !drop.isEmpty { try? await index.deleteAppEntities(identifiedBy: drop, ofType: MailThreadEntity.self) }
    }

    /// Settings turned the index off, or an account was removed: forget it
    /// all; the next refresh (if on) rebuilds from the store.
    static func clear() async {
        try? await CSSearchableIndex.default().deleteAllSearchableItems()
    }
}
