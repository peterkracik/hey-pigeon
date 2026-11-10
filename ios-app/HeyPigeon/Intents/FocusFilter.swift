// A Focus filter (System Settings › Focus › a Focus › Focus Filters › Hey
// Pigeon): while that Focus is on, the app shows one account — the work
// account during Work, the personal one in the evening — and new-mail
// banners come only from it. The system runs the intent when the Focus
// turns on, and again with no account when it turns off.

import AppIntents

struct MailFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Show One Account"
    static let description = IntentDescription(
        "While this Focus is on, the list shows one account's mail and new-mail banners come only from that account."
    )

    @Parameter(title: "Account")
    var account: MailAccountEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Show One Account", subtitle: account.map { "\($0.name)" } ?? "All accounts")
    }

    func perform() async throws -> some IntentResult {
        let id = account?.id
        let model = try await IntentSupport.model()
        await model.applyFocus(accountId: id)
        return .result()
    }
}
