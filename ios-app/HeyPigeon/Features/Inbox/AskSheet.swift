// "Ask my inbox": a question field, the answer streaming in, and the
// threads it rests on listed under it, tappable. Reached from the inbox
// toolbar and from the Ask intent. Everything runs on this device; the
// footer says so, and the sheet is only offered while the Spotlight index
// is on (Settings › Siri & Search).
//
// On the raised paper (docs/specs/marker-look.md): an answer opens under
// its title (the pink sparkle, "Answer" and a rule in the light grey of
// structure), the mail it rests on is a ruled row like the inbox's, and
// the field's send button is ink once there is something to ask.

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
                            } retry: {
                                // The same question again, in the failed one's place.
                                if conversations.indices.contains(i) {
                                    conversations[i] = InboxAsk.ask(c.question, model: model)
                                }
                            }
                            .id(i)
                        }
                        Text("Answered on this \(Device.name) from the index Siri uses. Nothing is sent anywhere.")
                            .font(Theme.secondary).foregroundStyle(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 20)
                }
                .onChange(of: conversations.count) { _, n in
                    withAnimation { proxy.scrollTo(n - 1, anchor: .top) }
                }
            }
            // A sheet stands on the raised paper.
            .background(Theme.raised)
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
                .font(Theme.text(.row)).foregroundStyle(Theme.textSecondary)
            // A question to try is a boxed chip: an outline, no fill.
            ForEach(Self.suggestions, id: \.self) { s in
                Button { question = s; ask() } label: {
                    Text(s).font(Theme.text(.bodySmall, .medium)).foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.outline, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The question's field, floating over the answers on the system's
    /// glass. Its send button is ink once there is something to ask (a
    /// faint ink until then), with the paper's colour for its arrow.
    private var field: some View {
        HStack(spacing: 10) {
            TextField("Ask about your mail…", text: $question, axis: .vertical)
                .font(Theme.sans(.body))
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit { ask() }
                .submitLabel(.send)
            Button { ask() } label: {
                Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(Theme.onPrimary)
                    .frame(width: 34, height: 34)
                    .background(Theme.textPrimary.opacity(canAsk ? 1 : 0.3), in: Circle())
                    .tapArea(horizontal: 5, vertical: 5)
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
    /// Asks the question again after a failure.
    let retry: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(conversation.question)
                .font(Theme.text(.bodySmall, .semibold)).foregroundStyle(Theme.textSecondary)
            // What the AI answers opens under its title.
            SectionTitle("Answer", systemImage: "sparkles")
            // An error wins over a partial answer, as before.
            ResultState(working: "Looking through your mail…", error: conversation.error,
                        isReady: conversation.error == nil && !conversation.answer.isEmpty, retry: retry) {
                SummaryTextView(text: conversation.answer)
                    .font(Theme.text(.row)).lineSpacing(4).foregroundStyle(Theme.textPrimary)
            }
            if !conversation.citations.isEmpty {
                // The mail an answer rests on: ruled rows, as in the
                // inbox — a hairline over the first, between two and
                // under the last, and no card around them.
                VStack(spacing: 0) {
                    RowRule()
                    ForEach(conversation.citations) { row in
                        Button { open(row) } label: {
                            ThreadRowView(row: row, showAccountDot: model.accounts.count > 1)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        RowRule()
                    }
                }
                .padding(.top, 6)
            }
        }
    }
}
