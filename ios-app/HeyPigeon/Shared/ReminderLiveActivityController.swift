// Due reminders used to sit on the Lock Screen as a Live Activity for as long
// as they were due, which got in the way. They are now a banner at the due
// time (ReminderScheduler) and the Lock Screen widgets. What is left here is
// the cleanup: a build that still had the activity running leaves it behind
// with nothing to draw it, so it is ended on the next launch.

#if os(iOS)
import ActivityKit
import Foundation

@MainActor
enum ReminderLiveActivityController {
    /// End every reminder activity a previous version started.
    static func endLeftovers() async {
        for a in Activity<ReminderActivityAttributes>.activities {
            await a.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#else
// No Live Activities on the Mac. Same call, nothing to do.
import Foundation

@MainActor
enum ReminderLiveActivityController {
    static func endLeftovers() async {}
}
#endif
