// Local notifications for "remind me" — no server, works offline. Every sync
// replaces the whole pending set with the next 7 days of reminders, so a
// reminder moved or cleared on another device disappears here too.

import Foundation
import UserNotifications

enum ReminderScheduler {
    private static let prefix = "reminder."

    static func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func reschedule(_ threads: [ThreadRow]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })

        let horizon = Date().addingTimeInterval(7 * 86_400)
        for t in threads {
            guard let at = t.scheduledAt, at > Date(), at < horizon else { continue }
            let content = UNMutableNotificationContent()
            content.title = t.isFollowUp ? "No reply yet" : "Reminder"
            content.subtitle = t.fromSummary
            content.body = t.subject
            content.sound = .default
            content.threadIdentifier = t.accountId
            content.userInfo = ["threadId": t.id]
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at),
                repeats: false
            )
            try? await center.add(UNNotificationRequest(identifier: prefix + t.id, content: content, trigger: trigger))
        }
    }
}
