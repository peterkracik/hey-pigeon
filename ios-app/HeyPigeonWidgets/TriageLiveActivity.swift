// A triage run on the Lock Screen and in the Dynamic Island: the phase,
// how many were scanned / picked / proposed / applied, the email being
// looked at, and Stop. The app updates it on every phase change
// (TriageLiveActivityController); Stop runs in the app's process.

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct TriageLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TriageActivityAttributes.self) { context in
            TriageLockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(AppGroup.Link.folder("inbox"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isFinished ? "checkmark.seal" : "sparkles")
                        .font(.title2).foregroundStyle(WidgetPalette.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(TriageTally.short(context.state)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.phaseTitle + (context.state.isDryRun ? " · dry run" : "")).font(.headline).lineLimit(1)
                        if let s = context.state.currentSubject { Text(s).font(.subheadline).lineLimit(1) }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !context.state.isFinished { StopButton() }
                }
            } compactLeading: {
                Image(systemName: "sparkles").foregroundStyle(WidgetPalette.accent)
            } compactTrailing: {
                Text(context.state.isFinished ? "Done" : "\(context.state.proposed)")
                    .font(.caption.weight(.semibold)).monospacedDigit()
            } minimal: {
                Image(systemName: "sparkles").foregroundStyle(WidgetPalette.accent)
            }
            .keylineTint(WidgetPalette.accent)
        }
    }
}

enum TriageTally {
    static func short(_ s: TriageActivityAttributes.ContentState) -> String {
        s.isFinished && s.applied > 0 ? "\(s.applied) applied" : "\(s.scanned) scanned · \(s.proposed) proposed"
    }

    static func long(_ s: TriageActivityAttributes.ContentState) -> String {
        var parts = ["\(s.scanned) scanned"]
        if s.candidates > 0 { parts.append("\(s.candidates) picked") }
        if s.proposed > 0 { parts.append("\(s.proposed) proposed") }
        if s.applied > 0 { parts.append("\(s.applied) applied") }
        return parts.joined(separator: " · ")
    }
}

private struct TriageLockScreenView: View {
    let state: TriageActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(state.isDryRun ? "Triage · dry run" : "Triage", systemImage: "sparkles")
                    .font(.caption.weight(.semibold)).foregroundStyle(WidgetPalette.accent)
                Spacer()
                Text(state.phaseTitle).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(TriageTally.long(state)).font(.headline).monospacedDigit()
                if let s = state.currentSubject, !state.isFinished {
                    Text(s).font(.subheadline).lineLimit(1).foregroundStyle(.secondary)
                }
            }
            if !state.isFinished { StopButton() }
        }
        .padding()
    }
}

private struct StopButton: View {
    var body: some View {
        HStack {
            Button(intent: WidgetCancelTriageIntent()) {
                Label("Stop", systemImage: "stop.fill").font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            Spacer()
        }
    }
}
