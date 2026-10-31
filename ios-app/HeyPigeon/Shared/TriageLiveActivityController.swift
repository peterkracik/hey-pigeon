// The app's side of the triage Live Activity: started when a run starts
// (the app is in front or launched by the intent — both may start one),
// updated on every phase change, ended a moment after the run finishes so
// the tally stays readable. The Stop button runs WidgetCancelTriageIntent
// in this process, which reaches TriageAgent.current.

#if os(iOS)
import ActivityKit
import Foundation

@MainActor
enum TriageLiveActivityController {
    static func update(_ agent: TriageAgent) async {
        let state = TriageActivityAttributes.ContentState(
            phase: agent.phase.rawValue, phaseTitle: agent.phase.title,
            scanned: agent.scanned, candidates: agent.candidates, proposed: agent.plan.proposals.count,
            applied: agent.applied, currentSubject: agent.currentSubject, isDryRun: agent.dryRun,
            isFinished: [.done, .cancelled, .failed].contains(agent.phase)
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(10 * 60), relevanceScore: 90)
        let existing = Activity<TriageActivityAttributes>.activities
        if let activity = existing.first {
            if state.isFinished {
                await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(60)))
            } else {
                await activity.update(content)
            }
            for extra in existing.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
            return
        }
        guard !state.isFinished, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        _ = try? Activity.request(attributes: TriageActivityAttributes(), content: content, pushType: nil)
    }

    static func endAll() async {
        for a in Activity<TriageActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
    }
}
#else
// No Live Activities on the Mac: Settings › Triage shows the run's phase
// and tally live instead. Same calls, nothing to do.
import Foundation

@MainActor
enum TriageLiveActivityController {
    static func update(_ agent: TriageAgent) async {}
    static func endAll() async {}
}
#endif
