// Settings › Triage › "Siri triage": run a triage from the app (same agent
// Siri uses, the confirmation as a list with Apply / Leave as is), its two
// settings — the dry-run switch and the user's own rules — and the
// journal — every run's tool calls, newest first — so what the model did
// is never a mystery, and the rows worth keeping can become evaluation
// cases. Drawn as a settings page is (SettingsView's pieces): a run of
// the journal stands under its day as a section's title, a proposed
// change is a ruled row with what it would do in that state's colour, and
// Apply is the page's one ink action while a plan waits.

import SwiftUI

struct TriageJournalView: View {
    @Environment(AppModel.self) private var model
    private let journal = TriageJournal.shared

    var body: some View {
        @Bindable var model = model
        List {
            runSection
            // The run's two settings, beside the run they steer (they sat
            // in Settings › Triage, between the classifier and the labels).
            Section {
                Toggle(isOn: $model.triageDryRun) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dry run")
                        Text("\"Triage my inbox\" only reports what it would do.").font(Theme.secondary).foregroundStyle(Theme.textTertiary)
                    }
                }
                .tint(Theme.switchOn)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your triage rules")
                    TextEditor(text: $model.triageRules)
                        .frame(minHeight: 60)
                        .font(Theme.bodySmall)
                        .settingsTextBox()
                    Text("In your words, one per line; they win over the built-in ones. \"Newsletters are done. Anything from the bank needs a reply.\"")
                        .font(Theme.secondary).foregroundStyle(Theme.textTertiary)
                }
            } header: {
                SectionTitle("Rules")
            }
            .menuCard()
            if journal.entries.isEmpty {
                Section { Text("No runs yet.").font(Theme.secondary).foregroundStyle(Theme.textTertiary) }.menuCard()
            }
            ForEach(journal.runs, id: \.id) { run in
                Section {
                    ForEach(run.entries) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            // The tool and the time are data: the mono.
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(e.tool).font(Theme.text(.meta, .medium)).foregroundStyle(Theme.textSecondary)
                                Text(e.phase.title).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                                Spacer()
                                Text(e.at, style: .time).font(Theme.meta).foregroundStyle(Theme.textTertiary)
                            }
                            Text(e.detail).font(Theme.secondary).foregroundStyle(Theme.textPrimary)
                        }
                    }
                } header: {
                    // The run's day (or its time, today), as a section's title.
                    if let first = run.entries.first {
                        SectionTitle("\(Formatters.rowTime(first.at))\(first.dryRun ? " · dry run" : "")")
                    }
                }
                .menuCard()
            }
            if !journal.entries.isEmpty {
                Section {
                    // What deletes is written in the danger colour: the
                    // role alone gives the system's red.
                    Button(role: .destructive) { journal.clear() } label: {
                        Text("Clear journal").foregroundStyle(Theme.dangerText)
                    }
                    .settingsRowButton()
                } footer: {
                    Text("Kept on this \(Device.name) only, the last \(TriageJournal.cap) tool calls.").settingsFooter()
                }
                .menuCard()
            }
        }
        .menuList()
        .settingsRows()
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
                        Text(agent.phase.title).font(Theme.sans(.body, .medium))
                        // Counts are data: the mono.
                        Text("\(agent.scanned) scanned · \(agent.candidates) picked · \(agent.plan.proposals.count) proposed")
                            .font(Theme.meta).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    if agent.phase == .scan || agent.phase == .decide || agent.phase == .act {
                        Button("Stop") { agent.cancel() }.buttonStyle(OutlineButtonStyle())
                    }
                }
                if let error = agent.error { Text(error).font(Theme.secondary).foregroundStyle(Theme.dangerText) }
                if !agent.plan.note.isEmpty { Text(agent.plan.note).font(Theme.secondary).foregroundStyle(Theme.textSecondary) }
                ForEach(agent.plan.proposals) { p in proposalRow(p) }
                if agent.phase == .confirm {
                    // The plan waits for one answer: Apply is the page's
                    // ink action, leaving it as it is an outlined capsule.
                    // A style each, too: two plain buttons in one list row
                    // are both pressed by a tap on it.
                    HStack {
                        Button("Apply") { Task { await agent.applyPlan(); model.triageAgent = nil } }
                            .buttonStyle(InkButtonStyle())
                        Spacer()
                        Button("Leave as is", role: .cancel) { agent.discardPlan(); model.triageAgent = nil }
                            .buttonStyle(OutlineButtonStyle())
                    }
                } else if [.done, .cancelled, .failed].contains(agent.phase) {
                    Button("Clear") { model.triageAgent = nil }
                        .settingsRowButton()
                }
            } else {
                Button {
                    let agent = TriageAgent(model: model, accountId: model.selectedAccountId, dryRun: model.triageDryRun)
                    model.triageAgent = agent
                    Task { await agent.run() }
                } label: {
                    Label(model.triageDryRun ? "Dry run now" : "Triage now", systemImage: "sparkles")
                }
                .settingsRowButton()
                .disabled(!TriageAgent.isAvailable(model))
            }
        } header: {
            SectionTitle("Run")
        } footer: {
            Text("Same as \"Hey Siri, triage my inbox in Hey Pigeon\": the on-device model scans the inbox, decides, and proposes; nothing changes until you apply. Delete and send are never on the table.").settingsFooter()
        }
        .menuCard()
    }

    /// A proposed change in the plan's own words ("Mark done · Subject").
    /// What it would do is written in that state's colour, as a state is
    /// on a mail row, and the subject stays ink. The words are the plan's
    /// (`TriageProposal.line`), which puts a dot after what it does; a
    /// line without one is shown whole, in ink.
    private func proposalRow(_ p: TriageProposal) -> some View {
        let line = p.line
        let cut = line.range(of: " · ")?.lowerBound ?? line.startIndex
        let what: Text = Text(line[..<cut]).foregroundStyle(Self.stateColor(p))
        let rest = Text(line[cut...])
        return Text("\(what)\(rest)")
            .font(Theme.secondary)
            .foregroundStyle(Theme.textPrimary)
    }

    /// The colour a proposal's words are written in: its state's, as on a
    /// mail row (done mint, a reminder lavender, need reply sky, a draft
    /// coral). A label is not a state: the grey a tag is written in.
    private static func stateColor(_ p: TriageProposal) -> Color {
        switch p {
        case .markDone: Theme.state(.mint)
        case .remind: Theme.state(.lavender)
        case .needReply: Theme.state(.sky)
        case .draft: Theme.state(.coral)
        case .label: Theme.textSecondary
        }
    }
}
