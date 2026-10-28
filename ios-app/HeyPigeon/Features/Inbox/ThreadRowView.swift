// One inbox row, three lines: sender · time, subject, one-line snippet —
// plus chips only when there is something to say. No avatar: the dot on the
// left is the unread mark, tinted with the account colour in the unified
// view. Unread rows sit on the card surface in primary text; read rows sink
// into the canvas in the secondary tone, so the two states read at a glance.

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

    private var tone: Color { row.isRead ? Theme.textSecondary : Theme.textPrimary }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(dotColor).frame(width: 8, height: 8).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(row.fromSummary)
                    .font(Theme.sender(!row.isRead))
                    .foregroundStyle(tone)
                    .lineLimit(1)
                if row.isConversation {
                    Text("\(row.messageCount)").font(.caption.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 8)
                trailingMarks
                Text(timeText)
                    .font(.footnote)
                    .foregroundStyle(row.isRead ? Theme.textTertiary : Theme.textSecondary)
                    .monospacedDigit()
            }
            // Subject line carries the chips at its end: three lines per row,
            // about 86 pt, so six rows fit above the bars.
            HStack(spacing: 8) {
                Text(row.subject.isEmpty ? "(no subject)" : row.subject)
                    .font(.subheadline.weight(row.isRead ? .regular : .semibold))
                    .foregroundStyle(tone)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let p = row.priority, p != .spam {
                    Chip(text: p.rawValue, background: Theme.priorityColor(p).opacity(0.14), foreground: Theme.priorityColor(p))
                }
                ForEach(triageNames, id: \.self) { name in
                    Chip(text: name, background: Theme.navy100, foreground: Theme.textSecondary)
                }
                if row.hasAttachment {
                    Image(systemName: "paperclip").font(.caption2).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.leading, 16)
            if !row.snippet.isEmpty {
                Text(row.snippet)
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .padding(.leading, 16)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// Jev labels on the row, by name (at most two; the rest is in the thread).
    private var triageNames: [String] {
        row.triageLabelIds.prefix(2).compactMap { id in model.triageLabels.first { $0.id == id }?.name }
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
            if row.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(Theme.pin) }
            if row.isDone && model.view != .archive { mark("checkmark") }
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
            Text(text).font(.caption.weight(.semibold)).lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
