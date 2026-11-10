// One row of the list, in the first desktop client's shape
// (desktop-app/src/lib/InboxList.svelte): a single line — the sender in a
// fixed column, the subject and the snippet, the badges, the time — on
// its day group's white card (the rows of a group share one card; each
// row draws its piece, `Position`). Under the pointer the time gives way
// to Done (the desktop's strike-through, then the row leaves), the other
// swipe actions from Settings and the arrow that opens the full thread.
// (A done circle at the row's start read as a selection checkbox.) The
// pointer is the hand over a row, as it was in the first desktop client;
// a click opens the row in place: the latest message, whole, Reply ·
// Reply all · Forward and "Open full thread ›" (MailPreview). ⌘ and ⇧
// gather rows for the batch bar; the context menu and two-finger trackpad
// swipes act on the row too. A bundle's Emails page lists its mail with
// the same row (BundleEmailList, `inBundle`): no bundle chip, since every
// row there would carry the same one, ⊖ (not part of this bundle) in the
// hover bar, and no cursor, as the Bundles page has none.

import AppKit
import SwiftUI

struct MailRow: View {
    /// Where the row sits in its day group: the group's card rounds its
    /// first row's top corners and its last row's bottom ones.
    struct Position {
        var first = true
        var last = true
    }

    let row: ThreadRow
    @Bindable var state: WindowState
    var position = Position()
    /// On a bundle's Emails page (the header comment says what differs).
    var inBundle = false
    /// A done email in a bundle: there for reference, set back until the
    /// pointer is on it or it is open.
    var dimmed = false
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    /// Between a click on Done and the row leaving: the strike runs.
    @State private var completing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var expanded: Bool { state.expanded == row.id }
    /// The window's cursor is the list's: under the Bundles page it is out
    /// of sight, and its row may be in the bundle too.
    private var selected: Bool { !inBundle && state.selection.contains(row.id) }

    var body: some View {
        VStack(spacing: 0) {
            line
                .opacity(dimmed && !expanded && !hovering ? 0.6 : 1)
            if expanded {
                Hairline()
                MailPreview(row: row, state: state)
                    .transition(.opacity)
            }
        }
        // The hover / cursor tint fills the row to 1 pt of the card's edge,
        // rounded only where the card is (an inset pill left a white frame
        // around every highlighted row).
        .background(background, in: UnevenRoundedRectangle(topLeadingRadius: position.first ? 13 : 0,
                                                            bottomLeadingRadius: position.last ? 13 : 0,
                                                            bottomTrailingRadius: position.last ? 13 : 0,
                                                            topTrailingRadius: position.first ? 13 : 0,
                                                            style: .continuous))
        .padding(1)
        // This row's piece of its group's white card; no shadow (on a card
        // holding a message it fell on the message's web view too).
        .background {
            UnevenRoundedRectangle(topLeadingRadius: position.first ? 14 : 0,
                                   bottomLeadingRadius: position.last ? 14 : 0,
                                   bottomTrailingRadius: position.last ? 14 : 0,
                                   topTrailingRadius: position.first ? 14 : 0,
                                   style: .continuous)
                .fill(MacTheme.groupCard)
        }
        .padding(.horizontal, 16)
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
        // The next page of the window's list; a bundle's is whole.
        .onAppear { if !inBundle { model.loadMoreIfNeeded(current: row) } }
    }

    private var background: Color {
        if expanded { return .clear }
        if selected { return MacTheme.selected }
        return hovering ? MacTheme.hover : .clear
    }

    // MARK: The line

