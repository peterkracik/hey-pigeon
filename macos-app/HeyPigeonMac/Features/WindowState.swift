// One window's state: the selected threads, the open sheets, the keyboard
// map and the actions behind every key, menu item, hover button and
// palette row. AppModel is one per process; this is one per window, so two
// windows can show two threads. Pure parts (the key map, the palette
// filter) are static so the tests can run them without a window.

import SwiftUI

/// Everything a key, a menu item, a hover button or the palette can do.
enum MailCommand: Hashable {
    case markDone, remind, needReply, pin, toggleRead, delete
    case reply, replyAll, forward
    case label, move
    case summarizeThread, draftReply
    case compose, search, palette, shortcuts, escape
    case next, previous, open, openInWindow
    /// Switch account: the index in `AppModel.accounts`, nil for all.
    case account(Int?)
    case go(MailView)
    case summarizeView, ask, triage, syncNow
}

/// A key press, reduced to what the map decides on.
enum MailKey: Equatable {
    case character(String), up, down, `return`, escape, delete
}

/// The desktop's keyboard map (desktop-app/src/App.svelte onKey), as a pure
/// function: a key and its modifiers in, a command out. `g` arms a chord
/// for a second — g-i inbox, g-a archive, g-s scheduled, g-n need reply,
/// g-d drafts, g-p pinned, g-t sent, g-u all accounts — and any other key
/// after it is read on its own, so g, e means "mark done".
enum KeyboardMap {
    enum Resolution: Equatable {
        case run(MailCommand), armChord, ignore
    }

    static let chordWindow: TimeInterval = 1.0

    static func resolve(_ key: MailKey, modifiers: EventModifiers = [], chordArmed: Bool = false) -> Resolution {
        // OS chords (⌘C, ⌃A, ⌥…) belong to the menus and the text fields.
        if !modifiers.isDisjoint(with: [.command, .control, .option]) { return .ignore }
        switch key {
        case .up: return .run(.previous)
        case .down: return .run(.next)
        case .return: return .run(.open)
        case .escape: return .run(.escape)
        case .delete: return .run(.delete)
        case .character(let c):
            if chordArmed, let command = chord(c) { return .run(command) }
            switch c {
            case "g": return .armChord
            case "?": return .run(.shortcuts)
            case "/": return .run(.search)
            case "c": return .run(.compose)
            case "e": return .run(.markDone)
            case "#": return .run(.delete)
            case "u": return .run(.toggleRead)
            case "s": return .run(.pin)
            case "r": return .run(.reply)
            case "a": return .run(.replyAll)
            case "f": return .run(.forward)
            case "n": return .run(.needReply)
            case "h": return .run(.remind)
            case "l": return .run(.label)
            case "v": return .run(.move)
            case "i": return .run(.summarizeThread)
            case "j": return .run(.next)
            case "k": return .run(.previous)
            case "0": return .run(.account(nil))
            default:
                if c.count == 1, let n = Int(c), (1...9).contains(n) { return .run(.account(n - 1)) }
                return .ignore
            }
        }
    }

    private static func chord(_ c: String) -> MailCommand? {
        switch c {
        case "i": .go(.inbox)
        case "a": .go(.archive)
        case "s": .go(.scheduled)
        case "n": .go(.needReply)
        case "d": .go(.drafts)
        case "p": .go(.starred)
        case "t": .go(.sent)
        case "u": .account(nil)
        default: nil
        }
    }
}

/// What the command palette opens on: everything, or straight into the
/// label / move pickers (the desktop's `l` and `v`).
enum PaletteStage: Equatable {
    case all, label, move
}

@MainActor
@Observable
final class WindowState: Equatable {
    /// Selected thread ids: one shows in the detail column, several show a
    /// batch bar.
    var selection: Set<String> = []
    var columns: NavigationSplitViewVisibility = .all
    var showPalette = false
    var paletteStage: PaletteStage = .all
    var showShortcuts = false
    var showTriage = false
    /// The list scrolls to this id after a keyboard move.
    var scrollTarget: String?
    /// Bumped to put the keyboard back on the list (after a chord changed
    /// the folder, after a sheet closed): the list column observes it.
    var listFocusRequest = 0
    /// Bumped to focus the search field (`/`).
    var searchFocusRequest = 0
    /// Installed by the window: opens a thread in its own window.
    @ObservationIgnored var openInWindow: ((String) -> Void)?

    @ObservationIgnored private var chordArmedAt: Date?
    /// Where the selection was in the flat list, so a row that leaves
    /// (done, delete, remind) hands the selection to its neighbour.
    @ObservationIgnored private var lastIndex: Int?
    /// Set by an action that may take the selected row out of the list;
    /// consumed by `rowsChanged`, so a folder switch never auto-selects.
    @ObservationIgnored private var pendingAdvance = false

    nonisolated static func == (a: WindowState, b: WindowState) -> Bool { a === b }

    // MARK: Selection

