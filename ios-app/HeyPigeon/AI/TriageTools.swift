// The tools an agentic triage run may call (docs/ios-intelligence.md,
// "iOS 27 › Agentic triage"): thin Foundation Models `Tool`s over AppModel
// and the engine. Reading tools answer at once; acting tools never touch
// the mailbox — they add a proposal to the run's TriagePlan, which the
// user confirms once as a batch (or never, in a dry run). Delete and send
// are deliberately not tools.

import Foundation
import FoundationModels

// MARK: - Proposals

/// One change the agent wants to make. Applied by `TriagePlan.apply` after
/// confirmation, through the same AppModel methods the swipes use.
enum TriageProposal: Equatable, Identifiable, Codable {
    case markDone(threadId: String, subject: String)
    case label(threadId: String, subject: String, labelId: String, labelName: String, on: Bool)
    case remind(threadId: String, subject: String, at: Date, onlyIfNoReply: Bool)
    case needReply(threadId: String, subject: String, on: Bool)
    case draft(threadId: String, subject: String, body: String)

    var id: String {
        switch self {
        case .markDone(let t, _): "done:\(t)"
        case .label(let t, _, let l, _, let on): "label:\(t):\(l):\(on)"
        case .remind(let t, _, _, _): "remind:\(t)"
        case .needReply(let t, _, let on): "needreply:\(t):\(on)"
        case .draft(let t, _, _): "draft:\(t)"
        }
    }

    var threadId: String {
        switch self {
        case .markDone(let t, _), .label(let t, _, _, _, _), .remind(let t, _, _, _), .needReply(let t, _, _), .draft(let t, _, _): t
        }
    }

    /// One line for the journal and the confirmation sheet.
    var line: String {
        switch self {
        case .markDone(_, let s): "Mark done · \(s)"
        case .label(_, let s, _, let name, let on): "\(on ? "Label" : "Unlabel") \(name) · \(s)"
        case .remind(_, let s, let at, let follow): "\(follow ? "Follow up" : "Remind") \(Formatters.reminder(at)) · \(s)"
        case .needReply(_, let s, let on): "\(on ? "Need reply" : "Clear need reply") · \(s)"
        case .draft(_, let s, _): "Draft a reply · \(s)"
        }
    }
}

struct TriagePlan: Equatable, Codable {
    var proposals: [TriageProposal] = []
    /// What the model said about the run, for the dialog.
    var note = ""

    var isEmpty: Bool { proposals.isEmpty }

    /// Adds a proposal unless the same one is already there (the model
    /// repeats itself); returns whether it was new.
    @discardableResult
    mutating func add(_ p: TriageProposal) -> Bool {
        guard !proposals.contains(where: { $0.id == p.id }) else { return false }
        proposals.append(p)
        return true
    }

    /// "Archive 12, label 3, remind 2?" — one confirmation for the batch.
    var confirmationSummary: String {
        var counts: [(String, Int)] = []
        func bump(_ name: String) {
            if let i = counts.firstIndex(where: { $0.0 == name }) { counts[i].1 += 1 } else { counts.append((name, 1)) }
        }
        for p in proposals {
            switch p {
            case .markDone: bump("mark done")
            case .label: bump("label")
            case .remind: bump("remind")
            case .needReply: bump("flag need reply")
            case .draft: bump("draft a reply for")
            }
        }
        guard !counts.isEmpty else { return "Nothing to change." }
        let parts = counts.map { "\($0.0) \($0.1)" }
        return parts.count == 1 ? parts[0].prefix(1).capitalized + parts[0].dropFirst() + "?"
            : parts.dropLast().joined(separator: ", ").prefix(1).capitalized + parts.dropLast().joined(separator: ", ").dropFirst() + " and \(parts.last!)?"
    }

    /// Apply every proposal through AppModel; a thread that is gone or
    /// already in the proposed state is skipped. Returns how many landed.
    @MainActor
    func apply(to model: AppModel) async -> Int {
        var applied = 0
        for p in proposals {
            guard let row = try? model.engine.threadRow(id: p.threadId) else { continue }
            switch p {
            case .markDone:
                guard !row.isDone else { continue }
                model.markDone(row)
            case .label(_, _, let labelId, let name, let on):
                guard row.labels.contains(labelId) != on else { continue }
                model.setLabel(row, MailLabelItem(id: labelId, accountId: row.accountId, name: name), on: on)
            case .remind(_, _, let at, let follow):
                model.remind(row, at: at, onlyIfNoReply: follow)
            case .needReply(_, _, let on):
                guard row.needsReply != on else { continue }
                model.toggleNeedsReply(row)
            case .draft(_, _, let body):
                guard let detail = try? await model.engine.thread(id: row.id), let last = detail.messages.last else { continue }
                var d = SendDraft.reply(to: last, in: row, all: false, history: nil)
                d.bodyText = body
                model.saveDraft(d, from: row.accountId)
            }
            applied += 1
        }
        model.toast = nil // one run, one outcome: the intent's dialog says it
        return applied
    }
}

