// The conversation a reply continues, inside the composer. The Mac shows
// it above the draft, so the reply reads as the end of the thread
// (ComposeMac.swift); the phone shows it under the editor, where Mail and
// Gmail keep the original — the reply sheet used to cover the thread and
// show nothing of the message being answered. Replies are sent without a
// quote (Gmail threads them); on the phone "Quote in reply" puts the
// latest message into the text for answering between its lines.

import SwiftUI

/// The thread of a reply: optionally the subject, then each message as the
/// thread view shows it — one line collapsed, the latest open. Loads what
/// the store has at once and the full thread after.
struct ComposeThreadHistory: View {
    let threadId: String
    /// The subject over the messages: the Mac's reply folds its Subject
    /// field away, the phone's shows it right above.
    var showsSubject = true
    /// Quotes a message into the draft; nil offers no "Quote in reply".
    var onQuote: ((MessageItem) -> Void)?
    /// The thread once it is here (the composer names recipients from it).
    let onLoad: (ThreadDetail) -> Void
    @Environment(AppModel.self) private var model
    @State private var detail: ThreadDetail?
    /// Both reads are over: without a thread there is nothing to wait for
    /// (offline, with the thread not in the store).
    @State private var loaded = false
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let detail {
                let mail = detail.mail
                if showsSubject {
                    let subject = detail.thread.subject
                    Text(subject.isEmpty ? "(no subject)" : subject)
                        .font(Theme.display(20, relativeTo: .title2))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
                }
                if let onQuote, let last = mail.last {
                    HStack {
                        Text(mail.count == 1 ? "Replying to" : "Conversation")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Button { onQuote(last) } label: {
                            Label("Quote in reply", systemImage: "text.quote")
                                .font(.footnote.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .accessibilityHint("Adds the latest message to your reply as quoted text")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
                VStack(spacing: 1) {
                    ForEach(Array(mail.enumerated()), id: \.element.id) { index, m in
                        HistoryMessageRow(message: m, expanded: expanded.contains(m.id) || index == mail.count - 1) {
                            if expanded.contains(m.id) { expanded.remove(m.id) } else { expanded.insert(m.id) }
                        }
                    }
                }
                .background(Theme.separator.opacity(0.6))
            } else if !loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 24)
            }
        }
        .task(id: threadId) {
            if let local = try? model.engine.threadLocal(id: threadId), !local.mail.isEmpty {
                detail = local
                onLoad(local)
            }
            if let fresh = try? await model.engine.thread(id: threadId), !fresh.mail.isEmpty {
                detail = fresh
                onLoad(fresh)
            }
            loaded = true
        }
    }
}

/// One message of the history: sender · time and a snippet line; open, the
/// recipients and the body. The thread view's row without its actions.
private struct HistoryMessageRow: View {
    let message: MessageItem
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(message.isMine ? "Me" : message.fromName)
                            .font(Theme.sender(!message.isRead))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(expanded ? Formatters.fullDate(message.date) : Formatters.rowTime(message.date))
                            .font(.footnote)
                            .foregroundStyle(Theme.textTertiary)
                            .monospacedDigit()
                    }
                    if expanded {
                        Text("to \(message.to.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    } else {
                        Text(message.snippet).font(.footnote).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                MessageBodyView(html: message.bodyHTML, text: message.bodyText ?? message.snippet,
                                senderAddress: message.fromAddress)
                    .padding(.top, 12)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, expanded ? 12 : 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(expanded ? Theme.card : Theme.canvas)
    }
}
