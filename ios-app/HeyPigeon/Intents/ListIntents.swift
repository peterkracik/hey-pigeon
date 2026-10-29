// The intents about lists rather than one thread: open a folder, search,
// "what needs a reply", "what's due", summarize the inbox, sync. The
// question intents return entities (a Shortcut can chain Mark done onto
// them) plus a spoken line and a small snippet.

import AppIntents
import Foundation
import SwiftUI

struct OpenFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Folder"
    static let description = IntentDescription("Opens a folder or tab in Hey Pigeon.", categoryName: "Navigation")
    static let openAppWhenRun = true

    @Parameter(title: "Folder", default: .inbox) var folder: MailFolder

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$folder)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        model.show(folder.view)
        return .result()
    }
}

struct SearchMailIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Mail"
    static let description = IntentDescription(
        "Searches your mail by sender, subject and text, with the app's operators (from:, to:, is:unread, account:).",
        categoryName: "Find"
    )

    @Parameter(title: "Search for") var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search mail for \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[MailThreadEntity]> & ProvidesDialog & ShowsSnippetView {
        let model = try await IntentSupport.model()
        await IntentSupport.syncIfStale(model)
        let rows = (try? model.engine.search(query, limit: 20)) ?? []
        let entities = IntentSupport.entities(rows, in: model)
        let dialog: IntentDialog = rows.isEmpty
            ? "Nothing matches \(query)."
            : "\(rows.count == 1 ? "One email matches" : "\(rows.count) emails match") \(query)."
        return .result(value: entities, dialog: dialog, view: ThreadsSnippet(rows: Array(rows.prefix(5)), accent: .none))
    }
}

struct WhatNeedsReplyIntent: AppIntent {
    static let title: LocalizedStringResource = "What Needs a Reply"
    static let description = IntentDescription("The emails you flagged as needing a reply.", categoryName: "Find")

    @Parameter(title: "Account") var account: MailAccountEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("What needs a reply") {
            \.$account
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[MailThreadEntity]> & ProvidesDialog & ShowsSnippetView {
        let model = try await IntentSupport.model()
        await IntentSupport.syncIfStale(model)
        let rows = (try? model.engine.threads(in: .needReply, accountId: account?.id, before: nil, limit: 500)) ?? []
        let dialog: IntentDialog
        switch rows.count {
        case 0: dialog = "Nothing is waiting on a reply."
        case 1: dialog = "One email needs a reply: \(rows[0].fromSummary) about \(rows[0].subject)."
        default: dialog = "\(rows.count) emails need a reply. The newest is from \(rows[0].fromSummary) about \(rows[0].subject)."
        }
        return .result(value: IntentSupport.entities(rows, in: model), dialog: dialog,
                       view: ThreadsSnippet(rows: Array(rows.prefix(5)), accent: .needReply))
    }
}

struct WhatsDueIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Due"
    static let description = IntentDescription("Reminders whose time has come, and what is scheduled next.", categoryName: "Find")

    @Parameter(title: "Account") var account: MailAccountEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("What's due") {
            \.$account
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[MailThreadEntity]> & ProvidesDialog & ShowsSnippetView {
        let model = try await IntentSupport.model()
        await IntentSupport.syncIfStale(model)
        let scheduled = model.scheduledThreads(accountId: account?.id)
            .sorted { ($0.scheduledAt ?? .distantFuture) < ($1.scheduledAt ?? .distantFuture) }
        let due = AppModel.due(scheduled)
        let dialog: IntentDialog
        if due.isEmpty, let next = scheduled.first, let at = next.scheduledAt {
            dialog = "Nothing is due. Next up is \(next.fromSummary) about \(next.subject), \(Formatters.reminder(at))."
        } else if due.isEmpty {
            dialog = "Nothing is due and nothing is scheduled."
        } else if due.count == 1 {
            dialog = "One reminder is due: \(due[0].fromSummary) about \(due[0].subject)."
        } else {
            dialog = "\(due.count) reminders are due. First: \(due[0].fromSummary) about \(due[0].subject)."
        }
        let shown = due.isEmpty ? Array(scheduled.prefix(5)) : Array(due.prefix(5))
        return .result(value: IntentSupport.entities(due, in: model), dialog: dialog,
                       view: ThreadsSnippet(rows: shown, accent: .reminder))
    }
}

struct SummarizeInboxIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize Inbox"
    static let description = IntentDescription(
        "A few lines about what is active in your inbox, from the AI provider set up in Hey Pigeon.",
        categoryName: "Find"
    )

