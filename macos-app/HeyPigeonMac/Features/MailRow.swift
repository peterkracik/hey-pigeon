// One row of the list, in the first desktop client's shape
// (desktop-app/src/lib/InboxList.svelte): a single line — the account's
// dot, the sender in a fixed column, the subject and the snippet, the
// state marks, the time — on the paper, with a hairline under it (but for
// the last row of its group). Unread is the sender in bold under the
// highlighter; the row under the pointer is the sunken grey, the cursor's
// and a selected one a step stronger with an ink rule down its leading
// edge and a heavier name. Under the pointer the time gives way to Done
// (the row's ink action: the subject is struck through, then the row
// leaves), the other swipe actions from Settings and the arrow that opens
// the full thread. (A done circle at the row's start read as a selection
// checkbox.) The pointer is the hand over a row, as it was in the first
// desktop client; a click opens the row in place, under a hairline and
// beside the ink rule: the latest message, whole, Reply · Reply all ·
// Forward and "Open full thread ›" (MailPreview). ⌘ and ⇧ gather rows for
// the batch bar; the context menu and two-finger trackpad swipes act on
// the row too. A bundle's Emails page lists its mail with the same row
// (BundleEmailList, `inBundle`): no bundle mark, since every row there
// would carry the same one, ⊖ (not part of this bundle) in the hover bar,
// and no cursor, as the Bundles page has none.

import AppKit
import SwiftUI

struct MailRow: View {
    let row: ThreadRow
    @Bindable var state: WindowState
    /// The last row of its group: it has no hairline under it (the next
    /// thing down is the next group's title and its rule).
    var isLast = false
    /// The first row of a group that has no title (a bundle's open
    /// emails): the rule that opens such a group runs along its top edge.
    /// Part of the row, not a 1 pt row of its own, which a list would
    /// give its least row height.
    var opensGroup = false
    /// On a bundle's Emails page (the header comment says what differs).
    var inBundle = false
    /// A done email in a bundle: there for reference, struck through and
    /// set back to the tertiary grey until the pointer is on it or it is
    /// open.
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
    /// Done is struck through: while the strike runs after a click on
    /// Done, and on a bundle's done emails.
    private var struck: Bool { completing || dimmed }
    /// A done row steps back to the tertiary grey, until the pointer is
    /// on it or it is open.
    private var setBack: Bool { completing || dimmed && !expanded && !hovering }
    /// The account's dot, where the list mixes accounts. Through the
    /// model's map, which changes only when an account does: every row
    /// used to scan the accounts on every render.
    private var account: MailAccount? {
        model.selectedAccountId == nil && model.accountsById.count > 1 ? model.account(for: row) : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            line
            if expanded {
                Hairline()
                // The message starts where the sender's name does.
                MailPreview(row: row, state: state)
                    .padding(.leading, account == nil ? 0 : 18)
                    .transition(.opacity)
            }
        }
        // The pointer's and the cursor's tint fills the row, square, from
        // one margin of the list to the other.
        .background(background)
        // The hairline under the row. An overlay, not a row of its own:
        // the list's cursor and the scroll target count rows.
        .overlay(alignment: .bottom) {
            if !isLast { RowRule().allowsHitTesting(false) }
        }
        .overlay(alignment: .top) {
            if opensGroup { SectionRule().allowsHitTesting(false) }
        }
        // Unread: the pink corner at the row's foot, with the bold sender.
        .unreadCorner(!row.isRead)
        // The cursor's row, a selected one and the one open in place carry
        // an ink rule down their leading edge, the open row's message
        // too. Drawn over the row, never clipped into it and with no
        // shadow: the row may hold a message's web view.
        .overlay(alignment: .leading) {
            if selected || expanded {
                Rectangle().fill(Theme.textPrimary).frame(width: 2).allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, MacLayout.listMargin)
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
            accountDot
            // The sender column and the subject · snippet, as the search
            // panel's results draw them too (MailLineSender, MailLineSubject).
            MailLineSender(row: row, width: state.readingPane && !inBundle ? MacLayout.paneSenderWidth : MacLayout.senderWidth,
                           showsCount: true, dimmed: row.isRead, heavy: selected || expanded, setBack: setBack)
            MailLineSubject(row: row, gap: 10, struck: struck, setBack: setBack)
            Spacer(minLength: 8)
            badges
            trailing
        }
        .padding(.horizontal, 4)
        .frame(height: MacLayout.rowHeight)
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
        // the marks said "Reply" and a bare time, the symbols nothing.
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

    /// The account, where the list mixes accounts: a 6 pt dot in its
    /// colour at the row's start, fainter once the row is read. It is
    /// not the unread mark — that is the sender, bold under the
    /// highlighter — and with one account on screen there is no dot.
    @ViewBuilder private var accountDot: some View {
        if let account {
            Circle()
                .fill(Theme.state(account.color))
                .frame(width: 6, height: 6)
                .opacity(row.isRead ? 0.35 : 1)
                .accessibilityHidden(true)
        }
    }

