// The analysis pass on screen: a slim glass bar over the inbox while
// auto-triage classifies a batch worth watching ("Reanalyze all emails",
// a first pass over the mailbox), and the same row in Settings › Triage.
// Small passes — a couple of new emails — finish before a bar could be
// read and show nothing (AnalysisProgress.visibleFrom). Off screen, the
// Live Activity carries it (AnalysisLiveActivityController).

import SwiftUI

/// "Analyzing emails · 40 of 120" over a determinate bar: the AI's sparkle
/// in its pink, the words in ink, the count in the mono, and the bar an
/// ink fill on a hairline-grey track.
struct AnalysisProgressRow: View {
    let progress: AnalysisProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(Theme.glyph(.secondary, .semibold)).foregroundStyle(Theme.pinkInk)
                Text("Analyzing emails").font(Theme.text(.secondary, .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Text(Self.count(progress))
                    .font(Theme.meta).foregroundStyle(Theme.textTertiary)
                    .contentTransition(.numericText())
            }
            AnalysisTrack(fraction: progress.fraction)
                .animation(Motion.animation(.easeOut(duration: 0.3)), value: progress.done)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Analyzing emails")
        .accessibilityValue(Self.count(progress))
    }

    /// "40 of 120"; the pieces the Live Activity shows too.
    static func count(_ p: AnalysisProgress) -> String { "\(p.done) of \(p.total)" }
}

/// The bar itself, drawn flat: an ink fill growing along a track in the
/// grey of the rules, square at both ends as they are. The system's own
/// bar comes with a track and round caps of its own, in neither token.
private struct AnalysisTrack: View {
    /// How much is done, 0…1.
    let fraction: Double

    var body: some View {
        Rectangle().fill(Theme.separator)
            .frame(height: 4)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.textPrimary)
                    .scaleEffect(x: CGFloat(fraction), y: 1, anchor: .leading)
            }
            // The row says the count itself (its label and value).
            .accessibilityHidden(true)
    }
}

/// The inbox's floating bar, above the triage label pill.
struct AnalysisProgressBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.analysis.isVisible {
            AnalysisProgressRow(progress: model.analysis)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