    @Parameter(title: "Account") var account: MailAccountEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Summarize my inbox") {
            \.$account
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        let model = try await IntentSupport.model()
        guard model.aiConfigured else { throw IntentError.aiOff }
        await IntentSupport.syncIfStale(model)
        let rows = ((try? model.engine.threads(in: .inbox, accountId: account?.id, before: nil, limit: AppModel.pageSize)) ?? [])
            .filter { !$0.isDone }
            .prefix(40)
        guard !rows.isEmpty else {
            return .result(value: "Nothing active in the inbox.", dialog: "Your inbox is clear.",
                           view: SummarySnippet(text: "All clear.", title: "Inbox"))
        }
        let items = rows.map { (from: $0.fromSummary, subject: $0.subject, snippet: $0.snippet) }
        let text = try await model.engine.aiSummarizeGroup(items: items)
        let title = account.map { "Inbox · \($0.name)" } ?? "Inbox"
        return .result(value: text, dialog: IntentDialog(stringLiteral: text), view: SummarySnippet(text: text, title: title))
    }
}

/// "Ask Hey Pigeon" (then "when is the Lisbon flight"): the on-device model over
/// the Spotlight index (AI/InboxAsk.swift). Answers in the background with
/// the cited threads as the snippet; nothing leaves the device.
struct AskInboxIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask My Inbox"
    static let description = IntentDescription(
        "Answers a question about your own mail on this iPhone, from the index Siri uses. Nothing is sent anywhere.",
        categoryName: "Find"
    )

    @Parameter(title: "Question") var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask my inbox \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        let model = try await IntentSupport.model()
        await IntentSupport.syncIfStale(model)
        let answer = try await InboxAsk.answer(question, model: model)
        let rows = InboxAsk.validCitations(answer.citedThreadIds, in: model)
        return .result(value: answer.answer, dialog: IntentDialog(stringLiteral: answer.answer),
                       view: ThreadsSnippet(rows: Array(rows.prefix(5)), accent: .none))
    }
}

struct SyncNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Check for Mail"
    static let description = IntentDescription("Syncs every account now and says how much is unread.", categoryName: "Find")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let model = try await IntentSupport.model()
        guard !model.accounts.isEmpty else { throw IntentError.noAccount }
        await model.sync()
        let unread = (try? model.engine.unreadCounts(accountId: nil))?["inbox"] ?? 0
        let dialog: IntentDialog
        switch unread {
        case 0: dialog = "Up to date. Nothing unread."
        case 1: dialog = "Up to date. One unread email."
        default: dialog = "Up to date. \(unread) unread emails."
        }
        return .result(value: unread, dialog: dialog)
    }
}

// MARK: - Snippets

/// Up to five rows under Siri's answer, in the inbox row's shape: sender ·
/// time, subject, one preview line. System fonts and colours: the snippet
/// renders on Siri's surface, not in the app.
struct ThreadsSnippet: View {
    enum Accent { case none, needReply, reminder }
    let rows: [ThreadRow]
    let accent: Accent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.fromSummary).font(.subheadline.weight(row.isRead ? .semibold : .bold)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(trailing(row)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text(row.subject.isEmpty ? "(no subject)" : row.subject)
                        .font(.subheadline.weight(row.isRead ? .regular : .semibold)).lineLimit(1)
                    Text(row.snippet).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if rows.isEmpty {
                Text("Nothing here.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func trailing(_ row: ThreadRow) -> String {
        switch accent {
        case .reminder: row.scheduledAt.map(Formatters.reminder) ?? Formatters.rowTime(row.lastMessageAt)
        case .none, .needReply: Formatters.rowTime(row.lastMessageAt)
        }
    }
}

struct SummarySnippet: View {
    let text: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.subheadline)
        }
        .padding()
    }
}
