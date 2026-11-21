// A triage run on the Lock Screen and in the Dynamic Island: the phase,
// how many were scanned / picked / proposed / applied, the email being
// looked at, and Stop. The app updates it on every phase change
// (TriageLiveActivityController); Stop runs in the app's process.
//
// In the app's look (docs/specs/marker-look.md): the sparkle is the AI's
// pink ink, the phase and the tally are in the mono, Stop is an outlined
// capsule, and a finished run is the mint of done. The Lock Screen's
// platter is a dark tint in both appearances, so what stands on it is
// drawn with the palette's dark column.

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct TriageLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TriageActivityAttributes.self) { context in
            TriageLockScreenView(state: context.state)
                .environment(\.colorScheme, .dark)
                .activityBackgroundTint(WidgetPalette.platter)
                .activitySystemActionForegroundColor(WidgetPalette.onPlatter)
                .widgetURL(AppGroup.Link.folder("inbox"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isFinished ? "checkmark.seal" : "sparkles")
                        .font(.title2)
                        .foregroundStyle(context.state.isFinished ? WidgetPalette.done : WidgetPalette.pinkInk)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // A size under the other counts: the mono's letters
                    // are wider, and the tally has only the island's
                    // corner to stand in.
                    Text(TriageTally.short(context.state))
                        .font(Typeface.mono(.caption2, .medium)).foregroundStyle(WidgetPalette.textSecondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.phaseTitle + (context.state.isDryRun ? " · dry run" : ""))
                            .font(Typeface.sans(.headline, .semibold))
                            .foregroundStyle(WidgetPalette.textPrimary)
                            .lineLimit(1)
                        if let s = context.state.currentSubject {
                            Text(s).font(Typeface.sans(.subheadline)).foregroundStyle(WidgetPalette.textSecondary).lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !context.state.isFinished { StopButton() }
                }
            } compactLeading: {
                Image(systemName: "sparkles").foregroundStyle(WidgetPalette.pinkInk)
            } compactTrailing: {
                Text(context.state.isFinished ? "Done" : "\(context.state.proposed)")
                    .font(Typeface.mono(.caption, .medium))
            } minimal: {
                Image(systemName: "sparkles").foregroundStyle(WidgetPalette.pinkInk)
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
                // The platter is not the paper (the wallpaper is behind
                // it), so the title is ink here, not the light grey a
                // title has in the app.
                WidgetTitle(text: state.isDryRun ? "Triage · dry run" : "Triage", systemImage: "sparkles",
                            glyph: WidgetPalette.pinkInk, tint: WidgetPalette.textPrimary)
                Spacer()
                Text(state.phaseTitle)
                    .font(Typeface.mono(size: 11.5, relativeTo: .caption))
                    .foregroundStyle(WidgetPalette.textSecondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(TriageTally.long(state))
                    .font(Typeface.mono(.footnote, .medium))
                    .foregroundStyle(WidgetPalette.textPrimary)
                if let s = state.currentSubject, !state.isFinished {
                    Text(s).font(Typeface.sans(.subheadline)).lineLimit(1).foregroundStyle(WidgetPalette.textSecondary)
                }
            }
            if !state.isFinished { StopButton() }
        }
        .padding()
    }
}

/// Stop: an outlined capsule, as every button that is not a screen's one
/// ink action.
private struct StopButton: View {
    var body: some View {
        HStack {
            Button(intent: WidgetCancelTriageIntent()) {
                Label("Stop", systemImage: "stop.fill").modifier(WidgetCapsule(height: 30))
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }
}
