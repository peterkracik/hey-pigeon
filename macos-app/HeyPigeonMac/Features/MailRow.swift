// One row of the list, in the first desktop client's shape
// (desktop-app/src/lib/InboxList.svelte): a single line — the done circle,
// the sender in a fixed column, the subject and the snippet, the badges,
// the time — that reads like a to-do item. The circle marks it done with
// the desktop's strike-through before the row leaves. Under the pointer
// the time gives way to the Settings swipe actions and the arrow that
// opens the full thread. A click opens the row in place: a card with the
// latest message, Reply · Reply all · Forward and "Open full thread ›"
// (MailPreview). ⌘ and ⇧ gather rows for the batch bar; the context menu
// and two-finger trackpad swipes act on the row too.

import AppKit
import SwiftUI

struct MailRow: View {
    let row: ThreadRow
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    /// Between a click on the circle and the row leaving: the strike runs.
    @State private var completing = false

    private var expanded: Bool { state.expanded == row.id }
    private var selected: Bool { state.selection.contains(row.id) }

    var body: some View {
        VStack(spacing: 0) {
            line
            if expanded {
                Hairline()
                MailPreview(row: row, state: state)
                    .transition(.opacity)
            }
        }
        .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if expanded {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(MacTheme.hairline, lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(expanded ? 0.12 : 0), radius: 16, y: 6)
        .padding(.horizontal, 10)
        .padding(.vertical, expanded ? 8 : 0)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .contextMenu {
            RowMenu(row: row)
            Divider()
            Button { state.open(row, in: model) } label: { Label("Open Full Thread", systemImage: "arrow.up.left.and.arrow.down.right") }
            Button { state.openInWindow?(row.id) } label: { Label("Open in New Window", systemImage: "macwindow") }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            swipe(model.swipeActions[0])
            swipe(model.swipeActions[1])
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            swipe(model.swipeActions[2])
            swipe(model.swipeActions[3])
        }
        .onAppear { model.loadMoreIfNeeded(current: row) }
    }

    private var background: Color {
        if expanded { return MacTheme.panel }
        if selected { return MacTheme.selected }
        return hovering ? MacTheme.hover : .clear
    }

    // MARK: The line

    private var line: some View {
        HStack(spacing: 12) {
            marker
            DoneCircle(done: row.isDone || completing, completing: completing) { complete() }
            HStack(spacing: 5) {
                Text(row.fromSummary)
                    .font(.system(size: 13, weight: row.isRead ? .regular : .semibold))
                    .foregroundStyle(row.isRead && !expanded ? Theme.textSecondary : Theme.textPrimary)
                    .lineLimit(1)
                if row.isConversation {
                    Text("\(row.messageCount)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                }
            }
            .frame(width: MacLayout.senderWidth, alignment: .leading)
            HStack(spacing: 10) {
                Text(row.subject.isEmpty ? "(no subject)" : row.subject)
                    .font(.system(size: 13, weight: row.isRead ? .regular : .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(row.snippet)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .strikethrough(completing, color: Theme.textTertiary)
            .opacity(completing ? 0.5 : 1)
            Spacer(minLength: 8)
            badges
            trailing
        }
        .padding(.leading, 10).padding(.trailing, 12)
        .frame(height: 42)
        .contentShape(Rectangle())
        // A click opens the row in place (the arrow and Return open the
        // full thread); ⌘ and ⇧ gather rows for the batch bar.
        .onTapGesture {
            let modifiers = NSEvent.modifierFlags
            if modifiers.contains(.command) {
                state.toggle(row.id, in: model)
            } else if modifiers.contains(.shift) {
                state.extend(to: row.id, in: model)
            } else {
                state.expand(row, in: model)
            }
        }
        .onHover { hovering = $0 }
    }

    /// Unread: a dot on the left edge, in the account's colour when the
    /// list mixes accounts. Read rows keep a faint account dot there.
    @ViewBuilder private var marker: some View {
        let account = model.selectedAccountId == nil && model.accounts.count > 1
            ? model.accounts.first(where: { $0.id == row.accountId }) : nil
        Circle()
            .fill(account.map { Theme.tagForeground($0.color) } ?? Theme.unreadBar)
            .frame(width: 6, height: 6)
            .opacity(row.isRead ? (account == nil ? 0 : 0.3) : 1)
            .accessibilityHidden(row.isRead)
            .accessibilityLabel("Unread")
    }

    @ViewBuilder private var badges: some View {
        // The Mac lists bundle mail row by row (no folding), so the chip
        // is what ties a row to its bundle.
        if let b = model.bundle(id: row.bundleId) {
            RowChip(text: b.name, systemImage: b.category.systemImage, tint: Theme.tagForeground(.sky))
        }
        if row.hasAttachment {
            Image(systemName: "paperclip").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
        }
        if row.needsReply {
            RowChip(text: "Reply", systemImage: "arrowshape.turn.up.left", tint: Color(hex: 0x2A6BAE))
        }
        if let at = row.scheduledAt {
            RowChip(text: Formatters.rowTime(at), systemImage: row.isFollowUp ? "arrow.uturn.left.circle" : "clock",
                 tint: at < Date() ? Theme.accent : Theme.textSecondary)
        }
        if row.isPinned {
            Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Theme.pin)
        }
    }

    /// The time, or under the pointer the actions and the arrow.
    private var trailing: some View {
        ZStack(alignment: .trailing) {
            Text(expanded ? Formatters.fullDate(row.lastMessageAt) : Formatters.rowTime(row.lastMessageAt))
                .font(.system(size: 12))
                .foregroundStyle(row.isRead ? Theme.textTertiary : Theme.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .opacity(hovering ? 0 : 1)
            if hovering { RowActions(row: row, state: state) }
        }
        .frame(minWidth: 64, alignment: .trailing)
    }

    /// The circle: the strike runs, then the row is marked done and leaves
    /// (auto-advance hands the highlight on). A done row's circle undoes.
    private func complete() {
        guard !row.isDone else { state.run(.markDone, in: model, rows: [row]); return }
        withAnimation(.easeOut(duration: 0.25)) { completing = true }
        Task {
            try? await Task.sleep(for: .milliseconds(380))
            state.run(.markDone, in: model, rows: [row])
            completing = false
        }
    }

    private func swipe(_ action: RowAction) -> some View {
        Button { state.run(action.command, in: model, rows: [row]) } label: {
            Label(action.label(for: row), systemImage: action.glyph(for: row))
        }
        .tint(action.tint)
    }
}

/// The to-do circle: an outline, a faint check under the pointer, filled
/// when done.
private struct DoneCircle: View {
    let done: Bool
    let completing: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(done ? Theme.textPrimary : Theme.textTertiary.opacity(hovering ? 1 : 0.6), lineWidth: 1.3)
                    .background(Circle().fill(done ? Theme.textPrimary : .clear))
                if done || hovering {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(done ? Theme.onPrimary : Theme.textTertiary)
                }
            }
            .frame(width: 17, height: 17)
            .scaleEffect(completing ? 1.12 : 1)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(done ? "Mark not done (E)" : "Mark done (E)")
        .accessibilityLabel(done ? "Mark not done" : "Mark done")
    }
}

/// A small tinted label: Reply, a reminder's time.
private struct RowChip: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Under the pointer: the swipe actions from Settings (Done is the
/// circle), then the arrow to the full thread.
private struct RowActions: View {
    let row: ThreadRow
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model

    private var actions: [RowAction] {
        var list: [RowAction] = []
        for a in model.swipeActions where a != .done && !list.contains(a) { list.append(a) }
        return list
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(actions) { action in
                SmallIcon(systemImage: action.glyph(for: row), help: "\(action.label(for: row)) (\(action.key))") {
                    state.run(action.command, in: model, rows: [row])
                }
            }
            SmallIcon(systemImage: "chevron.right", help: "Open full thread (↩)") { state.open(row, in: model) }
        }
    }
}

/// A row's own icon button: smaller than the top bar's.
private struct SmallIcon: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(hovering ? MacTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The open row's card body: the latest message (who it is to, the body,
/// folded to a readable height), then Reply · Reply all · Forward and the
/// way to the full thread. The thread is read once, from the store or the
/// network, the first time the card opens.
struct MailPreview: View {
    let row: ThreadRow
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model
    @State private var detail: ThreadDetail?
    @State private var failed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let last = detail?.mail.last {
                Text("\(last.isMine ? "Me" : last.fromName) to \(last.to.joined(separator: ", "))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                MessageBodyView(html: last.bodyHTML, text: last.bodyText ?? last.snippet, senderAddress: last.fromAddress)
                    .frame(maxHeight: 440, alignment: .top)
                    .clipped()
            } else if let failed {
                Text(failed).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 18)
            }
            HStack(spacing: 6) {
                PillButton(title: "Reply", systemImage: "arrowshape.turn.up.left") { state.run(.reply, in: model, rows: [row]) }
                PillButton(title: "Reply all", systemImage: "arrowshape.turn.up.left.2") { state.run(.replyAll, in: model, rows: [row]) }
                PillButton(title: "Forward", systemImage: "arrowshape.turn.up.right") { state.run(.forward, in: model, rows: [row]) }
                Spacer(minLength: 8)
                if row.isConversation {
                    Text("\(row.messageCount) messages").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                Button { state.open(row, in: model) } label: {
                    HStack(spacing: 4) {
                        Text("Open full thread")
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(MacTheme.selected, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Open the full thread (↩)")
            }
        }
        .padding(.leading, 56).padding(.trailing, 18).padding(.vertical, 14)
        .task(id: row.id) {
            do {
                detail = try await model.engine.thread(id: row.id)
                if detail == nil { failed = "This thread is no longer available." }
            } catch {
                failed = error.localizedDescription
            }
        }
    }
}

/// Reply · Reply all · Forward under the preview.
private struct PillButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10).frame(height: 28)
                .background(hovering ? MacTheme.selected : MacTheme.hover, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
