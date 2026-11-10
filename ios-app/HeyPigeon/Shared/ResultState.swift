// Something asked of a model or of the network, in its three states: on
// its way (a spinner and a word — allowed here, the bytes really come from
// elsewhere), failed (what went wrong, and Try again), or here. The
// summary sheet, Ask my inbox, Explain attachment and the translation
// panel each drew the first two by hand, and none offered a way to ask
// again: a failed request meant closing the sheet and starting over.

import SwiftUI

struct ResultState<Content: View>: View {
    /// What is being waited for, in a word: "Summarizing…".
    let working: String
    /// What went wrong, when something did.
    let error: String?
    /// The result is here: `content` shows it.
    let isReady: Bool
    /// Asks again; without one a failure only says what happened.
    var retry: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        if isReady {
            content()
        } else if let error {
            VStack(alignment: .leading, spacing: 8) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(Theme.dangerText)
                if let retry {
                    Button("Try again", action: retry)
                        .font(.subheadline.weight(.semibold))
                }
            }
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text(working).font(.body).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}
