// Settings › Triage › "Siri triage": run a triage from the app (same agent
// Siri uses, the confirmation as a list with Apply / Leave as is), and the
// journal — every run's tool calls, newest first — so what the model did
// is never a mystery, and the rows worth keeping can become evaluation
// cases.

import SwiftUI

struct TriageJournalView: View {
    @Environment(AppModel.self) private var model
    private let journal = TriageJournal.shared

    var body: some View {
        List {
            runSection
            if journal.entries.isEmpty {
                Section { Text("No runs yet.").font(.footnote).foregroundStyle(Theme.textTertiary) }.menuCard()
            }
            ForEach(journal.runs, id: \.id) { run in
                Section {
                    ForEach(run.entries) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(e.tool).font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                                Text(e.phase.title).font(.caption).foregroundStyle(Theme.textTertiary)
                                Spacer()
                                Text(e.at, style: .time).font(.caption).foregroundStyle(Theme.textTertiary).monospacedDigit()
                            }
                            Text(e.detail).font(.footnote).foregroundStyle(Theme.textPrimary)
                        }
                    }
                } header: {
                    if let first = run.entries.first {
                        Text("\(Formatters.rowTime(first.at))\(first.dryRun ? " · dry run" : "")")
                    }
                }
                .menuCard()
            }
            if !journal.entries.isEmpty {
                Section {
                    Button("Clear journal", role: .destructive) { journal.clear() }
                } footer: {
                    Text("Kept on this \(Device.name) only, the last \(TriageJournal.cap) tool calls.")
                }
                .menuCard()
            }
        }
        .menuList()
        .navigationTitle("Siri triage")
        .toolbarTitleDisplayMode(.inline)
    }

    /// The run in progress, its proposals and the two buttons; or Run now.
    @ViewBuilder private var runSection: some View {
        Section {
            if let agent = model.triageAgent {
                HStack {
                    if ![.done, .cancelled, .failed, .confirm].contains(agent.phase) { ProgressView().padding(.trailing, 6) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.phase.title).font(.body.weight(.medium))
                        Text("\(agent.scanned) scanned · \(agent.candidates) picked · \(agent.plan.proposals.count) proposed")
                            .font(.caption).foregroundStyle(Theme.textTertiary).monospacedDigit()
                    }
                    Spacer()
                    if agent.phase == .scan || agent.phase == .decide || agent.phase == .act {
                        Button("Stop") { agent.cancel() }.font(.footnote.weight(.semibold))
                    }
                }
                if let error = agent.error { Text(error).font(.footnote).foregroundStyle(.red) }
                if !agent.plan.note.isEmpty { Text(agent.plan.note).font(.footnote).foregroundStyle(Theme.textSecondary) }
                ForEach(agent.plan.proposals) { p in Text(p.line).font(.footnote) }
                if agent.phase == .confirm {
                    HStack {
                        Button("Apply") { Task { await agent.applyPlan(); model.triageAgent = nil } }
                            .font(.footnote.weight(.semibold))
                        Spacer()
                        Button("Leave as is", role: .cancel) { agent.discardPlan(); model.triageAgent = nil }
                            .font(.footnote.weight(.semibold))
                    }
                } else if [.done, .cancelled, .failed].contains(agent.phase) {
                    Button("Clear") { model.triageAgent = nil }.font(.footnote.weight(.semibold))
                }
            } else {
                Button {
                    let agent = TriageAgent(model: model, accountId: model.selectedAccountId, dryRun: model.triageDryRun)
                    model.triageAgent = agent
                    Task { await agent.run() }
                } label: {
                    Label(model.triageDryRun ? "Dry run now" : "Triage now", systemImage: "sparkles")
                }
                .disabled(!TriageAgent.isAvailable(model))
            }
        } header: {
            Text("Run")
        } footer: {
            Text("Same as \"Hey Siri, triage my inbox in Hey Pigeon\": the on-device model scans the inbox, decides, and proposes; nothing changes until you apply. Delete and send are never on the table.")
        }
        .menuCard()
    }
}
