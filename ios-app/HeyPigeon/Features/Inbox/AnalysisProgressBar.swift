// The analysis pass on screen: a slim glass bar over the inbox while
// auto-triage classifies a batch worth watching ("Reanalyze all emails",
// a first pass over the mailbox), and the same row in Settings › Triage.
// Small passes — a couple of new emails — finish before a bar could be
// read and show nothing (AnalysisProgress.visibleFrom). Off screen, the
// Live Activity carries it (AnalysisLiveActivityController).

import SwiftUI

/// "Analyzing emails · 40 of 120" over a determinate bar.
struct AnalysisProgressRow: View {
    let progress: AnalysisProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                Text("Analyzing emails").font(.footnote.weight(.semibold))
                Spacer(minLength: 8)
                Text(Self.count(progress))
                    .font(.footnote).monospacedDigit().foregroundStyle(Theme.textTertiary)
                    .contentTransition(.numericText())
            }
            ProgressView(value: progress.fraction)
                .tint(Theme.accent)
                .animation(.easeOut(duration: 0.3), value: progress.done)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Analyzing emails")
        .accessibilityValue(Self.count(progress))
    }

    /// "40 of 120"; the pieces the Live Activity shows too.
    static func count(_ p: AnalysisProgress) -> String { "\(p.done) of \(p.total)" }
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
