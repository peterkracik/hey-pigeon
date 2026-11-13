// The attributes of the retired due-reminder Live Activity. Nothing starts
// one any more; the type stays so ReminderLiveActivityController can end one
// an older build left running. Delete both once that build is gone.

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
