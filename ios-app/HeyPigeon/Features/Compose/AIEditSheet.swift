// The desktop AiEditPopover, plus a Write mode. Edit: tone presets, edit
// presets, or a freeform instruction, run against the selection or the
// whole body. Write: a brief the AI turns into the whole message — a reply
// goes through the desktop's "Draft with AI" (the brief steers it as notes),
// a new message through the edit endpoint with a compose instruction. The
// sheet opens in Write when the body is empty. Content leaves the device on
// an explicit tap only.

import SwiftUI

struct AIEditSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case write = "Write", edit = "Edit"
        var id: String { rawValue }
    }

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
    @State private var mode: Mode
    @State private var brief = ""
    @State private var instruction = ""
    @State private var running: String?
    @State private var error: String?
    @FocusState private var briefFocused: Bool

    init(text: String, hasSelection: Bool, subject: String, history: String?,
         onApply: @escaping (String) -> Void, onWrite: @escaping (String) -> Void) {
        self.text = text
        self.hasSelection = hasSelection
        self.subject = subject
        self.history = history
        self.onApply = onApply
        self.onWrite = onWrite
        _mode = State(initialValue: Self.isBlank(text) ? .write : .edit)
    }

    private static let tone: [(String, String)] = [
        ("Warmer", "Make the tone warmer and friendlier, without changing the meaning."),
        ("More formal", "Make the tone more formal and professional, without changing the meaning."),
        ("More casual", "Make the tone more casual and relaxed, without changing the meaning."),
        ("More confident", "Make the tone more confident and direct, without changing the meaning."),
        ("Softer", "Soften the tone — more polite and less blunt — without changing the meaning."),
        ("More concise", "Make it more concise without losing the key points."),
    ]
    private static let edits: [(String, String)] = [
        ("Fix grammar", "Fix grammar and spelling mistakes. Keep the meaning and tone unchanged."),
        ("Reformulate", "Rewrite this more clearly, keeping the same meaning and roughly the same length."),
        ("Shorten", "Make this more concise without losing the key points."),
        ("Expand", "Expand this with a bit more detail and context."),
        ("More formal", "Rewrite this in a more formal, professional tone."),
        ("More casual", "Rewrite this in a more casual, friendly tone."),
    ]
    /// `running` value for the Write action (presets use their instruction).
    private static let writeRun = "\u{0}write"

    private static func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasText: Bool { !Self.isBlank(text) }
    /// A reply: the thread transcript is there to draft against.
    private var isReply: Bool { !Self.isBlank(history ?? "") }
    private var briefTrimmed: String { brief.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            List {
                if hasText {
                    Section {
                        Picker("Mode", selection: $mode) {
                            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                switch mode {
                case .write: writeSections
                case .edit: editSections
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle(mode == .write ? "Write with AI" : "Edit with AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .disabled(running != nil)
            .overlay { if running != nil { ProgressView("Working…").padding(20).glassEffect() } }
            .onAppear { if mode == .write { briefFocused = true } }
        }
    }

    // MARK: Write

    @ViewBuilder private var writeSections: some View {
        Section {
            TextField(isReply ? "Notes for the reply — what to say, agree to, or ask…"
                              : "What should the email say?",
                      text: $brief, axis: .vertical)
                .lineLimit(3...8)
                .focused($briefFocused)
            Button { write() } label: {
                HStack {
                    Label(isReply ? "Draft the reply" : "Write it", systemImage: "sparkles")
                        .font(.body.weight(.semibold))
                    Spacer()
                    if running == Self.writeRun { ProgressView() }
                }
            }
            .foregroundStyle(Theme.accent)
            .disabled((briefTrimmed.isEmpty && !isReply) || running != nil)
        } footer: {
            Text(isReply
                 ? "Drafts an answer to the conversation; your notes steer it, or leave them empty. Replaces the message body."
                 : "Writes the whole message from your brief. Replaces the message body.")
        }
    }

    // MARK: Edit

    @ViewBuilder private var editSections: some View {
        Section {
            HStack {
                TextField("Tell the AI what to change…", text: $instruction)
                    .onSubmit { run(instruction) }
                Button { run(instruction) } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(instruction.trimmingCharacters(in: .whitespaces).isEmpty || running != nil)
            }
        } footer: {
            Text(hasSelection ? "Applies to the selected text." : "Applies to the whole message.")
        }
        Section("Tone") { ForEach(Self.tone, id: \.0) { preset($0) } }
        Section("Edit") { ForEach(Self.edits, id: \.0) { preset($0) } }
    }

    private func preset(_ p: (String, String)) -> some View {
        Button { run(p.1) } label: {
            HStack { Text(p.0); Spacer(); if running == p.1 { ProgressView() } }
        }
        .foregroundStyle(Theme.textPrimary)
    }

    // MARK: Requests

    private func run(_ instruction: String) {
        guard hasText else { error = "Nothing to edit"; return }
        running = instruction
        error = nil
        Task {
            do {
                let result = try await model.engine.aiEditText(instruction: instruction, text: text, history: history)
                onApply(result)
                dismiss()
            } catch { self.error = error.localizedDescription }
            running = nil
        }
    }

    private func write() {
        let notes = briefTrimmed
        running = Self.writeRun
        error = nil
        Task {
            do {
                let result: String
                if isReply, let history {
                    result = try await model.engine.aiDraftReply(subject: subject, history: history, notes: notes.isEmpty ? nil : notes)
                } else {
                    result = try await model.engine.aiEditText(instruction: Self.writeInstruction(subject: subject), text: notes, history: nil)
                }
                onWrite(result)
                dismiss()
            } catch { self.error = error.localizedDescription }
            running = nil
        }
    }

    /// Opening words of the compose instruction (MockEngine keys on them).
    static let writePrefix = "Write a complete email from the brief below"

    /// The edit endpoint doubles as the writer for a new message: the brief
    /// is the "text", and the instruction asks for a whole email built from
    /// it, with the same guardrails as the desktop's draft-reply prompt.
    static func writeInstruction(subject: String) -> String {
        var s = writePrefix + ", in the first person as the sender. "
        let subj = subject.trimmingCharacters(in: .whitespaces)
        if !subj.isEmpty { s += "The subject line is \"\(subj)\". " }
        s += "Be concise and natural. Never invent facts, dates, or commitments the brief does not support — put a short placeholder in square brackets where the sender must fill something in. Return ONLY the email body as plain text: no subject line, no markdown, and no signature block (the sender's signature is added separately)."
        return s
    }
}
