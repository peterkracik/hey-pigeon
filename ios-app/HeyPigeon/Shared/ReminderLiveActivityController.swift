// One Live Activity for the reminders that have come due: started while the
// app is in front (iOS only lets the app itself start one from the
// foreground), updated as the set changes, ended when it empties. The Done
// and Snooze buttons on it run WidgetMarkDoneIntent / WidgetSnoozeIntent
// in this process (LiveActivityIntent), which call back into AppModel.

import ActivityKit
import Foundation

@MainActor
enum ReminderLiveActivityController {
    static func sync(_ model: AppModel, now: Date = Date()) async {
        let due = AppModel.due(model.scheduledThreads(accountId: nil), now: now)
            .sorted { ($0.scheduledAt ?? now) < ($1.scheduledAt ?? now) }
        let existing = Activity<ReminderActivityAttributes>.activities
        guard let first = due.first, let at = first.scheduledAt else {
            for a in existing { await a.end(nil, dismissalPolicy: .immediate) }
            return
        }
        let state = ReminderActivityAttributes.ContentState(
            dueCount: due.count, threadId: first.id, from: first.fromSummary,
            subject: first.subject.isEmpty ? "(no subject)" : first.subject, dueAt: at, isFollowUp: first.isFollowUp
        )
        let content = ActivityContent(state: state, staleDate: now.addingTimeInterval(8 * 3600), relevanceScore: 100)
        if let activity = existing.first {
            if activity.content.state != state { await activity.update(content) }
            // Only ever one: a second would mean a crash left one behind.
            for extra in existing.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        _ = try? Activity.request(attributes: ReminderActivityAttributes(), content: content, pushType: nil)
    }
}
