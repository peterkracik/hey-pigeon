// UIKit's doorway for the two things SwiftUI's App cannot receive on its
// own: APNs device tokens and silent pushes. Everything else stays in
// HeyPigeonApp / AppModel.
//
// The push itself carries no mail (relay/README.md): `{aps:
// {content-available: 1}, email, historyId}`. We wake, run one delta sync
// for that account through the Rust core, and compose any notification
// from what the sync brought in — the same path the desktop takes.

import UIKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // MARK: APNs registration

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await AppModel.current?.push.tokenReceived(hex) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppModel.current?.push.registrationFailed(error.localizedDescription)
    }

    // MARK: Silent push → delta sync → local notification

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let model = AppModel.current else {
            completionHandler(.noData)
            return
        }
        let email = userInfo["email"] as? String
        Task {
            let result = await NewMailNotifier.handle(email: email, model: model)
            completionHandler(result)
        }
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
            AppModel.current?.openThread(id: threadId)
        }
    }

    /// Nothing is shown while the app is in front: the list is live, and the
    /// badge follows the sync. (Same as before this delegate existed.)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }
}
