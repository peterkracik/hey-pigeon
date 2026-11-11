// The AI summary of a day group or an open thread, in a sheet that slides
// up like compose. Generation runs in AppModel; this only shows the cache.

import SwiftUI

struct SummarySheet: View {
    let presentation: SummaryPresentation
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var summary: GroupSummary? { model.groupSummaries[presentation.id] }

    /// What went to the provider, said accurately: a thread summary reads
    /// the messages' text, a list summary only subjects and previews.
    /// It names no destination on purpose — "the AI provider" is whoever
    /// answered, the model on this device included — so it stays true
    /// when the provider changes between the request and this line.
    private var footnote: String {
        presentation.id.hasPrefix(AppModel.threadSummaryPrefix)
            ? "The messages' text (up to \(AppModel.threadSummaryCharsPerMessage.formatted()) characters each) was sent to the AI provider."
            : "Subject and snippet only were sent to the AI provider, never the full messages."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ResultState(working: "Summarizing…", error: summary?.error, isReady: summary?.text != nil,
                                retry: { model.retrySummary(presentation) }) {
                        SummaryTextView(text: summary?.text ?? "").font(.body).foregroundStyle(Theme.textPrimary)
                    }
                    Text(footnote)
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(Theme.canvas)
            .navigationTitle(presentation.title)
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .sheetSize(.mediumOrLarge)
    }
}
