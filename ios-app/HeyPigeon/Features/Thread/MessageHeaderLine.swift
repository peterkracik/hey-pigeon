// A message's header as the thread shows it: who it is from and when,
// then one line under it — the snippet while the message is closed, who
// it went to once it is open. The thread's rows (ThreadView's MessageRow)
// and the conversation inside the composer (ComposeThreadHistory) each
// drew it; they are the same message at the same sizes.

import SwiftUI

struct MessageHeaderLine<Trailing: View>: View {
    let message: MessageItem
    let expanded: Bool
    /// In the thread itself: an unread message's time is a step darker,
    /// and an open message says where its replies go
    /// (docs/specs/reply-recipients.md). The composer's history is for
    /// reading back, and shows neither.
    var inThread = true
    /// What sits after the time (the thread's ••• on an open message).
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message.isMine ? "Me" : message.fromName)
                    .font(Theme.sender(!message.isRead))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(expanded ? Formatters.fullDate(message.date) : Formatters.rowTime(message.date))
                    .font(.footnote)
                    .foregroundStyle(inThread && !message.isRead ? Theme.textSecondary : Theme.textTertiary)
                    .monospacedDigit()
                trailing()
            }
            if expanded {
                Text("to \(message.to.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                // The sender asked for replies elsewhere: said here, not
                // first in the composer's To field.
                if inThread, !message.repliesGoTo.isEmpty {
                    Text("replies go to \(message.repliesGoTo.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
            } else {
                Text(message.snippet).font(.footnote).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

extension MessageHeaderLine where Trailing == EmptyView {
    /// The header with nothing after the time.
    init(message: MessageItem, expanded: Bool, inThread: Bool = true) {
        self.init(message: message, expanded: expanded, inThread: inThread) { EmptyView() }
    }
}
