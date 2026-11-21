// The desktop AiEditPopover, plus a Write mode, as the phone's sheet over
// the shared assistant (AIAssist.swift: the presets, the requests, the
// runner). Edit: the presets, a tone, or a freeform instruction, run
// against the selection or the whole body. Write: a brief the AI turns
// into the whole message — a reply goes through the desktop's "Draft with
// AI" (the brief steers it as notes), a new message through the engine's
// write call. The sheet opens in Write when the body is empty.
//
// A request can always be cancelled and gives up after `AIAssist.timeout`,
// and its result is shown for review — refined with a tone, discarded, or
// applied — before it replaces anything, as on the Mac. The sheet used to
// lock itself (Cancel too) until the provider answered and then replaced
// the text at once, with nothing to take it back. Content leaves the
// device on an explicit tap only; the footer says what and to whom.
//
// A menu sheet on the raised paper (docs/specs/marker-look.md): the
// presets are ruled rows under their titles ("Edit", "Tone"), the
// instruction's field has an ink underline and no fill, the brief — a
// text of several lines — a box with an outline, and the only pink is
// the AI's sparkle.

import SwiftUI

struct AIEditSheet: View {
    /// The selection, or the body without the signature.
    let text: String
    let hasSelection: Bool
    let subject: String
    let history: String?
    /// Who writes to whom, as the Mac's panel sends it: without it the
    /// model did not know whose words the draft was or whom to address.
    let context: AIWriteContext?
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

    init(text: String, hasSelection: Bool, subject: String, history: String?, context: AIWriteContext? = nil,
         onApply: @escaping (String) -> Void, onWrite: @escaping (String) -> Void) {
        self.text = text
        self.hasSelection = hasSelection
        self.subject = subject
        self.history = history
        self.context = context
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

    /// What a tap sends and to whom (AIAssist.footnote), the composer's
    /// AIWriteContext included when it gave one. `shown` is the body's one read of who answers,
    /// the same value every button of that pass hands the runner: a sync
    /// can change the active provider while the sheet is up, and the core
    /// then refuses the request rather than send it under this sentence.
    private func footnote(_ shown: AIStatus?) -> String {
        AIAssist.footnote(mode: mode, isReply: isReply, sendsWriter: context != nil,
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
                        // No line of the list's own over or under the
                        // control (`menuCard` says why).
                        .listSectionSeparator(.hidden)
                    }
                    switch mode {
                    case .write: writeSections(shown)
                    case .edit: editSections(shown)
                    }
                }
                if running { workingSection }
                if let error = runner.error {
                    Section { Text(error).foregroundStyle(Theme.dangerText).font(Theme.sans(.footnote)) }
                        .menuCard()
                }
                // What a tap sends, and to whom: a footer with no rows.
                Section {
                    EmptyView()
                } footer: {
                    Text(footnote(shown)).font(Self.footerFont).foregroundStyle(Theme.textTertiary)
                }
                .listSectionSeparator(.hidden)
            }
            // The menu sheets' list: the raised paper, ruled rows, no cards.
            .menuList()
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

    /// A row of the sheet: a menu row's medium.
    private static let rowFont = Theme.sans(.callout, .medium)
    /// What is said under a section, and the privacy line: the footer's
    /// size in the tertiary grey.
    private static let footerFont = Theme.sans(.footnote)

