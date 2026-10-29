// One intent per verb on a thread, in the desktop's words: Mark done (`e`),
// Remind me (`h`), Need reply (`n`), Pin (`s`), Read / unread (`u`), Delete
// (`#`), Add label (`l`), Open. Each takes a thread Siri resolves — "this"
// (the open one), "the one from Anna", or a pick — runs in the background
// through AppModel exactly like the swipe, and answers with the toast's
// words. Toggles are explicit sets (`on: Bool`) so a Shortcut is
// idempotent; the swipe keeps toggling.

import AppIntents
import Foundation

struct MarkDoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Done"
    static let description = IntentDescription("Marks an email done — checks it off and archives it.", categoryName: "Triage")

    @Parameter(title: "Email") var thread: MailThreadEntity
    @Parameter(title: "Done", default: true) var done: Bool

    static var parameterSummary: some ParameterSummary {
        When(\.$done, .equalTo, true) {
            Summary("Mark \(\.$thread) done")
        } otherwise: {
            Summary("Mark \(\.$thread) not done")
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentSupport.model()
        let row = try IntentSupport.row(thread, in: model)
        if done {
            if !row.isDone { model.markDone(row) }
            return .result(dialog: "Marked done.")
        }
        if row.isDone { model.markNotDone(row) }
        return .result(dialog: "Moved back to the inbox.")
    }
}

struct RemindMeIntent: AppIntent {
    static let title: LocalizedStringResource = "Remind Me"
    static let description = IntentDescription(
        "Sets a reminder on an email. It leaves the inbox for Scheduled and comes back when the time comes.",
        categoryName: "Triage"
    )

    @Parameter(title: "Email") var thread: MailThreadEntity
    /// A preset, or "Pick a date…" which then asks for `date`. Required, so
    /// Siri asks with the list when it was not said ("When?" — "Tomorrow").
    @Parameter(title: "When") var when: RemindWhen
    @Parameter(title: "Date") var date: Date?
    @Parameter(title: "Only if nobody replies", default: false) var onlyIfNoReply: Bool

    static var parameterSummary: some ParameterSummary {
        When(\.$when, .equalTo, .pickDate) {
            Summary("Remind me about \(\.$thread) on \(\.$date)") {
                \.$onlyIfNoReply
            }
        } otherwise: {
            Summary("Remind me about \(\.$thread) \(\.$when)") {
                \.$onlyIfNoReply
            }
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentSupport.model()
        let row = try IntentSupport.row(thread, in: model)
        let at = try await resolveDate()
        model.remind(row, at: at, onlyIfNoReply: onlyIfNoReply)
        let whenText = Formatters.reminder(at)
        return .result(dialog: onlyIfNoReply
            ? "I'll remind you \(whenText) if nobody replies."
            : "Reminder set for \(whenText).")
    }

    /// An explicit date wins; else the preset's date; else ask for one
    /// ("Pick a date…", or "Later today" after 18:00 has passed).
    private func resolveDate() async throws -> Date {
        if let date { return date }
        if let preset = when.preset, let d = preset.date() { return d }
        let picked = try await $date.requestValue("When should I remind you?")
        guard let d = picked as Date? else { throw IntentError.noDate }
        return d
    }
}

struct NeedReplyIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Need Reply"
    static let description = IntentDescription("Flags an email as needing your reply; it moves to the Need reply tab.", categoryName: "Triage")

    @Parameter(title: "Email") var thread: MailThreadEntity
    @Parameter(title: "Needs reply", default: true) var on: Bool

    static var parameterSummary: some ParameterSummary {
        When(\.$on, .equalTo, true) {
            Summary("Mark \(\.$thread) as needing a reply")
        } otherwise: {
            Summary("Clear need reply on \(\.$thread)")
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentSupport.model()
        let row = try IntentSupport.row(thread, in: model)
        if row.needsReply != on { model.toggleNeedsReply(row) }
        return .result(dialog: on ? "Marked Need reply." : "Removed from Need reply.")
    }
}

struct PinIntent: AppIntent {
    static let title: LocalizedStringResource = "Pin"
    static let description = IntentDescription("Pins an email (the Gmail star).", categoryName: "Triage")

    @Parameter(title: "Email") var thread: MailThreadEntity
    @Parameter(title: "Pinned", default: true) var on: Bool

    static var parameterSummary: some ParameterSummary {
        When(\.$on, .equalTo, true) {
            Summary("Pin \(\.$thread)")
        } otherwise: {
            Summary("Unpin \(\.$thread)")
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentSupport.model()
        let row = try IntentSupport.row(thread, in: model)
        if row.isPinned != on { model.togglePin(row) }
        return .result(dialog: on ? "Pinned." : "Unpinned.")
    }
}

struct MarkReadIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Read"
    static let description = IntentDescription("Marks an email read or unread.", categoryName: "Triage")

    @Parameter(title: "Email") var thread: MailThreadEntity
    @Parameter(title: "Read", default: true) var read: Bool

    static var parameterSummary: some ParameterSummary {
        When(\.$read, .equalTo, true) {
            Summary("Mark \(\.$thread) read")
        } otherwise: {
            Summary("Mark \(\.$thread) unread")
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentSupport.model()
        let row = try IntentSupport.row(thread, in: model)
        if row.isRead != read { model.toggleRead(row) }
        return .result(dialog: read ? "Marked read." : "Marked unread.")
    }
}

struct DeleteIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete Email"
    static let description = IntentDescription("Moves an email to the trash.", categoryName: "Triage")

    @Parameter(title: "Email") var thread: MailThreadEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Delete \(\.$thread)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentSupport.model()
        let row = try IntentSupport.row(thread, in: model)
        try await requestConfirmation(result: .result(dialog: "Delete \"\(thread.subject)\" from \(thread.from)?"))
        model.delete(row)
        return .result(dialog: "Deleted.")
    }
}

struct AddLabelIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Label"
    static let description = IntentDescription("Adds or removes one of the account's Gmail labels on an email.", categoryName: "Triage")

    @Parameter(title: "Email") var thread: MailThreadEntity
    @Parameter(title: "Label") var label: MailLabelEntity
    @Parameter(title: "Add", default: true) var add: Bool

    static var parameterSummary: some ParameterSummary {
        When(\.$add, .equalTo, true) {
            Summary("Add \(\.$label) to \(\.$thread)")
        } otherwise: {
            Summary("Remove \(\.$label) from \(\.$thread)")
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentSupport.model()
        let row = try IntentSupport.row(thread, in: model)
        guard label.accountId == row.accountId else { throw IntentError.wrongAccount(label: label.name) }
        model.setLabel(row, label.item, on: add)
        return .result(dialog: add ? "Label added · \(label.name)." : "Label removed · \(label.name).")
    }
}

struct OpenThreadIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Email"
    static let description = IntentDescription("Opens an email in Hey Pigeon.", categoryName: "Navigation")
    static let openAppWhenRun = true

    @Parameter(title: "Email") var thread: MailThreadEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$thread)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        _ = try IntentSupport.row(thread, in: model)
        model.openThread(id: thread.id)
        return .result()
    }
}
