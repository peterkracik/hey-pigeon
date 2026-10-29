// The app's side of the widgets: after every reload, write what they show
// into the App Group and ask WidgetKit to redraw — only when something
// changed, so a reload that moved nothing costs nothing.

import Foundation
import WidgetKit

@MainActor
enum WidgetSnapshotWriter {
    private static var last: WidgetSnapshot?

    static func build(_ model: AppModel, now: Date = Date()) -> WidgetSnapshot {
        let counts = (try? model.engine.unreadCounts(accountId: nil)) ?? [:]
        let accounts = model.accounts.map { a in
            WidgetSnapshot.AccountSummary(
                id: a.id, name: a.displayName, color: a.color.rawValue,
                unread: (try? model.engine.unreadCounts(accountId: a.id))?["inbox"] ?? 0
            )
        }
        let colors = Dictionary(uniqueKeysWithValues: model.accounts.map { ($0.id, $0.color.rawValue) })
        func row(_ t: ThreadRow, at: Date) -> WidgetSnapshot.Row {
            WidgetSnapshot.Row(id: t.id, from: t.fromSummary, subject: t.subject, snippet: t.snippet,
                               accountColor: colors[t.accountId] ?? "sky", at: at, isFollowUp: t.isFollowUp, isUnread: !t.isRead)
        }
        let scheduled = model.scheduledAcrossAccounts
            .filter { $0.scheduledAt != nil }
            .sorted { ($0.scheduledAt ?? now) < ($1.scheduledAt ?? now) }
        let due = scheduled.filter { ($0.scheduledAt ?? now) <= now }
        let upcoming = scheduled.filter { ($0.scheduledAt ?? now) > now }
        let needReply = (try? model.engine.threads(in: .needReply, accountId: nil, before: nil, limit: 500)) ?? []
        return WidgetSnapshot(
            updatedAt: now,
            lastSyncAt: model.lastSyncAt,
            unreadTotal: counts["inbox"] ?? 0,
            accounts: accounts,
            due: due.prefix(WidgetSnapshot.maxRows).map { row($0, at: $0.scheduledAt ?? now) },
            upcoming: upcoming.prefix(WidgetSnapshot.maxRows).map { row($0, at: $0.scheduledAt ?? now) },
            needReply: needReply.prefix(WidgetSnapshot.maxRows).map { row($0, at: $0.lastMessageAt) },
            needReplyTotal: needReply.count
        )
    }

    /// Write and redraw when the content changed (the timestamp alone does
    /// not count).
    static func publish(_ model: AppModel) {
        let fresh = build(model)
        if let last, same(last, fresh) { return }
        guard AppGroup.write(fresh, to: WidgetSnapshot.file) else { return }
        last = fresh
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func same(_ a: WidgetSnapshot, _ b: WidgetSnapshot) -> Bool {
        a.unreadTotal == b.unreadTotal && a.accounts == b.accounts && a.due == b.due
            && a.upcoming == b.upcoming && a.needReply == b.needReply && a.needReplyTotal == b.needReplyTotal
    }
}
