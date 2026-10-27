// One inbox row. Typography does the work: sender · time, then subject ·
// snippet on one line, badges only when true.

import SwiftUI

struct ThreadRowView: View {
    let row: ThreadRow
    let showAccountDot: Bool
    @Environment(AppModel.self) private var model

    private var account: MailAccount? { model.accounts.first { $0.id == row.accountId } }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Unread accent bar + avatar circle (initial, tinted by account).
            ZStack(alignment: .leading) {
                if !row.isRead {
                    RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent).frame(width: 3, height: 36).offset(x: -16)
                }
                Circle()
                    .fill(account.map { Theme.tagBackground($0.color) } ?? Theme.navy100)
                    .frame(width: 36, height: 36)
                    .overlay {
                        Text(initial)
                            .font(.custom("Manrope-Bold", size: 14, relativeTo: .subheadline))
                            .foregroundStyle(account.map { Theme.tagForeground($0.color) } ?? Theme.textSecondary)
                    }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.fromSummary)
                        .font(Theme.sender(!row.isRead))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if row.isConversation {
                        Text("\(row.messageCount)").font(.caption2.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 8)
                    Text(timeText)
                        .font(.caption.weight(row.isRead ? .medium : .semibold))
                        .foregroundStyle(row.isRead ? Theme.textTertiary : Theme.textSecondary)
                        .monospacedDigit()
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(row.isRead ? Theme.textTertiary : Theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    badges
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var initial: String {
        String(row.fromSummary.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    private var timeText: String {
        if model.view == .scheduled, let at = row.scheduledAt { return Formatters.reminder(at) }
        return Formatters.rowTime(row.lastMessageAt)
    }

    private var preview: AttributedString {
        var s = AttributedString(row.subject.isEmpty ? "(no subject)" : row.subject)
        s.font = .subheadline.weight(row.isRead ? .regular : .semibold)
        s.foregroundColor = row.isRead ? Theme.textSecondary : Theme.textPrimary
        if !row.snippet.isEmpty {
            s += AttributedString(" · \(row.snippet)")
        }
        return s
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 5) {
            if let p = row.priority, p != .spam {
                Circle().fill(Theme.priorityColor(p)).frame(width: 6, height: 6)
                    .accessibilityLabel("Priority \(p.rawValue)")
            }
            if row.hasAttachment { badge("paperclip") }
            if row.scheduledAt != nil { badge(row.isFollowUp ? "clock.arrow.circlepath" : "clock") }
            if row.needsReply { badge("arrowshape.turn.up.left") }
            if row.isStarred { badge("star.fill") }
            if showAccountDot, let a = account {
                Circle().fill(Theme.tagForeground(a.color)).frame(width: 6, height: 6)
                    .accessibilityLabel(a.displayName)
            }
        }
    }

    private func badge(_ name: String) -> some View {
        Image(systemName: name).font(.caption2).foregroundStyle(Theme.textTertiary)
    }
}
