// Compose and Reply open the composer prefilled; they never send. The
// 5-second send undo, the outbox and the deferred commit stay the only way
// a message leaves — from Siri too.

import AppIntents
import Foundation

struct ComposeIntent: AppIntent {
    static let title: LocalizedStringResource = "Compose Email"
    static let description = IntentDescription("Opens a new message in Hey Pigeon, prefilled with what you give it. Nothing is sent until you tap Send.", categoryName: "Write")
    static let openAppWhenRun = true

    @Parameter(title: "To", description: "Email addresses") var to: [String]?
    @Parameter(title: "Subject") var subject: String?
    @Parameter(title: "Message") var body: String?
    @Parameter(title: "From account") var account: MailAccountEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Compose an email") {
            \.$to
            \.$subject
            \.$body
            \.$account
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        guard !model.accounts.isEmpty else { throw IntentError.noAccount }
        var draft = SendDraft()
        draft.to = (to ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        draft.subject = subject ?? ""
        draft.bodyText = body ?? ""
        draft.fromAccountId = account?.id
        model.compose(draft)
        return .result()
    }
}

struct ReplyIntent: AppIntent {
    static let title: LocalizedStringResource = "Reply"
    static let description = IntentDescription("Opens a reply to an email, with your words as the draft. Nothing is sent until you tap Send.", categoryName: "Write")
    static let openAppWhenRun = true

    @Parameter(title: "Email") var thread: MailThreadEntity
    @Parameter(title: "Message") var body: String?
    @Parameter(title: "Reply all", default: false) var replyAll: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Reply to \(\.$thread)") {
            \.$body
            \.$replyAll
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        let row = try IntentSupport.row(thread, in: model)
        try await model.openReply(to: row, all: replyAll, body: body)
        return .result()
    }
}