    /// The row's states as writing in their colour (`StateMark`), never
    /// as filled chips; the paperclip and the pin are bare glyphs.
    @ViewBuilder private var badges: some View {
        // The Mac lists bundle mail row by row (no folding), so the mark
        // is what ties a row to its bundle.
        if !inBundle, let b = model.bundle(id: row.bundleId) {
            StateMark(text: b.name, systemImage: b.category.systemImage, tint: Theme.state(.sky))
        }
        // The AI's proposal and an unsent reply, as the phone's row shows
        // them (ThreadRowView): here a suggestion was only in the context
        // menu and inside the thread, and a draft nowhere. Read-only — the
        // thread and the menu accept or dismiss a suggestion. The
        // suggestion is the one mark in pink ink: it is the AI's.
        if let s = row.openSuggestion {
            StateMark(text: s.title, systemImage: "sparkles", tint: Theme.pinkInk)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Suggested: \(s.title)")
        }
        if row.labels.contains("DRAFT"), model.view != .drafts {
            StateMark(text: "Draft", systemImage: "pencil", tint: Theme.state(.coral))
        }
        if row.hasAttachment {
            Image(systemName: "paperclip").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
        if row.needsReply {
            StateMark(text: "Reply", systemImage: "arrowshape.turn.up.left", tint: Theme.state(.sky))
                .accessibilityHidden(true)
        }
        // A reminder is lavender whether it is due or still ahead: pink
        // is the unread sender's and the AI's, not "this came due".
        if let at = row.scheduledAt {
            StateMark(text: Formatters.rowTime(at), systemImage: row.isFollowUp ? "arrow.uturn.left.circle" : "clock",
                      tint: Theme.state(.lavender))
                .accessibilityHidden(true)
        }
        if row.isPinned {
            Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Theme.pin)
                .accessibilityHidden(true)
        }
    }

