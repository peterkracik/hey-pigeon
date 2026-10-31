// The Live Activity for reminders that have come due: one activity for all
// of them, the first one's thread on it. Static: nothing (the set changes).
// Dynamic: how many are due, and the first's sender, subject and thread id
// (what the Done and Snooze buttons act on, what a tap opens).

#if os(iOS)
import ActivityKit
import Foundation

struct ReminderActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let dueCount: Int
        let threadId: String
        let from: String
        let subject: String
        let dueAt: Date
        let isFollowUp: Bool
    }
}
#else
// The macOS SDK ships ActivityKit with every type marked unavailable, so
// this is an os check, not canImport: nothing uses these on the Mac.
#endif