// MARK: - The tools

/// What the agent is allowed to see and change: the model and the plan
/// of the run in progress. Tools hold it unowned; the agent outlives them.
@MainActor
protocol TriageToolHost: AnyObject {
    var model: AppModel { get }
    var plan: TriagePlan { get set }
    var accountId: String? { get }
    func journal(_ tool: String, _ detail: String)
}

/// One row as the model reads it: never a body in the scan phase.
struct TriageRowView: Codable {
    let id: String
    let from: String
    let subject: String
    let preview: String
    let receivedAt: String
    let isUnread: Bool
    let labels: [String]
    let needsReply: Bool
    let reminderAt: String?

    @MainActor
    init(_ row: ThreadRow, model: AppModel) {
        id = row.id
        from = row.fromSummary
        subject = row.subject
        preview = row.snippet
        receivedAt = Formatters.rowTime(row.lastMessageAt)
        isUnread = !row.isRead
        labels = row.labels.compactMap { id in model.labels.first { $0.id == id && $0.accountId == row.accountId }?.name }
            + row.triageLabelIds.compactMap { id in model.triageLabels.first { $0.id == id }?.name }
        needsReply = row.needsReply
        reminderAt = row.scheduledAt.map(Formatters.reminder)
    }
}

enum TriageToolOutput {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static func json<T: Encodable>(_ value: T) -> String {
        (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}

struct SearchThreadsTool: Tool {
    unowned let host: any TriageToolHost
    let name = "searchThreads"
    let description = "Finds emails. Use an empty query for the inbox's newest active mail, or words, from:address, is:unread. Returns id, sender, subject, preview, labels and flags — never the body."

    @Generable
    struct Arguments {
        @Guide(description: "Search words and operators; empty for the inbox.")
        var query: String
        @Guide(description: "How many to return, 1 to 40.", .range(1...40))
        var limit: Int
    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            let model = host.model
            let q = arguments.query.trimmingCharacters(in: .whitespaces)
            var rows: [ThreadRow]
            if q.isEmpty {
                rows = (try? model.engine.threads(in: .inbox, accountId: host.accountId, before: nil, limit: arguments.limit)) ?? []
            } else {
                let query = host.accountId.map { "account:\($0) \(q)" } ?? q
                rows = (try? model.engine.search(query, limit: arguments.limit)) ?? []
            }
            rows = rows.filter { !$0.isDone && !$0.labels.contains("TRASH") && !$0.labels.contains("SPAM") }
            host.journal(name, q.isEmpty ? "inbox · \(rows.count) rows" : "\"\(q)\" · \(rows.count) rows")
            return TriageToolOutput.json(rows.map { TriageRowView($0, model: model) })
        }
    }
}

struct ReadThreadTool: Tool {
    unowned let host: any TriageToolHost
    let name = "readThread"
    let description = "Reads one email's messages (sender, date, text) when the preview is not enough to decide. Costs more than searching; read only what matters."

    @Generable
    struct Arguments {
        @Guide(description: "The email's id from searchThreads.")
        var threadId: String
    }

    struct Message: Codable {
        let from: String
        let date: String
        let text: String
    }

    func call(arguments: Arguments) async throws -> String {
        let model = await host.model
        guard let detail = try await model.engine.thread(id: arguments.threadId) else { return "That email is gone." }
        let messages = detail.messages.suffix(6).map { m in
            let text = m.bodyText.map { MessageBodyView.splitQuoted($0)?.main ?? $0 } ?? m.snippet
            return Message(from: m.isMine ? "Me" : m.fromName, date: Formatters.fullDate(m.date), text: String(text.prefix(1_500)))
        }
        await host.journal(name, "\(detail.thread.subject) · \(messages.count) messages")
        return TriageToolOutput.json(messages)
    }
}

struct SetLabelTool: Tool {
    unowned let host: any TriageToolHost
    let name = "setLabel"
    let description = "Proposes adding or removing one of the account's Gmail labels on an email. Only labels listed in the instructions exist."

