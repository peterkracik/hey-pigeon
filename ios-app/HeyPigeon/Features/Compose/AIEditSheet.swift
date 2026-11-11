// The desktop AiEditPopover, plus a Write mode, as the phone's sheet over
// the shared assistant (AIAssist.swift: the presets, the requests, the
// runner). Edit: the presets, a tone, or a freeform instruction, run
// against the selection or the whole body. Write: a brief the AI turns
// into the whole message — a reply goes through the desktop's "Draft with
// AI" (the brief steers it as notes), a new message through the edit
// endpoint with a compose instruction. The sheet opens in Write when the
// body is empty.
//
// A request can always be cancelled and gives up after `AIAssist.timeout`,
// and its result is shown for review — refined with a tone, discarded, or
// applied — before it replaces anything, as on the Mac. The sheet used to
// lock itself (Cancel too) until the provider answered and then replaced
// the text at once, with nothing to take it back. Content leaves the
// device on an explicit tap only; the footer says what and to whom.

import SwiftUI

struct AIEditSheet: View {
    /// The selection, or the body without the signature.
    let text: String
    let hasSelection: Bool
    let subject: String
    let history: String?
    /// Edit result: replaces the selection or the body.
    let onApply: (String) -> Void
    /// Written draft: replaces the body (the signature stays).
    let onWrite: (String) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var mode: AIAssist.Mode
    @State private var brief = ""
    @State private var instruction = ""
    /// The request that is out and the result under review (AIAssist).
    @State private var runner = AIAssistRunner()
    @FocusState private var briefFocused: Bool

    init(text: String, hasSelection: Bool, subject: String, history: String?,
         onApply: @escaping (String) -> Void, onWrite: @escaping (String) -> Void) {
        self.text = text
        self.hasSelection = hasSelection
        self.subject = subject
        self.history = history
        self.onApply = onApply
        self.onWrite = onWrite
        _mode = State(initialValue: AIAssist.startMode(text: text))
    }

    private var running: Bool { runner.running }
    private var hasText: Bool { !AIAssist.isBlank(text) }
    /// A reply: the thread transcript is there to draft against.
    private var isReply: Bool { !AIAssist.isBlank(history ?? "") }
    private var briefTrimmed: String { brief.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var instructionTrimmed: String { instruction.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What a tap sends and to whom (AIAssist.footnote). The phone sends
    /// no AIWriteContext. `shown` is the body's one read of who answers,
    /// the same value every button of that pass hands the runner: a sync
    /// can change the active provider while the sheet is up, and the core
    /// then refuses the request rather than send it under this sentence.
    private func footnote(_ shown: AIStatus?) -> String {
        AIAssist.footnote(mode: mode, isReply: isReply, sendsWriter: false,
                          destination: AIAssist.Destination(shown),
                          refining: runner.result != nil)
    }

    var body: some View {
        // Read once per draw: the footer and the requests must not get two
        // reads that could disagree.
        let shown = try? model.engine.aiStatus()
        NavigationStack {
            List {
                if let result = runner.result {
                    reviewSections(result, shown: shown)
                } else {
                    if hasText {
                        Section {
                            Picker("Mode", selection: $mode) {
                                ForEach(AIAssist.Mode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .disabled(running)
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                    switch mode {
                    case .write: writeSections(shown)
                    case .edit: editSections(shown)
                    }
                }
                if running { workingSection }
                if let error = runner.error {
                    Section { Text(error).foregroundStyle(Theme.dangerText).font(.footnote) }
                }
                // What a tap sends, and to whom: a footer with no rows.
                Section {
                    EmptyView()
                } footer: {
                    Text(footnote(shown))
                }
            }
            .navigationTitle(mode == .write ? "Write with AI" : "Edit with AI")
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear {
                if mode == .write { briefFocused = true }
            }
            // Closing the sheet stops the request with it.
            .onDisappear { runner.cancel() }
        }
    }

    /// The request that is out: said in words, with the way to stop it.
    private var workingSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView()
                Text("Working…").foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Cancel request") { runner.cancel() }
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    // MARK: Write

    @ViewBuilder private func writeSections(_ shown: AIStatus?) -> some View {
        Section {
            TextField(isReply ? "Notes for the reply — what to say, agree to, or ask…"
                              : "What should the email say?",
                      text: $brief, axis: .vertical)
                .lineLimit(3...8)
                .focused($briefFocused)
                .disabled(running)
            Button { write(notes: briefTrimmed, shown: shown) } label: {
                Label(isReply ? "Draft the reply" : "Write it", systemImage: "sparkles")
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(Theme.accent)
            .disabled(running || !AIAssist.canRun(mode: .write, typed: briefTrimmed, hasText: hasText, isReply: isReply))
        } footer: {
            Text(isReply
                 ? "Drafts an answer to the conversation; your notes steer it, or leave them empty. You review it before it replaces the message."
                 : "Writes the whole message from your brief. You review it before it replaces the message.")
        }
    }

    // MARK: Edit

    @ViewBuilder private func editSections(_ shown: AIStatus?) -> some View {
        Section {
            HStack {
                TextField("Tell the AI what to change…", text: $instruction)
                    .onSubmit { edit(instructionTrimmed, shown: shown) }
                    .disabled(running)
                Button { edit(instructionTrimmed, shown: shown) } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(running || !AIAssist.canRun(mode: .edit, typed: instructionTrimmed, hasText: hasText, isReply: isReply))
                    .accessibilityLabel("Apply the instruction")
            }
        } footer: {
            Text(hasSelection ? "Applies to the selected text." : "Applies to the whole message.")
        }
        Section("Edit") {
            ForEach(AIAssist.edits) { p in
                preset(p) { instruction in edit(instruction, shown: shown) }
            }
        }
        Section("Tone") {
            ForEach(AIAssist.tonesBeyondEdits) { p in
                preset(p) { instruction in edit(instruction, shown: shown) }
            }
        }
    }

    private func preset(_ p: AIAssist.Preset, run: @escaping (String) -> Void) -> some View {
        Button { run(p.instruction) } label: { Text(p.title) }
            .foregroundStyle(Theme.textPrimary)
            .disabled(running)
    }

    // MARK: Review

    /// The result, before it replaces anything: read it, dial the tone in
    /// (the tones chain), then use it or drop it.
    @ViewBuilder private func reviewSections(_ r: AIAssist.Outcome, shown: AIStatus?) -> some View {
        Section {
            Text(r.text)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
        } header: {
            Text(AIAssist.reviewTitle(r)).textCase(nil)
        }
        Section {
            Button { apply(r) } label: {
                Label(AIAssist.applyTitle(r), systemImage: "checkmark")
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(Theme.accent)
            .disabled(running)
            Button("Discard", role: .destructive) { runner.discard() }
                .disabled(running)
        }
        Section("Tone") {
            ForEach(AIAssist.tones) { tone in
                preset(tone) { instruction in
                    runner.refine(r, with: instruction, history: history, context: nil, shown: shown, in: model)
                }
            }
        }
    }

    // MARK: Requests

    private func edit(_ instruction: String, shown: AIStatus?) {
        guard !AIAssist.isBlank(instruction) else { return }
        runner.edit(instruction, text: text, hasSelection: hasSelection, history: history, context: nil,
                    shown: shown, in: model)
    }

    private func write(notes: String, shown: AIStatus?) {
        runner.write(notes: notes, subject: subject, history: history, context: nil, shown: shown, in: model)
    }

    private func apply(_ r: AIAssist.Outcome) {
        if r.written { onWrite(r.text) } else { onApply(r.text) }
        dismiss()
    }
}
