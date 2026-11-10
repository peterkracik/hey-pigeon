// The iPad's split layout (PadSplitView.swift): what is open in it, and
// the hardware keyboard's map. One object per scene, not in AppModel —
// which thread a window shows is the window's business, as on the Mac
// (macos-app WindowState). This file is the part with no view in it, so it
// compiles for the Mac too and the tests run it on both: the key map is a
// table, and the moves (j / k, auto-advance) only read the model's list
// order (`AppModel.flatRowIds`, `listIndex(of:)`).

import SwiftUI

/// What a key can do in the split layout.
enum PadCommand: Equatable, Sendable {
    case next, previous
    case delete, toggleRead
    case replyAll, forward
    case compose, search, close, undo

    /// Its name where the system lists an app's keys (the iPad's ⌘-hold
    /// overlay).
    var title: String {
        switch self {
        case .next: "Next thread"
        case .previous: "Previous thread"
        case .delete: "Delete"
        case .toggleRead: "Mark read or unread"
        case .replyAll: "Reply all"
        case .forward: "Forward"
        case .compose: "New message"
        case .search: "Search"
        case .close: "Close thread"
        case .undo: "Undo"
        }
    }
}

/// One key of the split layout.
struct PadBinding: Sendable {
    let key: KeyEquivalent
    var modifiers: EventModifiers = []
    let command: PadCommand
}

/// The iPad's keys, the desktop's letters. Each is a key equivalent on a
/// button that draws nothing (PadSplitView), like the open thread's own
/// (`threadKey`): the system hands a bare letter to a text field first, so
/// typing in the search field or the composer never runs one, and no view
/// has to hold the keyboard focus for them to work — a focus-based map
/// went dead after every sheet.
///
/// Mark done (e), Remind me (h), Need reply (n), Pin (s), Reply (r) and
/// Delete (⌘⌫) are not here: the open thread's own buttons hold those
/// keys, and in this layout the highlighted row and the open thread are
/// the same one — a second binding would run the action twice (or, for
/// `r`, skip the pill's "Continue draft").
enum PadKeys {
    static let bindings: [PadBinding] = [
        PadBinding(key: "j", command: .next),
        PadBinding(key: .downArrow, command: .next),
        PadBinding(key: "k", command: .previous),
        PadBinding(key: .upArrow, command: .previous),
        // `#` as the character and as the key that types it on a US
        // layout: which of the two the system matches is the keyboard's
        // business, and one press runs at most one of them.
        PadBinding(key: "#", command: .delete),
        PadBinding(key: "3", modifiers: .shift, command: .delete),
        PadBinding(key: "u", command: .toggleRead),
        PadBinding(key: "a", command: .replyAll),
        PadBinding(key: "f", command: .forward),
        PadBinding(key: "c", command: .compose),
        PadBinding(key: "/", command: .search),
        PadBinding(key: "z", command: .undo),
        PadBinding(key: .escape, command: .close),
    ]

    /// What a key runs, nil when it is not one of the layout's.
    static func command(for key: KeyEquivalent, modifiers: EventModifiers = []) -> PadCommand? {
        bindings.first { $0.key.character == key.character && $0.modifiers == modifiers }?.command
    }
}

@MainActor
@Observable
final class PadState {
    /// The thread in the detail column, which is also the highlighted row
    /// of the list. Nil shows the placeholder.
    private(set) var openRow: ThreadRow?
    /// The list scrolls to this id after a keyboard move or an auto-advance
    /// (a tap needs none: the row is under the finger).
    var scrollTarget: String?
    /// `/` was pressed: the Search column takes the caret once it is up.
    var wantsSearchFocus = false

    /// A list: another folder, account or tab is another one, and its
    /// rows are not "the next thread" of this one.
    private struct ListKey: Equatable {
        let tab: MainTab
        let view: MailView
        let accountId: String?
    }

    /// Where the open thread last sat as a row, and in which list, so its
    /// neighbour takes its place when the user deals with it. Nil for a
    /// thread that never was a row (opened from a banner).
    @ObservationIgnored private var listedAt: (list: ListKey, index: Int)?

    private func key(_ model: AppModel) -> ListKey {
        ListKey(tab: model.tab, view: model.view, accountId: model.selectedAccountId)
    }

    // MARK: Opening and closing

