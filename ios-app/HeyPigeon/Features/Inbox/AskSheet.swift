// "Ask my inbox": a question field, the answer streaming in, and the
// threads it rests on listed under it, tappable. Reached from the inbox
// toolbar and from the Ask intent. Everything runs on this device; the
// footer says so, and the sheet is only offered while the Spotlight index
// is on (Settings › Siri & Search).

import SwiftUI

struct AskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var question: String
    @State private var conversations: [InboxAskConversation] = []
    @FocusState private var focused: Bool

    init(question: String? = nil) {
        _question = State(initialValue: question ?? "")
    }

    private static let suggestions = [
        "What's waiting on me this week?",
        "When is my next flight?",
        "Anything from the landlord about the deposit?",
        "Which invoices are due?",
    ]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if conversations.isEmpty { starter }
                        ForEach(Array(conversations.enumerated()), id: \.offset) { i, c in
                            ConversationView(conversation: c) { row in
                                dismiss()
                                model.openThread(id: row.id)
                            }
                            .id(i)
                        }
                        Text("Answered on this \(Device.name) from the index Siri uses. Nothing is sent anywhere.")
                            .font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
                .onChange(of: conversations.count) { _, n in
                    withAnimation { proxy.scrollTo(n - 1, anchor: .top) }
                }
            }
            .background(Theme.canvas)
            .safeAreaInset(edge: .bottom) { field }
            .navigationTitle("Ask my inbox")
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                if !question.trimmingCharacters(in: .whitespaces).isEmpty { ask() } else { focused = true }
            }
        }
        .sheetSize(.large)
    }

    private var starter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about your own mail — who said what, when something is, what is still open.")
                .font(.body).foregroundStyle(Theme.textSecondary)
            ForEach(Self.suggestions, id: \.self) { s in
                Button { question = s; ask() } label: {
                    Text(s).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            TextField("Ask about your mail…", text: $question, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit { ask() }
                .submitLabel(.send)
            Button { ask() } label: {
                Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Theme.accent.opacity(canAsk ? 0.9 : 0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canAsk)
            .accessibilityLabel("Ask")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var canAsk: Bool {
        !question.trimmingCharacters(in: .whitespaces).isEmpty && !(conversations.last?.isAnswering ?? false)
    }

    private func ask() {
        guard canAsk else { return }
        let q = question.trimmingCharacters(in: .whitespaces)
        question = ""
        conversations.append(InboxAsk.ask(q, model: model))
    }
}

private struct ConversationView: View {
    let conversation: InboxAskConversation
    let open: (ThreadRow) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(conversation.question)
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            if let error = conversation.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
            } else if conversation.answer.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Looking through your mail…").font(.body).foregroundStyle(Theme.textSecondary)
                }
            } else {
                SummaryTextView(text: conversation.answer).font(.body).foregroundStyle(Theme.textPrimary)
            }
            if !conversation.citations.isEmpty {
                VStack(spacing: 1) {
                    ForEach(conversation.citations) { row in
                        Button { open(row) } label: {
                            ThreadRowView(row: row, showAccountDot: model.accounts.count > 1)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Theme.card)
                    }
                }
                .background(Theme.separator.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}