    /// The list's ids in display order.
    func flatIds(_ model: AppModel) -> [String] {
        model.groupedRows.flatMap { $0.rows.map(\.id) }
    }

    /// The one selected thread, from the list or the store.
    func selectedRow(in model: AppModel) -> ThreadRow? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return model.row(forThreadId: id)
    }

    func selectedRows(in model: AppModel) -> [ThreadRow] {
        selection.compactMap { model.row(forThreadId: $0) }
    }

    func select(_ id: String?, in model: AppModel) {
        selection = id.map { [$0] } ?? []
        lastIndex = id.flatMap { flatIds(model).firstIndex(of: $0) } ?? lastIndex
        scrollTarget = id
    }

    /// j / k / arrows: the neighbour, clamped; the first or last row when
    /// nothing is selected.
    func move(by delta: Int, in model: AppModel) {
        let ids = flatIds(model)
        guard !ids.isEmpty else { return }
        let current = selection.count == 1 ? selection.first.flatMap { ids.firstIndex(of: $0) } : nil
        let next: Int
        if let current {
            next = min(max(current + delta, 0), ids.count - 1)
        } else {
            next = delta > 0 ? 0 : ids.count - 1
        }
        select(ids[next], in: model)
    }

    /// The list clicked or arrowed to a row: remember where, and mark it
    /// read (a thread on screen is read, as on the phone's tap).
    func selectionChanged(in model: AppModel) {
        guard selection.count == 1, let id = selection.first else { return }
        if let i = flatIds(model).firstIndex(of: id) { lastIndex = i }
        if model.view != .drafts, let row = model.row(forThreadId: id), !row.isRead { model.markRead(row) }
    }

    /// The list's rows changed. When an action took the selected row out,
    /// the row now in its place takes the selection (Superhuman's
    /// auto-advance); when a folder switch did, the selection just clears.
    func rowsChanged(in model: AppModel) {
        let ids = flatIds(model)
        guard selection.count == 1, let id = selection.first, !ids.contains(id) else { return }
        guard pendingAdvance else { return }
        pendingAdvance = false
        guard !ids.isEmpty, let i = lastIndex else { selection = []; return }
        select(ids[min(i, ids.count - 1)], in: model)
    }

    /// The open thread's own bars did something that closes it (done,
    /// delete, mark unread, move): advance like a key would.
    func advance(in model: AppModel) {
        pendingAdvance = true
        rowsChanged(in: model)
    }

    // MARK: Keys

    func handle(_ press: KeyPress, model: AppModel) -> KeyPress.Result {
        let key: MailKey
        switch press.key {
        case .upArrow: key = .up
        case .downArrow: key = .down
        case .return: key = .return
        case .escape: key = .escape
        case .delete: key = .delete
        default: key = .character(press.characters)
        }
        let armed = chordArmedAt.map { Date().timeIntervalSince($0) < KeyboardMap.chordWindow } ?? false
        chordArmedAt = nil
        switch KeyboardMap.resolve(key, modifiers: press.modifiers, chordArmed: armed) {
        case .ignore:
            return .ignored
        case .armChord:
            chordArmedAt = Date()
            return .handled
        case .run(let command):
            run(command, in: model)
            return .handled
        }
    }

    // MARK: Actions

    /// Run a command on the selection (or on `rows`, for a hover bar or a
    /// trackpad swipe that names its row). Every mutation goes through
    /// AppModel, like the phone's swipes, so undo, the badge, the widgets
    /// and Spotlight stay consistent.
    func run(_ command: MailCommand, in model: AppModel, rows explicit: [ThreadRow]? = nil) {
        let rows = explicit ?? selectedRows(in: model)
        let row = explicit?.count == 1 ? explicit?.first : selectedRow(in: model)
        switch command {
        case .markDone:
            guard !rows.isEmpty else { return }
            pendingAdvance = true
            for r in rows {
                if !r.isDone { IntentDonations.archived(r, in: model) }
                model.toggleDone(r)
            }
        case .delete:
            guard !rows.isEmpty else { return }
            pendingAdvance = true
            for r in rows {
                IntentDonations.deleted(r, in: model)
                model.delete(r)
            }
        case .toggleRead:
            for r in rows { model.toggleRead(r) }
        case .pin:
            for r in rows { model.togglePin(r) }
        case .needReply:
            pendingAdvance = true
            for r in rows { model.toggleNeedsReply(r) }
        case .remind:
            guard let row else { return }
            pendingAdvance = true
            // A thread that already has a reminder: the key removes it, as the swipe does.
            model.run(.remind, on: row)
        case .reply, .replyAll:
            guard let row else { return }
            let all = command == .replyAll
            IntentDonations.replied(row, all: all, in: model)
            Task { try? await model.openReply(to: row, all: all, body: nil) }
        case .forward:
            guard let row else { return }
            Task { try? await model.openForward(of: row) }
        case .label:
            guard row != nil else { return }
            paletteStage = .label
            showPalette = true
        case .move:
            guard row != nil else { return }
            paletteStage = .move
            showPalette = true
        case .summarizeThread:
            guard let row else { return }
            summarize(row, in: model)
        case .draftReply:
            guard let row else { return }
            draftReply(for: row, in: model)
        case .compose:
            model.compose(SendDraft())
        case .search:
            searchFocusRequest += 1
        case .palette:
            paletteStage = .all
            showPalette = true
        case .shortcuts:
            showShortcuts.toggle()
        case .escape:
            if model.isSearching {
                model.searchText = ""
                model.searchFilters = SearchFilters()
                listFocusRequest += 1
            } else if !selection.isEmpty {
                selection = []
            }
        case .next:
            move(by: 1, in: model)
        case .previous:
            move(by: -1, in: model)
        case .open, .openInWindow:
            guard let row else { return }
            if model.view == .drafts { model.openDraft(row) } else { openInWindow?(row.id) }
        case .account(let index):
            if let index {
                guard index < model.accounts.count else { return }
                model.selectedAccountId = model.accounts[index].id
            } else {
                model.selectedAccountId = nil
            }
            listFocusRequest += 1
        case .go(let view):
            selection = []
            model.show(view)
            listFocusRequest += 1
        case .summarizeView:
            model.openViewSummary()
        case .ask:
            model.askSheet = AskPresentation()
        case .triage:
            showTriage = true
        case .syncNow:
            Task { await model.sync() }
        }
    }

    /// `i`: the thread summary, over the stored messages (the thread is on
    /// screen, so its bodies are local), fetched once when they are not.
    private func summarize(_ row: ThreadRow, in model: AppModel) {
        guard model.aiConfigured else { model.show("Connect an AI provider in Settings to summarize."); return }
        if let local = try? model.engine.threadLocal(id: row.id), !local.mail.isEmpty {
            model.openThreadSummary(row, messages: local.mail)
            return
        }
        Task {
            guard let detail = try? await model.engine.thread(id: row.id) else { return }
            model.openThreadSummary(row, messages: detail.mail)
        }
    }

    /// The thread view's sparkle, from the keyboard or the menu: the AI
    /// writes the reply body and the composer opens on it.
    private func draftReply(for row: ThreadRow, in model: AppModel) {
        guard model.aiConfigured else { model.show("Connect an AI provider in Settings to draft."); return }
        Task {
            do {
                guard let detail = try await model.engine.thread(id: row.id), detail.mail.last != nil else { return }
                let text = try await model.engine.aiDraftReply(subject: row.subject, history: detail.transcript, notes: nil)
                try await model.openReply(to: row, all: false, body: text)
            } catch {
                model.show(error.localizedDescription)
            }
        }
    }
}

