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

    static func archived(_ row: ThreadRow, in model: AppModel) {
        guard enabled, let e = messageEntity(row, model) else { return }
        let intent = ArchiveMailIntent()
        intent.entities = [e]
        donate(intent, result: .result(dialog: "Marked done."))
    }

    static func deleted(_ row: ThreadRow, in model: AppModel) {
        guard enabled, let e = messageEntity(row, model) else { return }
        let intent = DeleteMailIntent()
        intent.entities = [e]
        donate(intent, result: .result(dialog: "Deleted."))
    }

    static func replied(_ row: ThreadRow, all: Bool, in model: AppModel) {
        guard enabled, let e = messageEntity(row, model) else { return }
        let intent = ReplyMailIntent()
        intent.target = e
        intent.isReplyAll = all
        intent.attachments = []
        intent.to = []
        intent.cc = []
        intent.bcc = []
        donate(intent, result: .result())
    }

    // labeled(_:_:on:in:) and reminded(_:at:onlyIfNoReply:in:) live in
    // ThreadIntents.swift, next to their intents: the Mac's Debug build
    // compiles files in batches, and setting an intent's @Parameter from a
    // batch without Entities.swift lost MailThreadEntity's macro-made
    // AppEntity conformance ("requires that 'MailThreadEntity' conform to
    // '_IntentValue'", macos-ci on #102). A new file was enough to move
    // the batch boundary.

    // MARK: Plumbing

    private static func messageEntity(_ row: ThreadRow, _ model: AppModel) -> MailMessageEntity? {
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
