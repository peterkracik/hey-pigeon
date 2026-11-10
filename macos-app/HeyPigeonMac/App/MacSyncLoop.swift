// The Mac's sync cadence. The engine never spawns its own loop (the shell
// owns cadence, docs/ios.md), and a Mac app is never suspended, so this is
// a plain timer: a sync round every 30 seconds while the app runs — the
// desktop Tauri app's interval — on top of the sync every activation and
// the first one at launch (HeyPigeonMacApp). The round's diff is also where
// new-mail banners come from: no relay is needed when the app is awake to
// notice the change itself, and Settings › Notifications has the switch.
// The timer slows down in Low Power Mode and stands still without a
// network path (Connectivity), which also restarts it the moment the path
// is back.

import Foundation

@MainActor
final class MacSyncLoop {
    static let shared = MacSyncLoop()
    static let interval: Duration = .seconds(30)
    /// In Low Power Mode the Mac asks a quarter as often.
    static let lowPowerInterval: Duration = .seconds(120)
    /// Settings › Notifications › "New mail"; on unless turned off.
    static let notificationsKey = "newMailNotifications"

    private var task: Task<Void, Never>?

    /// The pause before the next round.
    static var currentInterval: Duration {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? lowPowerInterval : interval
    }

    func start(_ model: AppModel) {
        task?.cancel()
        // The network came back: do not wait for the next tick.
        Connectivity.shared.onReconnect = { [weak model] in
            guard let model else { return }
            Task { await Self.syncAndNotify(model) }
        }
        task = Task { [weak model] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.currentInterval)
                guard !Task.isCancelled, let model else { return }
                // No path, no round: it could only fail.
                guard Connectivity.shared.isOnline else { continue }
                await Self.syncAndNotify(model)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// One round, then a banner for every unread inbox thread that was not
    /// there before — only while the app is not in front (the list is live
    /// then) and only when the setting is on. The badge follows the sync
    /// itself (AppModel.sync → NewMailNotifier.refreshBadge). The round is
    /// a quiet one: when it brings nothing, the list, the reminders and
    /// the index are left alone. The before and after lists are read off
    /// the main actor (they were two reads of 200 rows on it per round).
    static func syncAndNotify(_ model: AppModel) async {
        var before: Set<String> = []
        if notificationsEnabled { before = Set(await unreadInbox(model).map(\.id)) }
        await model.sync(quiet: true)
        guard notificationsEnabled, !AppLifecycle.isActive else { return }
        let fresh = await unreadInbox(model).filter { !before.contains($0.id) }
        for row in fresh {
            await NewMailNotifier.post(row)
        }
    }

    /// The unread inbox threads across accounts, newest first.
    private static func unreadInbox(_ model: AppModel) async -> [ThreadRow] {
        let rows = try? await model.engine.readInBackground { store in
            try store.threads(in: .inbox, accountId: nil, before: nil, limit: 200).filter { !$0.isRead }
        }
        return rows ?? []
    }

    static var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: notificationsKey) as? Bool ?? true
    }
}
