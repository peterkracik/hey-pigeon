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
        let now = Date()
        // Reminders already due count toward every later badge.
        var dueByThen = threads.filter { t in t.scheduledAt.map { $0 <= now } ?? false }.count
        let upcoming = threads
            .compactMap { t in t.scheduledAt.map { (t, $0) } }
            .filter { $0.1 > now && $0.1 < now + horizon }
            .sorted { $0.1 < $1.1 }
        // The same reminders with the same badges as last time: what is
        // pending is already right. Every sync used to take them all off
        // and add each one again.
        let plan = ["\(unread)|\(dueByThen)"] + upcoming.map { t, at in
            "\(t.id)|\(at.timeIntervalSince1970)|\(t.isFollowUp)|\(t.fromSummary)|\(t.subject)"
        }
        if await MainActor.run(body: { lastPlan == plan }) { return }
        // Two runs at once (a sync's and a reminder just set) interleave
        // their removes and adds: neither then knows what is pending, so
        // neither records its plan and the next run starts clean.
        await MainActor.run {
            running += 1
            if running > 1 { overlapped = true }
        }
        var scheduledAll = true
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
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
            // Mark Done · Remind Me in 1 Hour · Reply on the banner itself
            // (NewMailNotifier.registerActions).
            content.categoryIdentifier = NotificationActions.reminderCategory
            // iOS 27: the notification names its thread entity, so "remind
            // me about that notification tomorrow" and "open it" resolve.
            content.appEntityIdentifiers = [MailThreadEntity.identifier(t.id)]
            // Seconds-precise. A calendar trigger rounded to the minute can
            // land in the past for a reminder due within the minute, and iOS
            // then never fires it.
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, at.timeIntervalSince(now)), repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: prefix + t.id, content: content, trigger: trigger))
            } catch {
                scheduledAll = false
            }
        }
        // A plan that did not go in whole (no permission yet) is tried
        // again next time.
        let complete = scheduledAll
        await MainActor.run {
            lastPlan = complete && !overlapped ? plan : []
            running -= 1
            if running == 0 { overlapped = false }
        }
    }

    /// Runs in flight, and whether any two of them met.
    @MainActor private static var running = 0
    @MainActor private static var overlapped = false

    /// What `reschedule` last put in place, to tell when nothing moved.
    @MainActor private static var lastPlan: [String] = []
}
