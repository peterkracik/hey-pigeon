// Interaction donations (docs/ios-intelligence.md, "iOS 27 › Siri's model
// of the app"): when the user performs one of the schema-shaped actions in
// the UI — archive, delete, reply, label, remind — the matching intent is
// donated with its result, so Apple Intelligence learns which actions this
// app owns and offers them in the right moments. Accurate and sparse: only
// user gestures donate (a swipe, a menu, a sheet), never an intent Siri
// just ran, never a sync, never the agent.

import AppIntents
import Foundation

@MainActor
enum IntentDonations {
    /// Off in the sample inbox and in tests: donations are system state.
    nonisolated(unsafe) static var enabled = true

    // The donations themselves live next to their intents: labeled(_:_:on:in:)
    // and reminded(_:at:onlyIfNoReply:in:) in ThreadIntents.swift,
    // archived(_:in:), deleted(_:in:) and replied(_:all:in:) in
    // MailSchemaIntents.swift. The Mac's Debug build compiles files in
    // batches, and setting an intent's @Parameter from another file lost
    // the entity's macro-made AppEntity conformance whenever a new file
    // moved the batch boundary ("requires that 'MailThreadEntity' conform
    // to '_IntentValue'", macos-ci on #102; the same for
    // 'MailMessageEntity' on #118, with this file in the intents' own batch
    // but ahead of them).

    // MARK: Plumbing

    static func messageEntity(_ row: ThreadRow, _ model: AppModel) -> MailMessageEntity? {
        model.account(for: row).map { MailMessageEntity(row, account: $0) }
    }

    /// `IntentDonationManager.shared.donate(intent:result:)` (iOS 27). A
    /// failed donation is nothing to tell the user about.
    static func donate<I: AppIntent>(_ intent: I, result: some IntentResult) {
        Task {
            try? await IntentDonationManager.shared.donate(intent: intent, result: result)
        }
    }
}