// MARK: - Focused scene value

/// The key window's state, for the menu bar commands.
struct WindowStateKey: FocusedValueKey {
    typealias Value = WindowState
}

extension FocusedValues {
    var windowState: WindowState? {
        get { self[WindowStateKey.self] }
        set { self[WindowStateKey.self] = newValue }
    }
}

// MARK: - Row actions on the Mac

extension RowAction {
    /// The window command a swipe tier or a hover button runs.
    var command: MailCommand {
        switch self {
        case .done: .markDone
        case .delete: .delete
        case .remind: .remind
        case .needReply: .needReply
        case .pin: .pin
        case .read: .toggleRead
        }
    }

    /// The glyph for a row's current state (the phone's swipe panel words).
    func glyph(for row: ThreadRow) -> String {
        switch self {
        case .done: row.isDone ? "arrow.uturn.backward" : "checkmark"
        case .delete: "trash"
        case .remind: row.scheduledAt == nil ? "clock" : "clock.badge.xmark"
        case .needReply: "arrowshape.turn.up.left"
        case .pin: row.isPinned ? "pin.slash" : "pin"
        case .read: row.isRead ? "envelope.badge" : "envelope.open"
        }
    }

    func label(for row: ThreadRow) -> String {
        switch self {
        case .done: row.isDone ? "Mark not done" : "Mark done"
        case .delete: "Delete"
        case .remind: row.scheduledAt == nil ? "Remind me" : "Remove reminder"
        case .needReply: row.needsReply ? "Clear need reply" : "Need reply"
        case .pin: row.isPinned ? "Unpin" : "Pin"
        case .read: row.isRead ? "Mark unread" : "Mark read"
        }
    }

    /// The swipe panel's colour, as on the phone.
    var tint: Color {
        switch self {
        case .done: Theme.accent
        case .delete: Color(hex: 0xB34E2E)
        case .remind: Theme.navy700
        case .needReply: Color(hex: 0x2A6BAE)
        case .pin: Color(hex: 0xA9761E)
        case .read: Theme.navy500
        }
    }

    /// The bare key that runs it (the shortcuts sheet and tooltips).
    var key: String {
        switch self {
        case .done: "E"
        case .delete: "#"
        case .remind: "H"
        case .needReply: "N"
        case .pin: "S"
        case .read: "U"
        }
    }
}
