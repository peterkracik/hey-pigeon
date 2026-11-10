// The iPad's split layout (PadSplitView.swift): what is open in it, and
// the hardware keyboard's map. One object per scene, not in AppModel —
// which thread a window shows is the window's business, as on the Mac
// (macos-app WindowState). This file is the part with no view in it, so it
// compiles for the Mac too and the tests run it on both: the key map is a
// pure function, and the moves (j / k, auto-advance) only read the model's
// list order (`AppModel.flatRowIds`, `listIndex(of:)`).

import SwiftUI

/// What a key can do in the split layout.
enum PadCommand: Equatable {
    case next, previous
    case delete, toggleRead
    case reply, replyAll, forward
    case compose, search, close, undo
}

/// A key press, reduced to what the map decides on.
enum PadKey: Equatable {
    case character(String), up, down, escape
}

/// The iPad's keys, the desktop's letters. Mark done (e), Remind me (h),
/// Need reply (n), Pin (s) and Delete (⌘⌫) are not here: the open thread's
/// own buttons hold those keys (ThreadView's bars, `threadKey`), and in
/// this layout the highlighted row and the open thread are the same one —
/// a second binding would run the action twice.
enum PadKeys {
    static func resolve(_ key: PadKey, modifiers: EventModifiers = []) -> PadCommand? {
        // ⌘, ⌃ and ⌥ chords belong to the system and the menus.
        if !modifiers.isDisjoint(with: [.command, .control, .option]) { return nil }
        switch key {
        case .up: return .previous
        case .down: return .next
        case .escape: return .close
        case .character(let c):
            switch c {
            case "j": return .next
            case "k": return .previous
            case "#": return .delete
            case "u": return .toggleRead
            case "r": return .reply
            case "a": return .replyAll
            case "f": return .forward
            case "c": return .compose
            case "/": return .search
            case "z": return .undo
            default: return nil
            }
        }
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
    /// Bumped to hand the keyboard back to the list (Esc, a closed thread).
    var listFocusRequest = 0
    /// `/` was pressed: the Search column takes the caret once it is up.
    var wantsSearchFocus = false

    /// The list the open thread was opened from: another folder, account
    /// or tab is another list, and its rows are not "the next thread".
    private struct ListKey: Equatable {
        let tab: MainTab
        let view: MailView
        let accountId: String?
    }

    @ObservationIgnored private var openedIn: ListKey?
    /// Where the open thread sat in the list, so its neighbour takes its
    /// place when it leaves.
    @ObservationIgnored private var lastIndex: Int?
    /// Whether the open thread was a row of the list at all (one opened
    /// from a banner or a search may not be): only a row that was there
    /// can leave.
    @ObservationIgnored private var wasListed = false

    private func key(_ model: AppModel) -> ListKey {
        ListKey(tab: model.tab, view: model.view, accountId: model.selectedAccountId)
    }

    // MARK: Opening and closing

    /// Show a thread in the detail column and highlight its row.
    func open(_ row: ThreadRow, in model: AppModel) {
        openRow = row
        let index = model.listIndex(of: row.id)
        lastIndex = index ?? lastIndex
        wasListed = index != nil
        openedIn = key(model)
    }

    /// Back to the placeholder (Esc); the list has the keyboard again.
    func close() {
        openRow = nil
        wasListed = false
        listFocusRequest += 1
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
    private func advance(in model: AppModel) {
        let ids = model.flatRowIds
        guard let index = lastIndex, !ids.isEmpty,
              let next = model.row(forThreadId: ids[min(index, ids.count - 1)]) else {
            close()
            return
        }
        show(next, in: model)
    }

    /// The open thread's own bars did something that ends it (done,
    /// delete, mark unread, move): the next thread takes its place when
    /// its row left the list, else the placeholder comes back.
    func closeOpen(in model: AppModel) {
        guard let open = openRow else { return }
        if wasListed, model.listIndex(of: open.id) == nil { advance(in: model) } else { close() }
    }

    /// The list's order changed (`AppModel.rowOrderRevision`). An open
    /// thread whose row left the same list — done on another device, a
    /// reminder set from a banner — hands over to the next one; a list
    /// that is another list altogether just closes it.
    func rowsChanged(in model: AppModel) {
        guard let open = openRow else { return }
        if let index = model.listIndex(of: open.id) {
            lastIndex = index
            wasListed = true
            return
        }
        guard wasListed else { return }
        guard openedIn == key(model) else {
            close()
            return
        }
        advance(in: model)
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
        case .reply, .replyAll:
            guard let row else { return }
            let all = command == .replyAll
            IntentDonations.replied(row, all: all, in: model)
            Task { try? await model.openReply(to: row, all: all, body: nil) }
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