    /// Show a thread in the detail column and highlight its row.
    func open(_ row: ThreadRow, in model: AppModel) {
        openRow = row
        listedAt = model.listIndex(of: row.id).map { (key(model), $0) }
    }

    /// Back to the placeholder (Esc).
    func close() {
        openRow = nil
        listedAt = nil
    }

    /// A row picked by a key or by auto-advance: read, as a tap makes it,
    /// and scrolled into view. A draft opens the composer instead.
    private func show(_ row: ThreadRow, in model: AppModel) {
        if model.view == .drafts { model.openDraft(row); return }
        if !row.isRead { model.markRead(row) }
        open(row, in: model)
        scrollTarget = row.id
    }

    /// j / k / arrows: the neighbour of the open thread, clamped; the
    /// first or the last row when none is open.
    func move(by delta: Int, in model: AppModel) {
        let ids = model.flatRowIds
        guard !ids.isEmpty else { return }
        let current = openRow.flatMap { model.listIndex(of: $0.id) }
        let next = current.map { min(max($0 + delta, 0), ids.count - 1) } ?? (delta > 0 ? 0 : ids.count - 1)
        guard next != current, let row = model.row(forThreadId: ids[next]) else { return }
        show(row, in: model)
    }

    // MARK: Auto-advance

    /// The row that took the open thread's place opens (Superhuman's
    /// auto-advance, as on the Mac); the placeholder when there is none.
    private func advance(from index: Int, in model: AppModel) {
        let ids = model.flatRowIds
        guard !ids.isEmpty, let next = model.row(forThreadId: ids[min(index, ids.count - 1)]) else {
            close()
            return
        }
        show(next, in: model)
    }

    /// The user did something on the open thread that ends it (done,
    /// delete, mark unread, move): the next thread takes its place when
    /// its row left the list it was in, else the placeholder comes back.
    func closeOpen(in model: AppModel) {
        guard let open = openRow else { return }
        if let at = listedAt, at.list == key(model), model.listIndex(of: open.id) == nil {
            advance(from: at.index, in: model)
        } else {
            close()
        }
    }

    /// The list's order changed (`AppModel.rowOrderRevision`): remember
    /// where the open thread sits now. A row that left the list on its
    /// own — another folder or filter, a search typed with a thread open,
    /// done on another device — opens nothing: only the user's own action
    /// on the open thread advances (`closeOpen`). Advancing here opened
    /// the next thread and marked it read without anyone asking, and
    /// with an "unread" search that walked through every result.
    func rowsChanged(in model: AppModel) {
        guard let open = openRow, let index = model.listIndex(of: open.id) else { return }
        listedAt = (key(model), index)
    }

    // MARK: Commands

    /// Run a key's command on the open thread, through AppModel like the
    /// swipes, so undo, the badge and the widgets follow.
    func run(_ command: PadCommand, in model: AppModel) {
        // Live from the store: the copy this was opened with goes stale
        // with the first action.
        let row = openRow.map { model.row(forThreadId: $0.id) ?? $0 }
        switch command {
        case .next:
            move(by: 1, in: model)
        case .previous:
            move(by: -1, in: model)
        case .delete:
            guard let row else { return }
            IntentDonations.deleted(row, in: model)
            model.delete(row)
            closeOpen(in: model)
        case .toggleRead:
            guard let row else { return }
            // Marking the open thread unread closes it: staying would only
            // read it again.
            let wasRead = row.isRead
            model.toggleRead(row)
            if wasRead { close() }
        case .replyAll:
            guard let row else { return }
            IntentDonations.replied(row, all: true, in: model)
            Task { try? await model.openReply(to: row, all: true, body: nil) }
        case .forward:
            guard let row else { return }
            Task { try? await model.openForward(of: row) }
        case .compose:
            model.compose(SendDraft())
        case .search:
            wantsSearchFocus = true
            if model.tab != .search { model.navigate(to: .search) }
        case .close:
            close()
        case .undo:
            model.undoLast()
        }
    }
}

// MARK: - The highlighted row

/// The id of the thread open beside the list, for the row that shows it:
/// nil on the phone, where a thread covers the list.
private struct OpenThreadIdKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var openThreadId: String? {
        get { self[OpenThreadIdKey.self] }
        set { self[OpenThreadIdKey.self] = newValue }
    }
}
