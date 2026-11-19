// A message's header as the thread shows it: who it is from and when,
// then one line under it — the snippet while the message is closed, who
// it went to once it is open, by name where the thread knows it, with the
// row's own control at that line's end. The thread's rows (ThreadView's MessageRow)
// and the conversation inside the composer (ComposeThreadHistory) each
// drew it; they are the same message at the same sizes.

import SwiftUI

struct MessageHeaderLine<Trailing: View>: View {
    let message: MessageItem
    let expanded: Bool
    /// In the thread itself: an unread message's time is a step darker,
    /// an open message says where its replies go
    /// (docs/specs/reply-recipients.md), and the user's own sent message
    /// what became of it (docs/specs/read-status.md). The composer's
    /// history is for reading back, and shows none of these.
    var inThread = true
    /// The thread's people by address (`ThreadDetail.knownNames`), for
    /// the "to" line; an address it does not know is shown as it is.
    var names: [String: String] = [:]
    /// What ends the "to" line of an open message (the thread's •••).
    /// Not after the time: the times of open and closed messages then
    /// ended at two different right edges.
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message.isMine ? "Me" : message.fromName)
                    .font(Theme.sender(!message.isRead))
                    // A closed message that was read steps back; the
                    // open one and the unread ones carry the thread.
                    .foregroundStyle(expanded || !message.isRead ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(expanded ? Formatters.messageTime(message.date) : Formatters.rowTime(message.date))
                    .font(Theme.meta)
                    .foregroundStyle(inThread && !message.isRead ? Theme.textSecondary : Theme.textTertiary)
                    .monospacedDigit()
                    // The whole date, for the pointer and for VoiceOver.
                    .help(Formatters.fullDate(message.date))
                    .accessibilityLabel(Formatters.fullDate(message.date))
            }
            if expanded {
                HStack(spacing: 8) {
                    Text("to \(ThreadDetail.recipientLine(message.to, names: names))")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    Spacer(minLength: 0)
                    // Taller than the line it ends: it overhangs it, so
                    // the header keeps its height.
                    trailing().padding(.vertical, -4)
                }
                // The sender asked for replies elsewhere: said here, not
                // first in the composer's To field.
                if inThread, !message.repliesGoTo.isEmpty {
                    Text("replies go to \(message.repliesGoTo.joined(separator: ", "))")
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
                // What became of the user's own sent message
                // (docs/specs/read-status.md): sent, bounced or answered.
                if inThread, let status = message.readStatus {
                    Label(ReadStatusText.line(status), systemImage: ReadStatusText.symbol(status.state))
                        .font(Theme.caption)
                        .foregroundStyle(status.state == .notDelivered ? Theme.dangerText : Theme.textTertiary)
                        .lineLimit(1)
                }
            } else {
                Text(message.snippet).font(Theme.secondary).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

extension MessageHeaderLine where Trailing == EmptyView {
    /// The header with nothing at the end of its "to" line.
    init(message: MessageItem, expanded: Bool, inThread: Bool = true, names: [String: String] = [:]) {
        self.init(message: message, expanded: expanded, inThread: inThread, names: names) { EmptyView() }
    }
}