    private var line: some View {
        HStack(spacing: 12) {
            marker
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
            .frame(width: state.readingPane && !inBundle ? MacLayout.paneSenderWidth : MacLayout.senderWidth, alignment: .leading)
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
        // (Not on a bundle's page, which has no batch bar.)
        .onTapGesture {
            let modifiers: NSEvent.ModifierFlags = inBundle ? [] : NSEvent.modifierFlags
            if modifiers.contains(.command) {
                state.toggle(row.id, in: model)
            } else if modifiers.contains(.shift) {
                state.extend(to: row.id, in: model)
            } else {
                state.expand(row, in: model)
            }
        }
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        // Onto a label, a bundle or a folder in the sidebar (SidebarColumn).
        .draggable(ThreadDrag.payload(for: row.id, selection: state.selection))
        // The hover bar's actions for VoiceOver and Voice Control, which
        // have no pointer to bring it up; the row reads as one element.
        .accessibilityElement(children: .combine)
        // The state in the words the phone's row uses (ThreadRow.spokenState):
        // the chips said "Reply" and a bare time, the symbols nothing.
        .accessibilityValue(row.spokenState(showsDone: false))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { state.open(row, in: model) }
        .accessibilityActions {
            ForEach(RowAction.allCases) { action in
                Button(action.label(for: row)) { state.run(action.command, in: model, rows: [row]) }
            }
            Button(expanded ? "Close preview" : "Preview") { state.expand(row, in: model) }
            if inBundle {
                Button("Not part of this bundle") { model.removeFromBundle(row) }
            }
        }
    }

    /// Unread: a dot on the left edge, in the account's colour when the
    /// list mixes accounts. Read rows keep a faint account dot there.
    @ViewBuilder private var marker: some View {
        // Through the model's map, which changes only when an account does:
        // every row used to scan the accounts on every render.
        let account = model.selectedAccountId == nil && model.accountsById.count > 1 ? model.account(for: row) : nil
        Circle()
            .fill(account.map { Theme.tagForeground($0.color) } ?? Theme.unreadBar)
            .frame(width: 6, height: 6)
            .opacity(row.isRead ? (account == nil ? 0 : 0.3) : 1)
            .accessibilityHidden(true) // "Unread", in the row's value
    }

    @ViewBuilder private var badges: some View {
        // The Mac lists bundle mail row by row (no folding), so the chip
        // is what ties a row to its bundle.
        if !inBundle, let b = model.bundle(id: row.bundleId) {
            RowChip(text: b.name, systemImage: b.category.systemImage, tint: Theme.tagForeground(.sky))
        }
        // The AI's proposal and an unsent reply, as the phone's row shows
        // them (ThreadRowView): here a suggestion was only in the context
        // menu and inside the thread, and a draft nowhere. Read-only — the
        // thread and the menu accept or dismiss a suggestion.
        if let s = row.openSuggestion {
            RowChip(text: s.title, systemImage: "sparkles", tint: Theme.textPrimary, background: Theme.accentSoft)
                .accessibilityLabel("Suggested: \(s.title)")
        }
        if row.labels.contains("DRAFT"), model.view != .drafts {
            RowChip(text: "Draft", systemImage: "pencil", tint: Theme.danger)
        }
        if row.hasAttachment {
            Image(systemName: "paperclip").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
        if row.needsReply {
            RowChip(text: "Reply", systemImage: "arrowshape.turn.up.left", tint: Theme.needReply)
                .accessibilityHidden(true)
        }
        if let at = row.scheduledAt {
            RowChip(text: Formatters.rowTime(at), systemImage: row.isFollowUp ? "arrow.uturn.left.circle" : "clock",
                 tint: at < Date() ? Theme.accent : Theme.textSecondary)
                .accessibilityHidden(true)
        }
        if row.isPinned {
            Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Theme.pin)
                .accessibilityHidden(true)
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
            if hovering { RowActions(row: row, state: state, inBundle: inBundle) { complete() } }
        }
        .frame(minWidth: 64, alignment: .trailing)
    }

    /// Done: the strike runs, then the row is marked done and leaves
    /// (auto-advance hands the highlight on). On a done row it undoes.
    private func complete() {
        // With Reduce Motion the row just leaves: no strike to wait for.
        guard !row.isDone, !reduceMotion else { state.run(.markDone, in: model, rows: [row]); return }
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

/// A small tinted label: Reply, a reminder's time.
private struct RowChip: View {
    let text: String
    let systemImage: String
    let tint: Color
    /// The fill, when it is not a wash of the tint (the suggestion's
    /// accent behind primary text, as on the phone).
    var background: Color? = nil

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(background ?? tint.opacity(0.12), in: Capsule())
    }
}

/// Under the pointer: Done first, the other swipe actions from Settings,
/// then the arrow to the full thread. On a bundle's page ⊖ comes before
/// the arrow: the email is not part of this bundle (the model learns from
/// it; the context menu's "Not part of …" is the same action).
private struct RowActions: View {
    let row: ThreadRow
    @Bindable var state: WindowState
    var inBundle = false
    /// Done, through the row, so its strike-through runs first.
    let onDone: () -> Void
    @Environment(AppModel.self) private var model

    private var actions: [RowAction] {
        var list: [RowAction] = []
        for a in model.swipeActions where a != .done && !list.contains(a) { list.append(a) }
        return list
    }

    var body: some View {
        HStack(spacing: 0) {
            IconButton(RowAction.done.glyph(for: row),
                       help: "\(RowAction.done.label(for: row)) (\(RowAction.done.key))", size: .small) { onDone() }
            ForEach(actions) { action in
                IconButton(action.glyph(for: row), help: "\(action.label(for: row)) (\(action.key))", size: .small) {
                    state.run(action.command, in: model, rows: [row])
                }
            }
            if inBundle {
                IconButton("minus.circle", help: "Not part of this bundle", size: .small) { model.removeFromBundle(row) }
            }
            IconButton("chevron.right", help: inBundle ? "Open full thread" : "Open full thread (↩)", size: .small) {
                state.open(row, in: model)
            }
        }
    }
}

/// The open row's card body: the latest message (who it is to, then the
/// whole body — the list scrolls, as the first desktop client's did; a
/// fold cut a message off mid-sentence with nothing to say so), then
/// Reply · Reply all · Forward and the way to the full thread. The thread
/// is read once, from the store or the network, the first time the card
/// opens.
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
                MessageBodyView(html: last.bodyHTML, text: last.bodyText ?? last.snippet, senderAddress: last.fromAddress,
                                translatable: !last.isMine)
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
        // The same margin on both sides of the message and its buttons.
        .padding(.horizontal, 20).padding(.vertical, 14)
        .task(id: row.id) {
            // The stored copy first (whole when the thread was opened or
            // prefetched, else its snippet), then Gmail's: the card used
            // to spin until the network had answered.
            let id = row.id
            if detail == nil, let local = try? await model.engine.readInBackground({ try $0.threadLocal(id: id) }),
               !local.mail.isEmpty, !Task.isCancelled {
                detail = local
            }
            do {
                let fresh = try await model.engine.thread(id: row.id)
                if fresh != detail { detail = fresh }
                if detail == nil { failed = "This thread is no longer available." }
            } catch {
                if detail == nil { failed = error.localizedDescription }
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
