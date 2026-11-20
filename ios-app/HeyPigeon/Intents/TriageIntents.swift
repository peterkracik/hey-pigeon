// "Hey Siri, triage my inbox in Hey Pigeon" (docs/ios-intelligence.md,
// "iOS 27 › Agentic triage"). A long-running, cancellable intent: the
// agent scans, decides and proposes while the Live Activity shows the
// tally; then one confirmation for the whole batch ("Mark done 12, label
// 3 and remind 2?"), never a question per email. A dry run stops before
// the confirmation and only reports. Delete and send are not on the table.

import AppIntents
import Foundation
import SwiftUI

struct TriageInboxIntent: AppIntent, LongRunningIntent, CancellableIntent {
    static let title: LocalizedStringResource = "Triage Inbox"
    static let description = IntentDescription(
        "Works through the inbox with on-device AI: marks finished mail done, files it under your labels, sets reminders for dates and flags what needs your reply. Asks once before changing anything. Never deletes, never sends.",
        categoryName: "Triage"
    )

    @Parameter(title: "Account") var account: MailAccountEntity?
    /// Nil follows Settings › Triage › "Dry run".
    @Parameter(title: "Dry run", description: "Only report what it would do.") var dryRun: Bool?

    static var parameterSummary: some ParameterSummary {
        Summary("Triage my inbox") {
            \.$account
            \.$dryRun
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog & ShowsSnippetView {
        let model = try await IntentSupport.model()
        guard TriageAgent.isAvailable(model) else { throw IntentError.triageOff }
        guard TriageAgent.current == nil else { throw IntentError.triageBusy }
        await IntentSupport.syncIfStale(model)
        let agent = TriageAgent(model: model, accountId: account?.id, dryRun: dryRun ?? model.triageDryRun)
        model.triageAgent = agent
        defer { if model.triageAgent === agent, agent.phase != .confirm { model.triageAgent = nil } }

        // Cancellation from Siri / Shortcuts stops the loop at its next step.
        let run = Task { await agent.run() }
        await withTaskCancellationHandler { await run.value } onCancel: { Task { @MainActor in agent.cancel() } }

        switch agent.phase {
        case .cancelled:
            return .result(value: 0, dialog: "Stopped. Nothing was changed.", view: TriageSnippet(agent: agent))
        case .failed:
            throw IntentError.askFailed(agent.error ?? "the model did not answer")
        case .done:
            return .result(value: 0, dialog: IntentDialog(stringLiteral: agent.plan.note.isEmpty ? "Nothing to do." : agent.plan.note),
                           view: TriageSnippet(agent: agent))
        default:
            break
        }
        if agent.dryRun {
            let n = agent.plan.proposals.count
            return .result(value: n,
                           dialog: "Dry run: I would \(agent.plan.confirmationSummary.dropLast()). Nothing was changed.",
                           view: TriageSnippet(agent: agent))
        }
        // One question for the whole batch.
        do {
            try await requestConfirmation(result: .result(dialog: IntentDialog(stringLiteral: agent.plan.confirmationSummary),
                                                          view: TriageSnippet(agent: agent)))
        } catch {
            agent.discardPlan()
            model.triageAgent = nil
            return .result(value: 0, dialog: "Left as is.", view: TriageSnippet(agent: agent))
        }
        await agent.applyPlan()
        model.triageAgent = nil
        let n = agent.applied
        return .result(value: n, dialog: n == 1 ? "Done, one change." : "Done, \(n) changes.", view: TriageSnippet(agent: agent))
    }
}

/// The proposals (or the tally) under Siri's answer.
struct TriageSnippet: View {
    let agent: TriageAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(agent.phase.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(agent.scanned) scanned").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if !agent.plan.note.isEmpty { Text(agent.plan.note).font(.subheadline) }
            ForEach(agent.plan.proposals.prefix(8)) { p in
                Text(p.line).font(.footnote).lineLimit(1)
            }
            if agent.plan.proposals.count > 8 {
                Text("+\(agent.plan.proposals.count - 8) more").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
