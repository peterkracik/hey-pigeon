// An analysis pass on the Lock Screen and in the Dynamic Island: "Analyzing
// emails", how many of how many, a bar (a ring when compact), and "Done"
// at the end. The app updates it as emails are classified
// (AnalysisLiveActivityController); a tap opens the inbox.

import ActivityKit
import SwiftUI
import WidgetKit

struct AnalysisLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AnalysisActivityAttributes.self) { context in
            AnalysisLockScreenView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(AppGroup.Link.folder("inbox"))
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: s.isFinished ? "checkmark.seal" : "sparkles")
                        .font(.title2).foregroundStyle(WidgetPalette.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(s.isFinished ? "Done" : "\(s.percent)%")
                        .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(AnalysisCopy.title(s, isStale: context.isStale)).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: s.fraction).tint(WidgetPalette.accent)
                        Text(AnalysisCopy.detail(s, isStale: context.isStale))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: "sparkles").foregroundStyle(WidgetPalette.accent)
            } compactTrailing: {
                AnalysisRing(state: s)
            } minimal: {
                AnalysisRing(state: s)
            }
            .keylineTint(WidgetPalette.accent)
        }
    }
}

/// The words, shared by the island and the Lock Screen.
enum AnalysisCopy {
    static func title(_ s: AnalysisActivityAttributes.ContentState, isStale: Bool) -> String {
        if s.isFinished { return "Emails analyzed" }
        return s.isPaused || isStale ? "Analysis paused" : "Analyzing emails"
    }

    static func detail(_ s: AnalysisActivityAttributes.ContentState, isStale: Bool) -> String {
        if s.isFinished { return "\(s.total) emails sorted and prioritized" }
        if s.isPaused || isStale { return "\(s.done) of \(s.total) · continues when you open Hey Pigeon" }
        return "\(s.done) of \(s.total)"
    }
}

/// The compact and minimal island: a ring filling up, a check when done.
private struct AnalysisRing: View {
    let state: AnalysisActivityAttributes.ContentState

    var body: some View {
        if state.isFinished {
            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(WidgetPalette.accent)
        } else {
            ProgressView(value: state.fraction)
                .progressViewStyle(.circular)
                .tint(WidgetPalette.accent)
                .frame(width: 18, height: 18)
        }
    }
}

private struct AnalysisLockScreenView: View {
    let state: AnalysisActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(AnalysisCopy.title(state, isStale: isStale), systemImage: state.isFinished ? "checkmark.seal" : "sparkles")
                    .font(.caption.weight(.semibold)).foregroundStyle(WidgetPalette.accent)
                Spacer()
                if !state.isFinished {
                    Text("\(state.percent)%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            ProgressView(value: state.fraction).tint(WidgetPalette.accent)
            Text(AnalysisCopy.detail(state, isStale: isStale))
                .font(.subheadline).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
        }
        .padding()
    }
}
