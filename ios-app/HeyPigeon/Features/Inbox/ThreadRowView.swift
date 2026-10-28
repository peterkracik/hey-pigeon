// One inbox row, three lines: sender · time, subject, two-line snippet —
// plus chips only when there is something to say. No avatar: the dot on the
// left is the unread mark, tinted with the account colour in the unified
// view; a read row has no dot at all.

import SwiftUI

struct ThreadRowView: View {
    let row: ThreadRow
    let showAccountDot: Bool
    @Environment(AppModel.self) private var model

    private var account: MailAccount? { model.accounts.first { $0.id == row.accountId } }

    private var dotColor: Color {
        guard !row.isRead else { return .clear }
        if showAccountDot, let a = account { return Theme.tagForeground(a.color) }
        return Theme.accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(dotColor).frame(width: 8, height: 8).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(row.fromSummary)
                    .font(Theme.sender(!row.isRead))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if row.isConversation {
                    Text("\(row.messageCount)").font(.caption.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 8)
                trailingMarks
                Text(timeText)
                    .font(.subheadline)
                    .foregroundStyle(row.isRead ? Theme.textTertiary : Theme.textSecondary)
                    .monospacedDigit()
            }
            Text(row.subject.isEmpty ? "(no subject)" : row.subject)
                .font(.body.weight(row.isRead ? .regular : .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .padding(.leading, 16)
            if !row.snippet.isEmpty {
                Text(row.snippet)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .padding(.leading, 16)
            }
            if row.priority != nil || row.hasAttachment {
                HStack(spacing: 6) {
                    if let p = row.priority, p != .spam {
                        Chip(text: p.rawValue, background: Theme.priorityColor(p).opacity(0.14), foreground: Theme.priorityColor(p))
                    }
                    if row.hasAttachment {
                        Chip(text: "attachment", systemImage: "paperclip", background: Theme.navy100, foreground: Theme.textSecondary)
                    }
                }
                .padding(.leading, 16).padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var timeText: String {
        if model.view == .scheduled, let at = row.scheduledAt { return Formatters.reminder(at) }
        return Formatters.rowTime(row.lastMessageAt)
    }

    /// Small marks next to the time, only when true.
    @ViewBuilder
    private var trailingMarks: some View {
        HStack(spacing: 6) {
            if row.scheduledAt != nil { mark(row.isFollowUp ? "clock.arrow.circlepath" : "clock") }
            if row.needsReply { mark("arrowshape.turn.up.left") }
            if row.isStarred { Image(systemName: "star.fill").font(.caption).foregroundStyle(Color(hex: 0xE3B341)) }
        }
    }

    private func mark(_ name: String) -> some View {
        Image(systemName: name).font(.caption).foregroundStyle(Theme.textTertiary)
    }
}

struct Chip: View {
    let text: String
    var systemImage: String? = nil
    let background: Color
    let foreground: Color

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.caption2) }
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
