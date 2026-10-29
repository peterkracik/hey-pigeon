// The Live Activity of a triage run ("Hey Siri, triage my inbox"): the
// phase, the running tally and a Stop button, on the Lock Screen and in
// the Dynamic Island while the intent works past Siri's patience. Static:
// nothing. Dynamic: everything the run reports as it goes.

import ActivityKit
import Foundation

struct TriageActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// TriagePhase.rawValue — the extension has no app types.
        let phase: String
        let phaseTitle: String
        let scanned: Int
        let candidates: Int
        let proposed: Int
        let applied: Int
        let currentSubject: String?
        let isDryRun: Bool
        let isFinished: Bool
    }
}