    /// The time in the mono — ink while the row is unread, the tertiary
    /// grey once read — or under the pointer the actions and the arrow.
    private var trailing: some View {
        ZStack(alignment: .trailing) {
            Text(expanded ? Formatters.fullDate(row.lastMessageAt) : Formatters.rowTime(row.lastMessageAt))
                .font(Theme.meta)
                .foregroundStyle(row.isRead || setBack ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
                .opacity(hovering ? 0 : 1)
            if hovering { RowActions(row: row, state: state, inBundle: inBundle) { complete() } }
        }
        .frame(minWidth: 72, alignment: .trailing)
    }

    /// Done: the strike runs (the subject struck through, the row set
    /// back to the tertiary grey), then the row is marked done and leaves
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

/// The sender column of a single-line row: the name in a fixed width —
/// bold under the highlighter while unread, medium once read — and the
/// thread's message count after it in the mono. The window's row and the
/// search panel's result each give their own width.
struct MailLineSender: View {
    let row: ThreadRow
    let width: CGFloat
    /// The message count of a conversation, after the name.
    var showsCount = false
    /// A read row's name in the secondary grey (the window's list).
    var dimmed = false
    /// The highlighted row (the list's cursor, a selection, the row open
    /// in place, a panel's highlight): a read name takes the semibold, in
    /// ink. An unread one is bold already.
    var heavy = false
    /// A done row set back: the name in the tertiary grey.
    var setBack = false

    private var font: Font {
        if !row.isRead { return Theme.sender(true) }
        return heavy ? Theme.sans(size: 13, weight: .semibold) : Theme.sender(false)
    }

    private var ink: Color {
        if setBack { return Theme.textTertiary }
        return dimmed && !heavy ? Theme.textSecondary : Theme.textPrimary
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(row.fromSummary)
                .font(font)
                .foregroundStyle(ink)
                .lineLimit(1)
            if showsCount && row.isConversation {
                Text("\(row.messageCount)")
                    .font(Theme.mono(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// The subject, semibold while unread, and the snippet after it in grey,
/// on one line; the subject keeps its width first.
struct MailLineSubject: View {
    let row: ThreadRow
    /// The space between the subject and the snippet.
    let gap: CGFloat
    /// A done row: the subject and the snippet struck through.
    var struck = false
    /// A done row set back: the subject in the tertiary grey too.
    var setBack = false

    var body: some View {
        HStack(spacing: gap) {
            Text(row.subject.isEmpty ? "(no subject)" : row.subject)
                .font(Theme.sans(size: 13, weight: row.isRead ? .regular : .semibold))
                .foregroundStyle(setBack ? Theme.textTertiary : Theme.textPrimary)
                .struckThrough(struck)
                .lineLimit(1)
                .layoutPriority(1)
            Text(row.snippet)
                .font(Theme.sans(size: 13))
                .foregroundStyle(Theme.textTertiary)
                .struckThrough(struck)
                .lineLimit(1)
        }
    }
}

/// Under the pointer: Done first — the row's ink action, a check on an
/// ink circle — the other swipe actions from Settings as plain glyphs,
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
                       help: "\(RowAction.done.label(for: row)) (\(RowAction.done.key))", size: .small,
                       prominent: true) { onDone() }
                .padding(.trailing, 2)
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

/// The open row's body, under its line and a hairline: the latest
/// message (who it is to, then the whole body — the list scrolls, as the
/// first desktop client's did; a fold cut a message off mid-sentence with
/// nothing to say so), then Reply (the ink pill) · Reply all · Forward
/// and the way to the full thread, outlined. The thread is read once,
/// from the store or the network, the first time the row opens. No card,
/// no clip and no shadow around it: either would lie over the message's
/// web view.
struct MailPreview: View {
    let row: ThreadRow
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model
    @State private var detail: ThreadDetail?
    @State private var failed: String?
    /// The attachments of the thread's messages, by message: read once the
    /// row is open, as the thread view does.
    @State private var attachments: [String: [AttachmentItem]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let last = detail?.mail.last {
                Text("\(last.isMine ? "Me" : last.fromName) to \(last.to.joined(separator: ", "))")
                    .font(Theme.meta)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                MessageBodyView(html: last.bodyHTML, text: last.bodyText ?? last.snippet, senderAddress: last.fromAddress,
                                inlineImages: (attachments[last.id] ?? []).filter { $0.contentId != nil },
                                translatable: !last.isMine)
                // A picture the body already shows (a signature logo) is
                // not offered again as a file.
                let files = (attachments[last.id] ?? []).filter { !InlineImages.isShownInline($0, in: last.bodyHTML) }
                if !files.isEmpty { AttachmentChips(attachments: files) }
            } else if let failed {
                Text(failed).font(Theme.sans(size: 13)).foregroundStyle(Theme.textSecondary)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 18)
            }
            HStack(spacing: 6) {
                PillButton(title: "Reply", systemImage: "arrowshape.turn.up.left", ink: true) { state.run(.reply, in: model, rows: [row]) }
                PillButton(title: "Reply all", systemImage: "arrowshape.turn.up.left.2") { state.run(.replyAll, in: model, rows: [row]) }
                PillButton(title: "Forward", systemImage: "arrowshape.turn.up.right") { state.run(.forward, in: model, rows: [row]) }
                Spacer(minLength: 8)
                if row.isConversation {
                    Text("\(row.messageCount) messages").font(Theme.meta).foregroundStyle(Theme.textTertiary)
                        .padding(.trailing, 6)
                }
                PillButton(title: "Open full thread", trailingImage: "chevron.right", strong: true) {
                    state.open(row, in: model)
                }
                .help("Open the full thread (↩)")
            }
        }
        // The row's own margin at the sides (MailRow adds the account
        // dot's column), air over the message and under its buttons.
        .padding(.horizontal, 4).padding(.top, 14).padding(.bottom, 16)
        .task(id: row.id) {
            // The stored copy first (whole when the thread was opened or
            // prefetched, else its snippet), then Gmail's: the row used
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
            guard row.hasAttachment, let list = try? await model.engine.attachments(threadId: id), !list.isEmpty,
                  !Task.isCancelled else { return }
            attachments = Dictionary(grouping: list, by: \.messageId)
        }
    }
}

/// The pills under a row's preview: Reply (`ink`: the row's one ink
/// action, the paper's colour for its words), Reply all · Forward
/// (outlined in ink, an icon first, the sunken grey under the pointer)
/// and "Open full thread ›" (`strong`: the one that goes somewhere —
/// outlined too, in the semibold, its chevron after the words). One 28 pt
/// capsule. The open thread's last message ends with the same three
/// reply pills (the shared shell's `ThreadReplyFoot`).
struct PillButton: View {
    let title: String
    var systemImage: String? = nil
    /// A symbol after the title (the strong pill's chevron).
    var trailingImage: String? = nil
    var strong = false
    /// The ink pill: filled, with `onPrimary` words.
    var ink = false
    let action: () -> Void
    @State private var hovering = false

    init(title: String, systemImage: String? = nil, trailingImage: String? = nil, strong: Bool = false,
         ink: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.trailingImage = trailingImage
        self.strong = strong
        self.ink = ink
        self.action = action
    }

    /// Ink for the ink pill (a little lighter under the pointer); for an
    /// outlined one nothing, or the sunken grey under the pointer.
    private var fill: Color {
        if ink { return Theme.textPrimary.opacity(hovering ? 0.85 : 1) }
        return hovering ? Theme.sunken : Color.clear
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: systemImage == nil ? 4 : 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .medium))
                        .accessibilityHidden(true)
                }
                Text(title).font(Theme.sans(size: 12.5, weight: ink || strong ? .semibold : .medium))
                if let trailingImage {
                    Image(systemName: trailingImage).font(.system(size: 9, weight: .bold))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(ink ? Theme.onPrimary : Theme.textPrimary)
            .padding(.horizontal, 12).frame(height: 28)
            .background(fill, in: Capsule())
            .overlay(Capsule().strokeBorder(ink ? Color.clear : Theme.textPrimary, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
