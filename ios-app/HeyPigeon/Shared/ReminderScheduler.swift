// Local notifications for "remind me" — no server, works offline. The
// pending set is replaced wholesale with the next 7 days of reminders
// whenever one is set on this phone and after every sync, so a reminder
// moved or cleared on another device disappears here too.

import AppIntents
import Foundation
import UserNotifications

enum ReminderScheduler {
    /// Request identifier prefix. AppDelegate uses it to tell a reminder
    /// (shown in front too) from a new-mail banner (silent in front).
    static let prefix = "reminder."
    private static let horizon: TimeInterval = 7 * 86_400

    static func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// `unread` is the unified unread inbox count right now. Each reminder
    /// carries a badge of that plus every reminder due by its time, so the
    /// icon badge keeps pace with reminders firing while the app is asleep;
    /// NewMailNotifier.refreshBadge puts the exact number back on the next
    /// sync.
    static func reschedule(_ threads: [ThreadRow], unread: Int) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })

        let now = Date()
        // Reminders already due count toward every later badge.
        var dueByThen = threads.filter { t in t.scheduledAt.map { $0 <= now } ?? false }.count
        let upcoming = threads
            .compactMap { t in t.scheduledAt.map { (t, $0) } }
            .filter { $0.1 > now && $0.1 < now + horizon }
            .sorted { $0.1 < $1.1 }
        for (t, at) in upcoming {
            dueByThen += 1
            let content = UNMutableNotificationContent()
            content.title = t.isFollowUp ? "No reply yet" : "Reminder"
            content.subtitle = t.fromSummary
            content.body = t.subject
            content.sound = .default
            content.badge = NSNumber(value: unread + dueByThen)
            content.threadIdentifier = t.accountId
            content.userInfo = ["threadId": t.id]
            // iOS 27: the notification names its thread entity, so "remind
            // me about that notification tomorrow" and "open it" resolve.
            content.appEntityIdentifiers = [MailThreadEntity.identifier(t.id)]
            // Seconds-precise. A calendar trigger rounded to the minute can
            // land in the past for a reminder due within the minute, and iOS
            // then never fires it.
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, at.timeIntervalSince(now)), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: prefix + t.id, content: content, trigger: trigger))
        }
    }
}
