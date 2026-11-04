// The app's side of the analysis Live Activity. Started when a pass worth
// following begins while the app is in front (only then can one start),
// updated as emails are classified — at most once per percent, since the
// engine reports every email — and ended with a "Done" a little after the
// pass finishes. Updates are coalesced through one worker so they reach
// ActivityKit in order and only the newest is sent.

#if os(iOS)
import ActivityKit
import Foundation

@MainActor
enum AnalysisLiveActivityController {
    typealias State = AnalysisActivityAttributes.ContentState

    private static var latest: AnalysisProgress?
    private static var worker: Task<Void, Never>?

    /// The newest progress; cheap to call per email.
    static func submit(_ p: AnalysisProgress) {
        latest = p
        guard worker == nil else { return }
        worker = Task { @MainActor in
            while let next = latest {
                latest = nil
                await apply(next)
            }
            worker = nil
        }
    }

    private static func apply(_ p: AnalysisProgress) async {
        let existing = Activity<AnalysisActivityAttributes>.activities
        guard p.isActive else {
            // The pass is over: the last count becomes "Done", readable for
            // a moment on the Lock Screen.
            for a in existing {
                let total = a.content.state.total
                let done = State(done: total, total: total, isPaused: false, isFinished: true)
                await a.end(ActivityContent(state: done, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(30)))
            }
            return
        }
        let state = State(done: p.done, total: p.total, isPaused: !p.isRunning && !AppLifecycle.isActive, isFinished: false)
        // Stale a while after the last word: iOS suspended the app mid-round,
        // and the activity then reads "Paused" instead of a frozen count.
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(2 * 60), relevanceScore: 50)
        if let activity = existing.first {
            for extra in existing.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
            let shown = activity.content.state
            guard state.percent != shown.percent || state.isPaused != shown.isPaused || state.total != shown.total else { return }
            await activity.update(content)
            return
        }
        guard p.total >= AnalysisProgress.liveActivityFrom, p.remaining > 0, AppLifecycle.isActive,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        _ = try? Activity.request(attributes: AnalysisActivityAttributes(), content: content, pushType: nil)
    }
}
#else
// No Live Activities on the Mac: the inbox and Settings show the progress.
import Foundation

@MainActor
enum AnalysisLiveActivityController {
    static func submit(_ p: AnalysisProgress) {}
}
#endif
