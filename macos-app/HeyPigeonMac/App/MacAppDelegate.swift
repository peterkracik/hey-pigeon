// AppKit's doorway for what SwiftUI's App cannot receive on its own: APNs
// device tokens and silent pushes (the optional relay, relay/README.md),
// notification taps, and the Dock menu. Everything else stays in
// HeyPigeonMacApp / AppModel. Same shape as the iPhone's AppDelegate.

import AppKit
import UserNotifications

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        // After the window is up: a copy run from the download cannot sign
        // in or update (InstallLocation.swift).
        Task { @MainActor in InstallLocation.warnIfTranslocated() }
    }

    /// Closing the last window does not quit a mail client: the menu bar
    /// extra, the timer sync and the banners keep going; the Dock icon or
    /// the extra bring the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: APNs registration

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await AppModel.current?.push.tokenReceived(hex) }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppModel.current?.push.registrationFailed(error.localizedDescription)
    }

    // MARK: Silent push → delta sync → local notification

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard let model = AppModel.current else { return }
        let email = userInfo["email"] as? String
        Task { _ = await NewMailNotifier.handle(email: email, model: model) }
    }

    // MARK: Dock menu

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let compose = NSMenuItem(title: "New Message", action: #selector(composeFromDock), keyEquivalent: "")
        compose.target = self
        menu.addItem(compose)
        let check = NSMenuItem(title: "Check for Mail", action: #selector(syncFromDock), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        return menu
    }

    @objc private func composeFromDock() {
        NSApp.activate()
        AppModel.current?.compose(SendDraft())
    }

    @objc private func syncFromDock() {
        guard let model = AppModel.current else { return }
        Task { await model.sync() }
    }

    // MARK: Notification taps → the thread
    //
    // UNUserNotificationCenterDelegate calls back off the main actor with
    // non-Sendable arguments, so these two stay nonisolated: pull out the
    // one String needed, answer the system, then hop to the model.

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let threadId = response.notification.request.content.userInfo["threadId"] as? String
        completionHandler()
        guard let threadId else { return }
        Task { @MainActor in
            NSApp.activate()
            AppModel.current?.openThread(id: threadId)
        }
    }

    /// A reminder shows in front too — the user asked to be interrupted at
    /// that time. New-mail banners stay silent while the app is in front:
    /// the list is live, and the badge follows the sync.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let isReminder = notification.request.identifier.hasPrefix(ReminderScheduler.prefix)
        completionHandler(isReminder ? [.banner, .list, .sound, .badge] : [])
    }
}
