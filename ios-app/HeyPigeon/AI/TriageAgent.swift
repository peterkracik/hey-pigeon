// "Hey Siri, triage my inbox in Hey Pigeon": a model works the inbox in a
// loop with real tools over the engine (TriageTools.swift), shows progress
// as a Live Activity, and asks once before anything changes. Three phases,
// each its own session profile — the shape of a Foundation Models dynamic
// profile, one session per phase with its own model, instructions and
// tools:
//
//   scan   — on device, cheap: list the inbox, name the candidates.
//   decide — Apple's cloud when the device can reach it (deeper
//            reasoning), else on device: read what needs reading, decide
//            per candidate.
//   act    — on device, tools enabled: turn the decisions into proposals.
//
// The instructions carry the user's own rules from Settings › Triage. Every
// tool call is journaled (TriageJournal) so a run can be read back, and
// the same journal feeds the evaluation harness with real decisions.

import Foundation
import FoundationModels
import Observation

enum TriagePhase: String, Codable, Sendable {
    case scan, decide, act, confirm, apply, done, cancelled, failed

    var title: String {
        switch self {
        case .scan: "Scanning"
        case .decide: "Deciding"
        case .act: "Proposing"
        case .confirm: "Waiting for your OK"
        case .apply: "Applying"
        case .done: "Done"
        case .cancelled: "Stopped"
        case .failed: "Failed"
        }
    }
}

/// The candidates the scan phase names, as structured output.
@Generable
struct TriageScan {
    @Guide(description: "Ids of the emails worth a decision (not routine notifications already in order), at most 15.", .count(0...15))
    var candidateIds: [String]
    @Guide(description: "One line on what the inbox holds.")
    var overview: String
}

/// One decision per candidate, as structured output.
@Generable
struct TriageDecision {
    var threadId: String
    @Guide(description: "What to do: done | label | remind | needReply | draft | leave.")
    var action: String
    @Guide(description: "The label name for label, the ISO 8601 time for remind, the notes for draft; empty otherwise.")
    var detail: String
    @Guide(description: "Why, in a few words.")
    var reason: String
}

@Generable
struct TriageDecisions {
    var decisions: [TriageDecision]
}

/// One run's profile: which model and which tools each phase gets.
struct TriageProfile {
    let scanProvider: any ModelProvider
    let decideProvider: any ModelProvider
    let actProvider: any ModelProvider

    /// On device for scan and act; Apple's cloud for decide when the device
    /// can reach it, else on device.
    static func current() -> TriageProfile {
        let device = SystemModelProvider()
        var decide: any ModelProvider = device
        if let cloud = ModelProviderRegistry.provider(id: PrivateCloudComputeProvider().id), cloud.availability.isAvailable {
            decide = cloud
        }
        return TriageProfile(scanProvider: device, decideProvider: decide, actProvider: device)
    }
}

@MainActor
@Observable
final class TriageAgent: TriageToolHost {
    let model: AppModel
    let accountId: String?
    let dryRun: Bool
    let runId = UUID()
    let startedAt = Date()
    var plan = TriagePlan()
    private(set) var phase: TriagePhase = .scan
    private(set) var scanned = 0
    private(set) var candidates = 0
    private(set) var applied = 0
    private(set) var currentSubject: String?
    private(set) var error: String?
    /// Flipped by the Live Activity's Stop, the intent's cancellation or
    /// the sheet; every phase checks it between steps.
    private(set) var isCancelled = false
    private let profile: TriageProfile
    private let journalStore: TriageJournal

    /// The run in progress, for the Live Activity button and Settings.
    private(set) static var current: TriageAgent?

    init(model: AppModel, accountId: String?, dryRun: Bool, profile: TriageProfile = .current(), journal: TriageJournal = .shared) {
        self.model = model
        self.accountId = accountId
        self.dryRun = dryRun
        self.profile = profile
        journalStore = journal
    }

    static func isAvailable(_ model: AppModel) -> Bool {
        AppleIntelligenceProvider.isAvailable && !model.accounts.isEmpty
    }

    func cancel() {
        isCancelled = true
        if phase != .done && phase != .failed { setPhase(.cancelled) }
    }

    // MARK: The loop

