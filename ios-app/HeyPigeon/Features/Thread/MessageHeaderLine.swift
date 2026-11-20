// A message's header as the thread shows it: who it is from and when,
// then one line under it — the snippet while the message is closed, who
// it went to once it is open, by name where the thread knows it, with the
// row's own control at that line's end. The thread's rows (ThreadView's MessageRow)
// and the conversation inside the composer (ComposeThreadHistory) each
// drew it; they are the same message at the same sizes.
//
// It is drawn as a row of the list is (docs/specs/marker-look.md): the
// sender in bold under the highlighter while the message is unread, in
// bold ink while it is open, in the medium grey of a read row otherwise;
// the time and the facts under an open message (who it went to, where
// replies go, what became of it) in the mono.

import SwiftUI

struct MessageHeaderLine<Trailing: View>: View {
    let message: MessageItem
    let expanded: Bool
    /// In the thread itself: the time of an open or an unread message is
    /// ink (a read, closed one's is grey, as a row's is), an open message
    /// says where its replies go (docs/specs/reply-recipients.md), and
    /// the user's own sent message what became of it
    /// (docs/specs/read-status.md). The composer's history is for reading
    /// back, and shows none of these.
    var inThread = true
    /// The thread's people by address (`ThreadDetail.knownNames`), for
    /// the "to" line; an address it does not know is shown as it is.
    var names: [String: String] = [:]
    /// What ends the "to" line of an open message (the thread's •••).
    /// Not after the time: the times of open and closed messages then
    /// ended at two different right edges.
    @ViewBuilder let trailing: () -> Trailing

    /// The open message and the unread ones carry the thread; a closed
    /// message that was read steps back.
    private var stands: Bool { expanded || !message.isRead }

    var body: some View {
        // A closed message is a row of the list: 3 pt between its lines.
        VStack(alignment: .leading, spacing: expanded ? 2 : 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message.isMine ? "Me" : message.fromName)
                    .font(Theme.sender(stands))
                    .foregroundStyle(stands ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    // Unread is the highlighter, as on a row: no bar on
                    // the message's edge.
                    .marker(!message.isRead)
                Spacer(minLength: 8)
                Text(expanded ? Formatters.messageTime(message.date) : Formatters.rowTime(message.date))
                    .font(Theme.meta)
                    .foregroundStyle(inThread && stands ? Theme.textPrimary : Theme.textTertiary)
                    .monospacedDigit()
                    // The whole date, for the pointer and for VoiceOver.
                    .help(Formatters.fullDate(message.date))
                    .accessibilityLabel(Formatters.fullDate(message.date))
            }
            if expanded {
                HStack(spacing: 8) {
                    Text("to \(ThreadDetail.recipientLine(message.to, names: names))")
                        .font(Theme.tag).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    Spacer(minLength: 0)
                    // Taller than the line it ends: it overhangs it, so
                    // the header keeps its height.
                    trailing().padding(.vertical, -4)
                }
                // The sender asked for replies elsewhere: said here, not
                // first in the composer's To field.
                if inThread, !message.repliesGoTo.isEmpty {
                    Text("replies go to \(message.repliesGoTo.joined(separator: ", "))")
                        .font(Theme.tag).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
                // What became of the user's own sent message
                // (docs/specs/read-status.md): sent, bounced, delivered to
                // a device that hides opens, opened or answered — and
                // under it what the relay reported, when that says more.
                // A state, so a glyph and a few words: quiet, but in the
                // danger colour and the medium when the message did not
                // arrive, which is news.
                if inThread, let status = message.readStatus {
                    let recipients = message.to + message.cc
                    let failed = status.state == .notDelivered
                    StateMark(text: ReadStatusText.line(status, recipients: recipients, names: names),
                              systemImage: ReadStatusText.symbol(status.state),
                              tint: failed ? Theme.dangerText : Theme.textTertiary,
                              weight: failed ? .medium : .regular)
                    // By position: two fetches in the same minute read alike.
                    let details = ReadStatusText.details(status, recipients: recipients)
                    ForEach(details.indices, id: \.self) { index in
                        Text(details[index]).font(Theme.tag).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
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