    /// The request that is out: said in words, with the way to stop it.
    private var workingSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView()
                Text("Working…").font(Self.rowFont).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Cancel request") { runner.cancel() }
                    .font(Theme.sans(.subheadline, .semibold))
            }
        }
        .menuCard()
    }

    // MARK: Write

    @ViewBuilder private func writeSections(_ shown: AIStatus?) -> some View {
        Section {
            TextField(isReply ? "Notes for the reply — what to say, agree to, or ask…"
                              : "What should the email say?",
                      text: $brief, axis: .vertical)
                .font(Theme.sans(.callout))
                .lineLimit(3...8)
                .focused($briefFocused)
                .disabled(running)
                // A text of several lines: no fill, a box with an outline.
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.outline, lineWidth: 1))
            // The AI's own row: its sparkle is the sheet's one pink, its
            // words are ink.
            Button { write(notes: briefTrimmed, shown: shown) } label: {
                Label {
                    Text(isReply ? "Draft the reply" : "Write it").font(Theme.sans(.callout, .semibold))
                } icon: {
                    Image(systemName: "sparkles").foregroundStyle(Theme.pinkInk)
                }
            }
            .foregroundStyle(Theme.textPrimary)
            .disabled(running || !AIAssist.canRun(mode: .write, typed: briefTrimmed, hasText: hasText, isReply: isReply))
        } footer: {
            Text(isReply
                 ? "Drafts an answer to the conversation; your notes steer it, or leave them empty. You review it before it replaces the message."
                 : "Writes the whole message from your brief. You review it before it replaces the message.")
                .font(Self.footerFont).foregroundStyle(Theme.textTertiary)
        }
        .menuCard()
    }

    // MARK: Edit

    @ViewBuilder private func editSections(_ shown: AIStatus?) -> some View {
        Section {
            // The instruction's field: no fill, an ink underline.
            VStack(spacing: 8) {
                HStack {
                    TextField("Tell the AI what to change…", text: $instruction)
                        .font(Theme.sans(.callout))
                        .onSubmit { edit(instructionTrimmed, shown: shown) }
                        .disabled(running)
                    // An ink circle once there is something to send.
                    Button { edit(instructionTrimmed, shown: shown) } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .tint(Theme.textPrimary)
                        .disabled(running || !AIAssist.canRun(mode: .edit, typed: instructionTrimmed, hasText: hasText, isReply: isReply))
                        .accessibilityLabel("Apply the instruction")
                }
                Rectangle().fill(Theme.textPrimary).frame(height: 1)
            }
        } footer: {
            Text(hasSelection ? "Applies to the selected text." : "Applies to the whole message.")
                .font(Self.footerFont).foregroundStyle(Theme.textTertiary)
        }
        .menuCard()
        Section {
            ForEach(AIAssist.edits) { p in
                preset(p) { instruction in edit(instruction, shown: shown) }
            }
        } header: {
            SectionTitle("Edit")
        }
        .menuCard()
        Section {
            ForEach(AIAssist.tonesBeyondEdits) { p in
                preset(p) { instruction in edit(instruction, shown: shown) }
            }
        } header: {
            SectionTitle("Tone")
        }
        .menuCard()
    }

    /// One preset: a ruled row, its name in ink.
    private func preset(_ p: AIAssist.Preset, run: @escaping (String) -> Void) -> some View {
        Button { run(p.instruction) } label: { Text(p.title).font(Self.rowFont) }
            .foregroundStyle(Theme.textPrimary)
            .disabled(running)
    }

    // MARK: Review

    /// The result, before it replaces anything: read it, dial the tone in
    /// (the tones chain), then use it or drop it.
    @ViewBuilder private func reviewSections(_ r: AIAssist.Outcome, shown: AIStatus?) -> some View {
        Section {
            Text(r.text)
                .font(Theme.sans(.body))
                .lineSpacing(4)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
        } header: {
            Text(AIAssist.reviewTitle(r)).font(Self.footerFont).foregroundStyle(Theme.textTertiary).textCase(nil)
        }
        .menuCard()
        Section {
            // Using it is the page's action: ink. Dropping it is the
            // danger colour, as writing.
            Button { apply(r) } label: {
                Label(AIAssist.applyTitle(r), systemImage: "checkmark")
                    .font(Theme.sans(.callout, .semibold))
            }
            .foregroundStyle(Theme.textPrimary)
            .disabled(running)
            Button(role: .destructive) { runner.discard() } label: {
                // Said on the words themselves: the role's own red is
                // the system's, not the app's danger colour.
                Text("Discard").font(Self.rowFont).foregroundStyle(Theme.dangerText)
            }
            .disabled(running)
        }
        .menuCard()
        Section {
            ForEach(AIAssist.tones) { tone in
                preset(tone) { instruction in
                    runner.refine(r, with: instruction, history: history, context: context, shown: shown, in: model)
                }
            }
        } header: {
            SectionTitle("Tone")
        }
        .menuCard()
    }

    // MARK: Requests

    private func edit(_ instruction: String, shown: AIStatus?) {
        guard !AIAssist.isBlank(instruction) else { return }
        runner.edit(instruction, text: text, hasSelection: hasSelection, history: history, context: context,
                    shown: shown, in: model)
    }

    private func write(notes: String, shown: AIStatus?) {
        runner.write(notes: notes, subject: subject, history: history, context: context, shown: shown, in: model)
    }

    private func apply(_ r: AIAssist.Outcome) {
        if r.written { onWrite(r.text) } else { onApply(r.text) }
        dismiss()
    }
}
