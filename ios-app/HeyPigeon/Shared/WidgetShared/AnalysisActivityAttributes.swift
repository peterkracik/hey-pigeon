// The Live Activity of a large analysis pass (auto-triage classifying the
// mailbox, e.g. after "Reanalyze all emails"): how far it is, on the Lock
// Screen and in the Dynamic Island. Static: nothing. Dynamic: the count.

#if os(iOS)
import ActivityKit
import Foundation

struct AnalysisActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let done: Int
        let total: Int
        /// The app left the foreground and iOS stopped the work; it goes
        /// on when the app is opened again.
        let isPaused: Bool
        let isFinished: Bool

        var fraction: Double { total > 0 ? min(Double(done) / Double(total), 1) : 0 }
        /// Whole percent, what the compact island shows and what an update
        /// must move to be worth sending.
        var percent: Int { Int((fraction * 100).rounded(.down)) }
    }
}
#else
// The macOS SDK ships ActivityKit with every type marked unavailable, so
// this is an os check, not canImport: nothing uses these on the Mac.
#endif
