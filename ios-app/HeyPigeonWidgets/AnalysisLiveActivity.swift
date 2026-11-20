// An analysis pass on the Lock Screen and in the Dynamic Island: "Analyzing
// emails", how many of how many, a bar (a ring when compact), and "Done"
// at the end. The app updates it as emails are classified
// (AnalysisLiveActivityController); a tap opens the inbox.
//
// In the app's look (docs/specs/marker-look.md): the sparkle is the AI's
// pink ink, the bar and the ring are the one pink fill, the counts are in
// the mono, and a finished pass is the mint of done — pink never says
// done. The Lock Screen's platter is a dark tint in both appearances, so
// what stands on it is drawn with the palette's dark column.

import ActivityKit
import SwiftUI
import WidgetKit

struct AnalysisLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AnalysisActivityAttributes.self) { context in
            AnalysisLockScreenView(state: context.state, isStale: context.isStale)
                .environment(\.colorScheme, .dark)
                .activityBackgroundTint(WidgetPalette.platter)
                .activitySystemActionForegroundColor(WidgetPalette.onPlatter)
                .widgetURL(AppGroup.Link.folder("inbox"))
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: s.isFinished ? "checkmark.seal" : "sparkles")
                        .font(.title2)
                        .foregroundStyle(s.isFinished ? WidgetPalette.done : WidgetPalette.pinkInk)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(s.isFinished ? "Done" : "\(s.percent)%")
                        .font(Typeface.mono(.caption, .medium)).foregroundStyle(WidgetPalette.textSecondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(AnalysisCopy.title(s, isStale: context.isStale))
                        .font(Typeface.sans(.headline, .semibold))
                        .foregroundStyle(WidgetPalette.textPrimary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: s.fraction).tint(WidgetPalette.accent)
                        Text(AnalysisCopy.detail(s, isStale: context.isStale))
                            .font(AnalysisCopy.detailFont(s, isStale: context.isStale, count: .caption, sentence: .caption))
                            .foregroundStyle(WidgetPalette.textSecondary)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: "sparkles").foregroundStyle(WidgetPalette.pinkInk)
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

    /// The face of the detail line. While the pass runs the line is the
    /// count alone ("6 of 8"), which is data and set in the mono; paused
    /// or finished it is a sentence, set in the interface face — in the
    /// mono's wide letters the paused one did not fit its one line.
    static func detailFont(_ s: AnalysisActivityAttributes.ContentState, isStale: Bool,
                           count: Font.TextStyle, sentence: Font.TextStyle) -> Font {
        s.isFinished || s.isPaused || isStale ? Typeface.sans(sentence) : Typeface.mono(count)
    }
}

/// The compact and minimal island: a ring filling up, a check when done.
private struct AnalysisRing: View {
    let state: AnalysisActivityAttributes.ContentState

    var body: some View {
        if state.isFinished {
            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(WidgetPalette.done)
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
                // The platter is not the paper (the wallpaper is behind
                // it), so the title is ink here, not the light grey a
                // title has in the app.
                WidgetTitle(text: AnalysisCopy.title(state, isStale: isStale),
                            systemImage: state.isFinished ? "checkmark.seal" : "sparkles",
                            glyph: state.isFinished ? WidgetPalette.done : WidgetPalette.pinkInk,
                            tint: WidgetPalette.textPrimary)
                Spacer()
                if !state.isFinished {
                    Text("\(state.percent)%")
                        .font(Typeface.mono(size: 11.5, relativeTo: .caption))
                        .foregroundStyle(WidgetPalette.textSecondary)
                }
            }
            ProgressView(value: state.fraction).tint(WidgetPalette.accent)
            Text(AnalysisCopy.detail(state, isStale: isStale))
                .font(AnalysisCopy.detailFont(state, isStale: isStale, count: .footnote, sentence: .subheadline))
                .foregroundStyle(WidgetPalette.textSecondary)
                .lineLimit(1)
        }
        .padding()
    }
}
