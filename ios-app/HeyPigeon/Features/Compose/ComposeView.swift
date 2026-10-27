// Compose / reply / forward. Plain text in iOS-M1; the AI bar and rich
// text follow (docs/ios.md). Sends through the outbox like everything else.

import SwiftUI

struct ComposeView: View {
    @State private var draft: SendDraft
    @State private var fromId: String
    @State private var toText: String
    @State private var sending = false
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?

    private enum Field { case to, subject, body }

    init(draft: SendDraft) {
        _draft = State(initialValue: draft)
        _toText = State(initialValue: draft.to.joined(separator: ", "))
        _fromId = State(initialValue: "")
    }

    private var canSend: Bool {
        !toText.trimmingCharacters(in: .whitespaces).isEmpty && !sending && !fromId.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if model.accounts.count > 1 {
                        Picker("From", selection: $fromId) {
                            ForEach(model.accounts) { a in Text(a.email).tag(a.id) }
                        }
                    }
                    TextField("To", text: $toText)
                        .textContentType(.emailAddress).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focus, equals: .to)
                    TextField("Subject", text: $draft.subject).focused($focus, equals: .subject)
                }
                Section {
                    TextEditor(text: $draft.bodyText)
                        .frame(minHeight: 220)
                        .focused($focus, equals: .body)
                }
            }
            .navigationTitle(draft.replyToThreadId == nil ? "New message" : "Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { send() } label: { Image(systemName: "paperplane.fill") }
                        .disabled(!canSend)
                        .accessibilityLabel("Send")
                }
            }
            .onAppear {
                if fromId.isEmpty {
                    // Replies go out from the account that received the thread.
                    let receiving = draft.replyToThreadId.flatMap { id in model.rows.first { $0.id == id }?.accountId }
                    fromId = receiving ?? model.selectedAccountId ?? model.accounts.first?.id ?? ""
                    if draft.bodyText.isEmpty, let sig = model.accounts.first(where: { $0.id == fromId })?.signature, !sig.isEmpty {
                        draft.bodyText = "\n\n\(sig)"
                    }
                }
                focus = draft.to.isEmpty ? .to : .body
            }
        }
        .interactiveDismissDisabled(!draft.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func send() {
        sending = true
        var d = draft
        d.to = toText.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
        let from = fromId
        dismiss()
        Task { await model.send(d, from: from) }
    }
}
