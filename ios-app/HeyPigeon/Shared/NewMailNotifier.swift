// A silent push arrived: sync that account, tell the user about threads
// that are new since the last look, keep the badge honest (unread inbox +
// reminders that came due). Text is composed here from the local database —
// the relay never had it.

import Foundation
import UIKit
import UserNotifications

enum NewMailNotifier {
    private static let prefix = "newmail."
    /// iOS gives a background fetch about 30 s; leave headroom for the
    /// completion handler.
    private static let budget: Duration = .seconds(25)

    @MainActor
    static func handle(email: String?, model: AppModel) async -> UIBackgroundFetchResult {
        let accountId = email.flatMap { e in model.accounts.first { $0.id == e || $0.email == e }?.id }
        let before = Set(unreadInbox(model, accountId: accountId).map(\.id))

        let engine = model.engine
        let changed: Bool
        do {
            changed = try await withTimeout(budget) {
                if let accountId {
                    try await engine.syncNow(accountId: accountId)
                } else {
                    try await engine.syncAll()
                }
            }
        } catch {
            await refreshBadge(model)
            return .failed
        }

        let fresh = unreadInbox(model, accountId: accountId).filter { !before.contains($0.id) }
        // In front, the list is live and a banner would be noise.
        if UIApplication.shared.applicationState != .active {
            for row in fresh {
                await post(row)
            }
        }
        model.reloadAccounts()
        model.reload()
        await refreshBadge(model)
        return changed || !fresh.isEmpty ? .newData : .noData
    }

    /// Badge = unread in the unified inbox + reminders that came due, across
    /// every account. Also called after every sync and reload, so it is
    /// right with the relay off too.
    @MainActor
    static func refreshBadge(_ model: AppModel) async {
        let unread = (try? model.engine.unreadCounts(accountId: nil))?["inbox"] ?? 0
        let due = AppModel.due(model.scheduledThreads(accountId: nil)).count
        try? await UNUserNotificationCenter.current().setBadgeCount(unread + due)
    }

    @MainActor
    private static func unreadInbox(_ model: AppModel, accountId: String?) -> [ThreadRow] {
        ((try? model.engine.threads(in: .inbox, accountId: accountId, before: nil, limit: 200)) ?? [])
            .filter { !$0.isRead }
    }

    private static func post(_ row: ThreadRow) async {
        let content = UNMutableNotificationContent()
        content.title = row.fromSummary
        content.body = row.subject.isEmpty ? "(no subject)" : row.subject
        content.sound = .default
        content.threadIdentifier = row.accountId
        content.userInfo = ["threadId": row.id, "accountId": row.accountId]
        // Delivered now; the identifier dedupes a second push for the same thread.
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: prefix + row.id, content: content, trigger: nil)
        )
    }

    private struct Timeout: Error {}

    private static func withTimeout<T: Sendable>(
        _ limit: Duration,
        _ work: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw Timeout()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}
