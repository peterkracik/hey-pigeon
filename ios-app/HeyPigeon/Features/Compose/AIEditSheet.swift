// The desktop AiEditPopover: tone presets, edit presets, or a freeform
// instruction, run against the selection or the whole body on an explicit
// tap (content leaves the device on user action only).

import SwiftUI

struct AIEditSheet: View {
    let text: String
    let hasSelection: Bool
    let history: String?
    let onApply: (String) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var instruction = ""
    @State private var running: String?
    @State private var error: String?

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

    var body: some View {
        NavigationStack {
            List {
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
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("Edit with AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .disabled(running != nil)
            .overlay { if running != nil { ProgressView("Working…").padding(20).glassEffect() } }
        }
    }

    private func preset(_ p: (String, String)) -> some View {
        Button { run(p.1) } label: {
            HStack { Text(p.0); Spacer(); if running == p.1 { ProgressView() } }
        }
        .foregroundStyle(Theme.textPrimary)
    }

    private func run(_ instruction: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { error = "Nothing to edit"; return }
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
}