    /// Scan → decide → act. Ends with the plan filled (phase `.confirm`),
    /// or `.done` with nothing to do, or `.cancelled` / `.failed`.
    func run() async {
        Self.current = self
        defer { if Self.current === self { Self.current = nil } }
        journal("run", "started\(dryRun ? " (dry run)" : "")\(accountId.map { " · \($0)" } ?? "")")
        do {
            setPhase(.scan)
            let scan = try await scanPhase()
            guard !isCancelled else { return }
            candidates = scan.candidateIds.count
            plan.note = scan.overview
            if scan.candidateIds.isEmpty {
                setPhase(.done)
                journal("run", "nothing to do")
                return
            }
            setPhase(.decide)
            let decisions = try await decidePhase(scan)
            guard !isCancelled else { return }
            setPhase(.act)
            try await actPhase(decisions)
            guard !isCancelled else { return }
            setPhase(plan.isEmpty ? .done : .confirm)
            journal("run", plan.isEmpty ? "no changes proposed" : "\(plan.proposals.count) proposal(s): \(plan.confirmationSummary)")
        } catch let e as LanguageModelSession.GenerationError {
            fail(FoundationModelsBackend.describe(e))
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// The user said yes (or it is a dry run, which stops short of this).
    func applyPlan() async {
        guard phase == .confirm, !dryRun else { return }
        setPhase(.apply)
        applied = await plan.apply(to: model)
        journal("run", "applied \(applied) of \(plan.proposals.count)")
        setPhase(.done)
        await ReminderLiveActivityController.sync(model)
    }

    /// The user said no.
    func discardPlan() {
        guard phase == .confirm else { return }
        journal("run", "declined")
        setPhase(.cancelled)
    }

    // MARK: Phases

    private func scanPhase() async throws -> TriageScan {
        let rows = inboxRows(limit: 40)
        scanned = rows.count
        guard !rows.isEmpty else { return TriageScan(candidateIds: [], overview: "The inbox is clear.") }
        let session = profile.scanProvider.session(instructions: Self.scanInstructions(rules: model.triageRules), task: .completion)
        let listing = TriageToolOutput.json(rows.map { TriageRowView($0, model: model) })
        let response = try await session.respond(to: "Inbox, newest first:\n\(listing)", generating: TriageScan.self)
        AiUsageLedger.shared.record(provider: profile.scanProvider.id, response.usage)
        let known = Set(rows.map(\.id))
        var scan = response.content
        scan.candidateIds = scan.candidateIds.filter(known.contains)
        journal("scan", "\(rows.count) rows · \(scan.candidateIds.count) candidates · \(scan.overview)")
        return scan
    }

    private func decidePhase(_ scan: TriageScan) async throws -> TriageDecisions {
        let session = profile.decideProvider.session(
            instructions: Self.decideInstructions(rules: model.triageRules, labels: labelNames),
            task: .classification,
            tools: [ReadThreadTool(host: self)]
        )
        var rows: [TriageRowView] = []
        for id in scan.candidateIds {
            guard !isCancelled else { break }
            if let row = try? model.engine.threadRow(id: id) {
                currentSubject = row.subject
                rows.append(TriageRowView(row, model: model))
            }
        }
        let response = try await session.respond(
            to: "Decide for each of these emails. Read one only when its preview does not settle it.\n\(TriageToolOutput.json(rows))",
            generating: TriageDecisions.self
        )
        AiUsageLedger.shared.record(provider: profile.decideProvider.id, response.usage)
        for d in response.content.decisions { journal("decide", "\(d.action) · \(d.threadId) · \(d.reason)") }
        return response.content
    }

    private func actPhase(_ decisions: TriageDecisions) async throws {
        let actionable = decisions.decisions.filter { $0.action.lowercased() != "leave" }
        guard !actionable.isEmpty else { return }
        let tools: [any Tool] = [
            SetLabelTool(host: self), MarkDoneTool(host: self), RemindTool(host: self),
            MarkNeedReplyTool(host: self), DraftReplyTool(host: self),
        ]
        let session = profile.actProvider.session(instructions: Self.actInstructions, task: .completion, tools: tools)
        let list = actionable.map { "\($0.threadId): \($0.action) \($0.detail)".trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        currentSubject = nil
        let response = try await session.respond(to: "Carry out these decisions with the tools, one call each:\n\(list)\nAnswer \"done\" when every decision has its tool call.")
        AiUsageLedger.shared.record(provider: profile.actProvider.id, response.usage)
    }

    // MARK: Helpers

    private func inboxRows(limit: Int) -> [ThreadRow] {
        ((try? model.engine.threads(in: .inbox, accountId: accountId, before: nil, limit: limit)) ?? [])
            .filter { !$0.isDone }
    }

    private var labelNames: [String] {
        let ids = Set(model.accounts.map(\.id))
        return model.labels.filter { ids.contains($0.accountId) && !$0.id.hasPrefix("CATEGORY_") }.map(\.name)
    }

    private func setPhase(_ p: TriagePhase) {
        phase = p
        Task { await TriageLiveActivityController.update(self) }
    }

    private func fail(_ message: String) {
        error = message
        journal("run", "failed: \(message)")
        setPhase(.failed)
    }

    func journal(_ tool: String, _ detail: String) {
        journalStore.append(TriageJournalEntry(runId: runId, at: Date(), phase: phase, tool: tool, detail: detail, dryRun: dryRun))
    }

    // MARK: Instructions

    static func scanInstructions(rules: String) -> String {
        """
        You help a busy person triage their inbox. You will see the newest active emails (id, sender, \
        subject, preview, labels, flags). Pick the ones worth a decision: a person asking for something, \
        a date or deadline, a payment, travel, anything that should be filed under one of their labels, \
        and anything that is clearly finished and can be marked done. Skip routine notifications that are \
        already in order. Give an overview in one line.\(rulesBlock(rules))
        """
    }

    static func decideInstructions(rules: String, labels: [String]) -> String {
        """
        For each email decide one action: done (nothing more to do), label (file it; give the label name), \
        remind (give an ISO 8601 time, a day before any date it names, 09:00 local), needReply (a person \
        is waiting on the user), draft (needReply plus a reply worth drafting; give notes on what to say), \
        or leave. Labels that exist: \(labels.isEmpty ? "(none)" : labels.joined(separator: ", ")). Read an \
        email with the tool only when the preview does not settle it. Never delete, never send.\(rulesBlock(rules))
        """
    }

    static let actInstructions = """
    You turn decisions into tool calls, one per decision, exactly as given: done → markDone, label → setLabel \
    with the label name, remind → remind with the ISO 8601 time, needReply → markNeedReply on, draft → \
    draftReply with the notes. Do not invent decisions. Answer "done" when finished.
    """

    private static func rulesBlock(_ rules: String) -> String {
        let r = rules.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.isEmpty ? "" : "\n\nThe person's own rules, which win over everything above:\n\(r)"
    }
}

// MARK: - Journal

struct TriageJournalEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    let runId: UUID
    let at: Date
    let phase: TriagePhase
    let tool: String
    let detail: String
    let dryRun: Bool
}

/// Every tool call of every run, newest last, in Application Support —
/// readable in Settings › Triage › Journal, and the raw material for the
/// evaluation set. Capped so it stays small.
@Observable
final class TriageJournal: @unchecked Sendable {
    static let shared = TriageJournal()
    static let cap = 500

    private(set) var entries: [TriageJournalEntry]
    private let url: URL?
    private let lock = NSLock()

    init(url: URL? = TriageJournal.defaultURL) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder.shared.decode([TriageJournalEntry].self, from: data) {
            entries = saved
        } else {
            entries = []
        }
    }

    static var defaultURL: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("HeyPigeon", isDirectory: true)
            .appendingPathComponent("triage-journal.json")
    }

    func append(_ e: TriageJournalEntry) {
        lock.lock()
        entries.append(e)
        if entries.count > Self.cap { entries.removeFirst(entries.count - Self.cap) }
        save()
        lock.unlock()
    }

    func clear() {
        lock.lock()
        entries = []
        save()
        lock.unlock()
    }

    /// Runs, newest first, each with its entries in order.
    var runs: [(id: UUID, entries: [TriageJournalEntry])] {
        var order: [UUID] = []
        var byRun: [UUID: [TriageJournalEntry]] = [:]
        for e in entries {
            if byRun[e.runId] == nil { order.append(e.runId) }
            byRun[e.runId, default: []].append(e)
        }
        return order.reversed().map { ($0, byRun[$0] ?? []) }
    }

    private func save() {
        guard let url, let data = try? JSONEncoder.shared.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