    @Generable
    struct Arguments {
        var threadId: String
        @Guide(description: "The label's exact name.")
        var label: String
        @Guide(description: "true to add, false to remove.")
        var add: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            guard let row = try? host.model.engine.threadRow(id: arguments.threadId) else { return "That email is gone." }
            guard let label = host.model.labels.first(where: {
                $0.accountId == row.accountId && $0.name.caseInsensitiveCompare(arguments.label) == .orderedSame
            }) else { return "No label named \(arguments.label) on that account." }
            let p = TriageProposal.label(threadId: row.id, subject: row.subject, labelId: label.id, labelName: label.name, on: arguments.add)
            host.journal(name, p.line)
            return host.plan.add(p) ? "Proposed." : "Already proposed."
        }
    }
}

struct MarkDoneTool: Tool {
    unowned let host: any TriageToolHost
    let name = "markDone"
    let description = "Proposes marking an email done (archived): nothing to do, or dealt with. Never for mail that asks the user for something."

    @Generable
    struct Arguments { var threadId: String }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            guard let row = try? host.model.engine.threadRow(id: arguments.threadId) else { return "That email is gone." }
            let p = TriageProposal.markDone(threadId: row.id, subject: row.subject)
            host.journal(name, p.line)
            return host.plan.add(p) ? "Proposed." : "Already proposed."
        }
    }
}

struct RemindTool: Tool {
    unowned let host: any TriageToolHost
    let name = "remind"
    let description = "Proposes a reminder on an email: it leaves the inbox and comes back at the given time. Use for things with a date — a flight, a payment due, a deadline — a day before."

    @Generable
    struct Arguments {
        var threadId: String
        @Guide(description: "When, as ISO 8601 (2026-11-14T09:00:00+01:00).")
        var at: String
        @Guide(description: "true for \"only if nobody replies\".")
        var onlyIfNoReply: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            guard let row = try? host.model.engine.threadRow(id: arguments.threadId) else { return "That email is gone." }
            guard let at = RemindTool.parse(arguments.at), at > Date() else { return "Give a future ISO 8601 time." }
            let p = TriageProposal.remind(threadId: row.id, subject: row.subject, at: at, onlyIfNoReply: arguments.onlyIfNoReply)
            host.journal(name, p.line)
            return host.plan.add(p) ? "Proposed." : "Already proposed."
        }
    }

    static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withFullDate]
        return f.date(from: s).flatMap { Calendar.current.date(bySettingHour: ReminderPreset.dayStart, minute: 0, second: 0, of: $0) }
    }
}

struct MarkNeedReplyTool: Tool {
    unowned let host: any TriageToolHost
    let name = "markNeedReply"
    let description = "Proposes flagging an email as needing the user's reply (a person asked them something), or clearing the flag."

    @Generable
    struct Arguments {
        var threadId: String
        var on: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            guard let row = try? host.model.engine.threadRow(id: arguments.threadId) else { return "That email is gone." }
            let p = TriageProposal.needReply(threadId: row.id, subject: row.subject, on: arguments.on)
            host.journal(name, p.line)
            return host.plan.add(p) ? "Proposed." : "Already proposed."
        }
    }
}

struct DraftReplyTool: Tool {
    unowned let host: any TriageToolHost
    let name = "draftReply"
    let description = "Proposes a reply draft for an email the user must answer, from these notes. Saved to Drafts for the user to edit; never sent."

    @Generable
    struct Arguments {
        var threadId: String
        @Guide(description: "What the reply should say, in a sentence or two.")
        var notes: String
    }

    func call(arguments: Arguments) async throws -> String {
        let model = await host.model
        guard let detail = try await model.engine.thread(id: arguments.threadId) else { return "That email is gone." }
        let transcript = detail.messages.map { "\($0.isMine ? "Me" : $0.fromName): \($0.bodyText ?? $0.snippet)" }.joined(separator: "\n\n")
        let body = try await model.engine.aiDraftReply(subject: detail.thread.subject, history: transcript, notes: arguments.notes)
        return await MainActor.run {
            let p = TriageProposal.draft(threadId: detail.thread.id, subject: detail.thread.subject, body: body)
            host.journal(name, p.line)
            return host.plan.add(p) ? "Proposed." : "Already proposed."
        }
    }
}
