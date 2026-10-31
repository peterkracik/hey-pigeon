// The Mac's sync cadence. The engine never spawns its own loop (the shell
// owns cadence, docs/ios.md), and a Mac app is never suspended, so this is
// a plain timer: a sync round every 30 seconds while the app runs — the
// desktop Tauri app's interval — on top of the sync every activation and
// the first one at launch (HeyPigeonMacApp). The round's diff is also where
// new-mail banners come from: no relay is needed when the app is awake to
// notice the change itself, and Settings › Notifications has the switch.

import Foundation

@MainActor
final class MacSyncLoop {
    static let shared = MacSyncLoop()
    static let interval: Duration = .seconds(30)
    /// Settings › Notifications › "New mail"; on unless turned off.
    static let notificationsKey = "newMailNotifications"

    private var task: Task<Void, Never>?

    func start(_ model: AppModel) {
        task?.cancel()
        task = Task { [weak model] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled, let model else { return }
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
    /// itself (AppModel.sync → NewMailNotifier.refreshBadge).
    static func syncAndNotify(_ model: AppModel) async {
        let before = Set(NewMailNotifier.unreadInbox(model, accountId: nil).map(\.id))
        await model.sync()
        guard notificationsEnabled, !AppLifecycle.isActive else { return }
        let fresh = NewMailNotifier.unreadInbox(model, accountId: nil).filter { !before.contains($0.id) }
        for row in fresh {
            await NewMailNotifier.post(row)
        }
    }

    static var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: notificationsKey) as? Bool ?? true
    }
}
