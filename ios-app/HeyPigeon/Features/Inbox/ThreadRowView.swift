// One inbox row, three lines: sender · time, subject, one-line snippet —
// plus chips only when there is something to say. No avatar, no indent:
// the unread mark is the bar on the row's left edge (InboxView) and the
// bold sender; in the unified view the account shows as a small dot
// before the time.

import SwiftUI

struct ThreadRowView: View {
    let row: ThreadRow
    let showAccountDot: Bool
    @Environment(AppModel.self) private var model

    private var account: MailAccount? { model.accounts.first { $0.id == row.accountId } }

    private var tone: Color { Theme.textPrimary }

    private var senderText: Text {
        let name = row.fromSummary
        guard showAccountDot, let a = account, let first = name.first else {
            return Text(name).foregroundStyle(tone)
        }
        return Text(String(first)).foregroundStyle(Theme.tagForeground(a.color))
            + Text(name.dropFirst()).foregroundStyle(tone)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Unified view: the sender's first letter takes the account
                // colour. Nothing is added to the row; the mark sits where the
                // eye lands first.
                senderText
                    .font(Theme.sender(!row.isRead))
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
                if let p = row.priority { PriorityIndicator(priority: p) }
                ForEach(triageNames, id: \.self) { name in
                    Chip(text: name, background: Theme.sunken, foreground: Theme.textSecondary)
                }
                if row.hasAttachment {
                    Image(systemName: "paperclip").font(.caption2).foregroundStyle(Theme.textTertiary)
                }
            }
            if !row.snippet.isEmpty {
                Text(row.snippet)
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
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

/// Jev priority, the desktop's indicator: three short bars (1 lit = low,
/// 2 = medium, 3 = high; high in the alert colour), spam a blocked circle.
struct PriorityIndicator: View {
    let priority: TriageLevel

    var body: some View {
        if priority == .spam {
            Image(systemName: "circle.slash").font(.caption2.weight(.bold)).foregroundStyle(Theme.textTertiary)
                .accessibilityLabel("Likely spam")
        } else {
            let level = priority == .high ? 3 : priority == .medium ? 2 : 1
            let lit = priority == .high ? Theme.tagForeground(.coral) : Theme.tagForeground(.amber)
            VStack(spacing: 2) {
                ForEach(1...3, id: \.self) { bar in
                    RoundedRectangle(cornerRadius: 1).fill(bar > 3 - level ? lit : Theme.navy200).frame(width: 11, height: 2)
                }
            }
            .accessibilityLabel("Priority \(priority.rawValue)")
        }
    }
}
