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
        var intent = ArchiveMailIntent()
        intent.entities = [e]
        donate(intent, result: .result(dialog: "Marked done."))
    }

    static func deleted(_ row: ThreadRow, in model: AppModel) {
        guard enabled, let e = messageEntity(row, model) else { return }
        var intent = DeleteMailIntent()
        intent.entities = [e]
        donate(intent, result: .result(dialog: "Deleted."))
    }

    static func replied(_ row: ThreadRow, all: Bool, in model: AppModel) {
        guard enabled, let e = messageEntity(row, model) else { return }
        var intent = ReplyMailIntent()
        intent.target = e
        intent.isReplyAll = all
        intent.attachments = []
        intent.to = []
        intent.cc = []
        intent.bcc = []
        donate(intent, result: .result())
    }

    static func labeled(_ row: ThreadRow, _ label: MailLabelItem, on: Bool, in model: AppModel) {
        guard enabled, model.account(for: row) != nil else { return }
        var intent = AddLabelIntent()
        intent.thread = MailThreadEntity(row, account: model.account(for: row))
        intent.label = MailLabelEntity(label)
        intent.add = on
        donate(intent, result: .result(dialog: on ? "Label added · \(label.name)." : "Label removed · \(label.name)."))
    }

    static func reminded(_ row: ThreadRow, at: Date, onlyIfNoReply: Bool, in model: AppModel) {
        guard enabled else { return }
        var intent = RemindMeIntent()
        intent.thread = MailThreadEntity(row, account: model.account(for: row))
        intent.when = .pickDate
        intent.date = at
        intent.onlyIfNoReply = onlyIfNoReply
        donate(intent, result: .result(dialog: "Reminder set for \(Formatters.reminder(at))."))
    }

    // MARK: Plumbing

    private static func messageEntity(_ row: ThreadRow, _ model: AppModel) -> MailMessageEntity? {
        model.account(for: row).map { MailMessageEntity(row, account: $0) }
    }

    /// `IntentDonationManager.shared.donate(intent:result:)` (iOS 27). A
    /// failed donation is nothing to tell the user about.
    private static func donate<I: AppIntent>(_ intent: I, result: some IntentResult) {
        Task {
            try? await IntentDonationManager.shared.donate(intent: intent, result: result)
        }
    }
}
