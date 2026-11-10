// One window's state: the open thread, the highlighted rows, the folders
// drawer, the search, the sheets, the keyboard map and the actions behind
// every key, menu item, hover button and palette row. AppModel is one per
// process; this is one per window, so two windows can show two threads.
// Pure parts (the key map, the palette filter) are static so the tests can
// run them without a window.

import AppKit
import SwiftUI
import WebKit

/// Everything a key, a menu item, a hover button or the palette can do.
enum MailCommand: Hashable {
    case markDone, remind, needReply, pin, toggleRead, delete
    case reply, replyAll, forward
    case label, move
    case summarizeThread, draftReply
    case compose, search, palette, bundles, shortcuts, escape, back, toggleSidebar
    case next, previous, open, openInWindow
    /// Space: the highlighted row's preview in the list, a page down in a
    /// thread; ⇧Space a page up.
    case peek, pageUp
    /// ⇧J / ⇧K (and X): one more row into the selection; ⌘A: every row.
    case extendNext, extendPrevious, selectAll
    /// Z, Edit › Undo: take the last action back (AppModel.undoLast).
    case undo
    /// ⌘P: the thread on paper or as a PDF (ThreadPrinter).
    case print
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
    /// Every bare character the map acts on (the account digits aside):
    /// what the shortcuts sheet must list (the tests hold it to that).
    static let characters = ["g", "?", "/", "c", "e", "#", "u", "s", "r", "a", "f", "n", "h", "l", "v", "i", "j", "k", "x", "z", " "]

    static func resolve(_ key: MailKey, modifiers: EventModifiers = [], chordArmed: Bool = false) -> Resolution {
        // OS chords (⌘C, ⌃A, ⌥…) belong to the menus and the text fields.
        if !modifiers.isDisjoint(with: [.command, .control, .option]) { return .ignore }
        switch key {
        case .up: return .run(modifiers.contains(.shift) ? .extendPrevious : .previous)
        case .down: return .run(modifiers.contains(.shift) ? .extendNext : .next)
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
            case "J", "x": return .run(.extendNext)
            case "K": return .run(.extendPrevious)
            case " ": return .run(modifiers.contains(.shift) ? .pageUp : .peek)
            case "z": return .run(.undo)
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
    /// `bundles`: the bundles, most recently active first (⌘B).
    case all, label, move, bundles
}

@MainActor
@Observable
final class WindowState: Equatable {
    /// The thread on screen: the NavigationStack's path, at most one deep —
    /// the next thread replaces the one before it. The list is the root,
    /// as in the phone's MailListScreen.
    var path: [ThreadRow] = []
    /// The highlighted rows: one is the keyboard cursor (j / k, the row a
    /// thread was opened from), several (⌘-click, ⇧-click) show the batch bar.
    var selection: Set<String> = []
    /// The folders drawer; away, the list has the whole window. Remembered
    /// across launches.
    /// Hidden until asked for (a new key: the old one remembered the
    /// drawer open from when it was the default).
    var sidebarVisible: Bool = UserDefaults.standard.object(forKey: "sidebarShown") as? Bool ?? false {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: "sidebarShown") }
    }
    /// The row opened in place: a click shows its latest message under the
    /// row, the desktop's preview card, without leaving the list; its arrow
    /// (or Return) opens the full thread.
    var expanded: String?
    /// The list and the open thread side by side (View › Reading Pane, on
    /// a window wide enough; MainWindow keeps this current). A click or
    /// Space then opens the thread beside the list instead of in the row.
    var readingPane = false
    /// Settings in the content area, from ⌘, or the palette.
    var showSettings = false {
        // Settings opens on its root the next time.
        didSet { if !showSettings, !settingsPath.isEmpty { settingsPath = [] } }
    }
    /// The page pushed over Settings' root (AI, Triage, Siri triage): the
    /// shared SettingsView's stack, kept here so the window's Back, Esc
    /// and title follow it, as they follow a thread.
    var settingsPath: [SettingsRoute] = []
    /// Bundles — the list, one bundle, an email in it — as a page of the
    /// window in the list's place, as Settings is: the phone covers its
    /// screen, and a sheet here looked like a dialog over the window.
    var showBundles = false
    /// The Bundles page's stack (BundlesStack): a bundle, then an email in
    /// it. The window's, so the open email is the window's open thread.
    var bundlePath: [BundleRoute] = []
    /// The header shows the search field (`/`, the magnifier).
    var searching = false
    var showPalette = false
    var paletteStage: PaletteStage = .all
    var showShortcuts = false
    var showTriage = false
    /// The list scrolls to this id after a keyboard move.
    var scrollTarget: String?
    /// Bumped to put the keyboard back on the list (after a chord changed
    /// the folder, after a sheet closed): the list observes it.
    var listFocusRequest = 0
    /// Bumped to focus the search field (`/`).
    var searchFocusRequest = 0
    /// Installed by the window: opens a thread in its own window.
    @ObservationIgnored var openInWindow: ((String) -> Void)?

    @ObservationIgnored private var chordArmedAt: Date?
    /// Where the cursor was in the flat list, so a row that leaves (done,
    /// delete, remind) hands its place to its neighbour.
    @ObservationIgnored private var lastIndex: Int?
    /// Set by an action that may take the highlighted row out of the list;
    /// consumed by `rowsChanged`, so a folder switch never auto-selects.
    @ObservationIgnored private var pendingAdvance = false

    nonisolated static func == (a: WindowState, b: WindowState) -> Bool { a === b }

    // MARK: What a command acts on

    /// The thread on screen: the Bundles page's open email while the page
    /// is up (the main stack is under it, out of sight), else the main
    /// stack's.
    var openThread: ThreadRow? {
        if showBundles {
            if case .thread(let row)? = bundlePath.last { return row }
            return nil
        }
        return path.last
    }

    /// The Bundles page is up with an email open in it.
    private var bundleThreadOpen: Bool { showBundles && openThread != nil }

    /// A page is pushed over the list (a thread) or over the Bundles list
    /// (a bundle, an email in it): the toolbar's Back walks it back, as
    /// Esc and ⌘[ do (`run(.back)`). The stacks' own Back is hidden
    /// (`backInWindowToolbar`): it sat beside the traffic lights, over
    /// the sidebar.
    var canGoBack: Bool {
        if showSettings, !settingsPath.isEmpty { return true }
        return showBundles ? !bundlePath.isEmpty : !path.isEmpty
    }

    /// Esc or Back in Settings: a pushed page goes back to the root, the
    /// root leaves Settings.
    private func backInSettings() {
        if settingsPath.isEmpty { showSettings = false } else { settingsPath.removeLast() }
    }

    /// The open thread (live from the store), else the one highlighted
    /// row. On the Bundles page without an email open there is nothing:
    /// the list's highlight is under the page, and a key must not act on
    /// a row the user cannot see.
    func focusRow(in model: AppModel) -> ThreadRow? {
        if let open = openThread { return model.row(forThreadId: open.id) ?? open }
        return showBundles ? nil : selectedRow(in: model)
    }

    func focusRows(in model: AppModel) -> [ThreadRow] {
        if let open = openThread { return [model.row(forThreadId: open.id) ?? open] }
        return showBundles ? [] : selectedRows(in: model)
    }

    /// For the menus: something to act on at all, and exactly one thread.
    var hasTarget: Bool { openThread != nil || !showBundles && !selection.isEmpty }
    var hasOneTarget: Bool { openThread != nil || !showBundles && selection.count == 1 }
    var isThreadOpen: Bool { openThread != nil }

    // MARK: Selection

    /// The list's ids in display order.
    func flatIds(_ model: AppModel) -> [String] {
        model.flatRowIds
    }

    /// The one highlighted thread, from the list or the store.
    func selectedRow(in model: AppModel) -> ThreadRow? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return model.row(forThreadId: id)
    }

    func selectedRows(in model: AppModel) -> [ThreadRow] {
        selection.compactMap { model.row(forThreadId: $0) }
    }

    func select(_ id: String?, in model: AppModel) {
        selection = id.map { [$0] } ?? []
        lastIndex = id.flatMap { model.listIndex(of: $0) } ?? lastIndex
        scrollTarget = id
    }

    /// j / k / arrows: the neighbour, clamped; the first or last row when
    /// nothing is highlighted.
    func move(by delta: Int, in model: AppModel) {
        let ids = flatIds(model)
        guard !ids.isEmpty else { return }
        let current = selection.count == 1 ? selection.first.flatMap { model.listIndex(of: $0) } : nil
        let next: Int
        if let current {
            next = min(max(current + delta, 0), ids.count - 1)
        } else {
            next = delta > 0 ? 0 : ids.count - 1
        }
        select(ids[next], in: model)
    }

    /// ⌘-click: the row joins or leaves the selection.
    func toggle(_ id: String, in model: AppModel) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        lastIndex = model.listIndex(of: id) ?? lastIndex
    }

    /// ⇧-click: every row between the cursor and this one.
    func extend(to id: String, in model: AppModel) {
        let ids = flatIds(model)
        guard let to = model.listIndex(of: id) else { return }
        let from = lastIndex ?? to
        selection.formUnion(ids[min(from, to)...max(from, to)])
    }

    /// ⇧J / ⇧K / X: the row after (or before) the moving end joins the
    /// selection, so a run of rows can be gathered for the batch bar
    /// without the pointer. With nothing highlighted it starts like j / k.
    func extendSelection(by delta: Int, in model: AppModel) {
        let ids = flatIds(model)
        guard !ids.isEmpty else { return }
        guard !selection.isEmpty, let from = lastIndex, ids.indices.contains(from) else {
            move(by: delta, in: model)
            return
        }
        let to = min(max(from + delta, 0), ids.count - 1)
        selection.insert(ids[to])
        lastIndex = to
        scrollTarget = ids[to]
    }

    /// ⌘A: every row of the list.
    func selectAll(in model: AppModel) {
        selection = Set(flatIds(model))
    }

    // MARK: The open thread

    /// A click, Return, a notification: the thread opens in place of the
    /// list, is marked read like the phone's tap, and keeps the cursor on
    /// its row so Esc lands where the reader left. A draft opens the
    /// composer instead.
    func open(_ row: ThreadRow, in model: AppModel) {
        select(row.id, in: model)
        if model.view == .drafts { model.openDraft(row); return }
        if !row.isRead { model.markRead(row) }
        showSettings = false
        if showBundles { closeBundles() }
        path = [row]
    }

    /// A click on a row: its preview opens under it (marked read, like the
    /// phone's tap), or closes when it was the open one. A draft opens the
    /// composer instead.
    func expand(_ row: ThreadRow, in model: AppModel) {
        // Beside the list there is room for the whole thread.
        if readingPane { open(row, in: model); return }
        select(row.id, in: model)
        if expanded == row.id { expanded = nil; return }
        if model.view == .drafts { model.openDraft(row); return }
        if !row.isRead { model.markRead(row) }
        expanded = row.id
    }

    /// Back to the list (Esc, the header's arrow, ⌘[), the cursor still on
    /// the row. On the Bundles page, back from the email to its bundle.
    func close() {
        if showBundles {
            if case .thread? = bundlePath.last { bundlePath.removeLast() }
            return
        }
        path = []
        listFocusRequest += 1
    }

    // MARK: The Bundles page

    /// The Bundles page, on the list or straight on one bundle (the
    /// sidebar): in the list's place, over whatever the window showed, as
    /// Settings is. `AppModel.openBundles` lands here through MainWindow.
    func openBundles(at id: String?) {
        showSettings = false
        searching = false
        showPalette = false
        bundlePath = id.map { [.bundle($0)] } ?? []
        showBundles = true
    }

    /// The list again (Esc on the Bundles list, a tab, a folder, a thread
    /// opening in the main stack).
    func closeBundles() {
        showBundles = false
        bundlePath = []
        listFocusRequest += 1
    }

    /// Esc or ⌘[ on the Bundles page: one step back in its stack, and from
    /// its root the list.
    private func backInBundles() {
        if bundlePath.isEmpty { closeBundles() } else { bundlePath.removeLast() }
    }

    /// The Bundles page's name for the toolbar: the bundle's, "Bundles" on
    /// the list; none on an email, which the toolbar names as it names
    /// the window's open thread (MainToolbar.otherTitle).
    func bundlesTitle(in model: AppModel) -> String? {
        switch bundlePath.last {
        case .none: "Bundles"
        case .bundle(let id)?: model.bundle(id: id)?.name ?? "Bundle"
        case .thread?: nil
        }
    }

    /// Arm the list's auto-advance for an action that may take the
    /// highlighted row out — not on the Bundles page, whose list is not
    /// the window's.
    private func armAdvance() {
        pendingAdvance = !showBundles
    }

    /// The open thread's own bars did something that closes it (done,
    /// delete, mark unread, move): the next thread takes its place when its
    /// row left the list, else the list comes back.
    func closeOpen(in model: AppModel) {
        guard let open = path.last else { return }
        if model.listIndex(of: open.id) != nil { close() } else { advanceOpen(in: model) }
    }

    /// The palette is about to move the thread on (a folder chosen): in the
    /// list, the cursor may go to the row that takes its place; with a
    /// thread open nothing is needed, the next thread follows its row
    /// leaving the list (`rowsChanged`).
    func advance(in model: AppModel) {
        guard !isThreadOpen else { return }
        pendingAdvance = true
        rowsChanged(in: model)
    }

    /// The row the open thread came from is gone: its neighbour opens
    /// (Superhuman's auto-advance), or the list comes back when there is none.
    private func advanceOpen(in model: AppModel) {
        let ids = flatIds(model)
        if let i = lastIndex, !ids.isEmpty, let next = model.row(forThreadId: ids[min(i, ids.count - 1)]) {
            open(next, in: model)
        } else {
            selection = []
            close()
        }
    }

    /// The list's rows changed. With a thread open whose row left the list
    /// (done, delete, a reminder, a sync from another device), the next
    /// thread takes its place. In the list, an action that took the
    /// highlighted row out hands the highlight to the row now in its place;
    /// a folder switch just clears it.
    func rowsChanged(in model: AppModel) {
        let ids = flatIds(model)
        // The previewed row left (done, delete, a reminder): its card goes
        // with it; the highlight moves on below as for any row.
        if let open = expanded, !ids.contains(open) { expanded = nil }
        if let open = path.last {
            guard !ids.contains(open.id) else { return }
            pendingAdvance = false
            advanceOpen(in: model)
            return
        }
        guard selection.count == 1, let id = selection.first, !ids.contains(id) else { return }
        guard pendingAdvance else { return }
        pendingAdvance = false
        guard !ids.isEmpty, let i = lastIndex else { selection = []; return }
        select(ids[min(i, ids.count - 1)], in: model)
    }

    /// The search field closes and the list is the folder again.
    func endSearch(in model: AppModel) {
        searching = false
        model.searchText = ""
        model.searchFilters = SearchFilters()
        listFocusRequest += 1
    }

    // MARK: Keys

    func handle(_ press: KeyPress, model: AppModel) -> KeyPress.Result {
        // Typing belongs to the field being typed in. The handler sits on
        // the window as well as the list, and the window's saw every letter
        // of a search before the field did: "e" marked a row done. A text
        // field's editor (an NSText) as the first responder means typing.
        if Self.isTyping(NSApp.keyWindow?.firstResponder) { return .ignored }
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

    /// The first responder is a text editor: a field, or the composer's
    /// web view (EditorWebView). A message body's selectable, read-only
    /// text — and its web view — is not typing.
    static func isTyping(_ responder: NSResponder?) -> Bool {
        if responder is EditorWebView { return true }
        guard let text = responder as? NSTextView else { return responder is NSTextField }
        return text.isEditable
    }

    // MARK: Actions

    /// Run a command on the open thread or the highlighted rows (or on
    /// `rows`, for a hover bar or a trackpad swipe that names its row).
    /// Every mutation goes through AppModel, like the phone's swipes, so
    /// undo, the badge, the widgets and Spotlight stay consistent.
    func run(_ command: MailCommand, in model: AppModel, rows explicit: [ThreadRow]? = nil) {
        let rows = explicit ?? focusRows(in: model)
        let row = explicit?.count == 1 ? explicit?.first : focusRow(in: model)
        switch command {
        case .markDone:
            guard !rows.isEmpty else { return }
            armAdvance()
            for r in rows {
                if !r.isDone { IntentDonations.archived(r, in: model) }
                model.toggleDone(r)
            }
            // The bundle's email is done: back to the bundle, as its own
            // bars do; no list to auto-advance along.
            if bundleThreadOpen { close() }
        case .delete:
            guard !rows.isEmpty else { return }
            armAdvance()
            for r in rows {
                IntentDonations.deleted(r, in: model)
                model.delete(r)
            }
            if bundleThreadOpen { close() }
        case .toggleRead:
            // Marking the open thread unread closes it, as on the phone:
            // staying would only read it again.
            let closes = explicit == nil && isThreadOpen && rows.allSatisfy(\.isRead)
            for r in rows { model.toggleRead(r) }
            if closes { close() }
        case .pin:
            for r in rows { model.togglePin(r) }
        case .needReply:
            armAdvance()
            for r in rows { model.toggleNeedsReply(r) }
        case .remind:
            guard let row else { return }
            armAdvance()
            // A thread that already has a reminder: the key removes it, as the swipe does.
            model.run(.remind, on: row)
        case .reply, .replyAll:
            guard let row else { return }
            let all = command == .replyAll
            IntentDonations.replied(row, all: all, in: model)
            showThread(row, in: model)
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
            // The field is in the top bar, where an open thread shows its
            // title: the search takes the list back.
            showSettings = false
            showPalette = false
            if showBundles { closeBundles() }
            if !path.isEmpty { path = [] }
            searching = true
            searchFocusRequest += 1
        case .palette:
            if searching { endSearch(in: model) }
            paletteStage = .all
            showPalette = true
        case .bundles:
            // ⌘B: the palette on its bundles stage, the recent ones first;
            // one opens as the Bundles page.
            if searching { endSearch(in: model) }
            paletteStage = .bundles
            showPalette = true
        case .shortcuts:
            showShortcuts.toggle()
        case .escape:
            // The floating panels are over everything: they go first.
            if showPalette {
                showPalette = false
                listFocusRequest += 1
            } else if searching {
                endSearch(in: model)
            } else if showSettings {
                backInSettings()
                if !showSettings { listFocusRequest += 1 }
            } else if showBundles {
                backInBundles()
            } else if isThreadOpen {
                close()
            } else if expanded != nil {
                expanded = nil
            } else if model.isSearching {
                // The panel is gone (handled above) and its search is still
                // in the list.
                endSearch(in: model)
            } else if !selection.isEmpty {
                selection = []
            }
        case .back:
            if showSettings { backInSettings() } else if showBundles { backInBundles() } else if isThreadOpen { close() }
        case .toggleSidebar:
            sidebarVisible.toggle()
        case .next:
            // The Bundles page has no cursor: j / k walk the window's list.
            guard !showBundles else { return }
            move(by: 1, in: model)
            if isThreadOpen, let next = selectedRow(in: model) { open(next, in: model) }
        case .previous:
            guard !showBundles else { return }
            move(by: -1, in: model)
            if isThreadOpen, let previous = selectedRow(in: model) { open(previous, in: model) }
        case .peek:
            // In a thread Space pages, as in every reader; in the list it
            // opens (or closes) the highlighted row's preview, which only
            // a click could do.
            if isThreadOpen {
                WindowScroller.page(down: true)
            } else if !showBundles, let row = selectedRow(in: model) {
                expand(row, in: model)
            }
        case .pageUp:
            if isThreadOpen { WindowScroller.page(down: false) }
        case .extendNext:
            guard !showBundles, !isThreadOpen else { return }
            extendSelection(by: 1, in: model)
        case .extendPrevious:
            guard !showBundles, !isThreadOpen else { return }
            extendSelection(by: -1, in: model)
        case .selectAll:
            guard !showBundles, !isThreadOpen else { return }
            selectAll(in: model)
        case .undo:
            model.undoLast()
        case .print:
            guard let row else { return }
            let window = NSApp.keyWindow
            Task {
                // The stored copy when it is whole; else Gmail's, once.
                var detail = try? model.engine.threadLocal(id: row.id)
                let whole = detail?.mail.isEmpty == false
                    && detail?.mail.allSatisfy { $0.bodyHTML != nil || $0.bodyText != nil } == true
                if !whole { detail = (try? await model.engine.thread(id: row.id)) ?? detail }
                guard let detail, !detail.mail.isEmpty else {
                    model.show("Couldn't load the thread to print")
                    return
                }
                ThreadPrinter.print(detail, in: window)
            }
        case .open:
            // On the Bundles page the email is already open where it is.
            guard let row, !showBundles else { return }
            open(row, in: model)
        case .openInWindow:
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
            path = []
            expanded = nil
            showSettings = false
            if showBundles { closeBundles() }
            if searching || model.isSearching { endSearch(in: model) }
            model.show(view)
            listFocusRequest += 1
        case .summarizeView:
            model.openViewSummary()
        case .ask:
            model.askSheet = AskPresentation()
        case .triage:
            showTriage = true
        case .syncNow:
            Task { await model.sync(manual: true) }
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

    /// A reply is written under its thread (ThreadView's inline composer):
    /// the thread opens first when a reply starts from the list or a
    /// row's preview, as in Superhuman. Not in Drafts, where a row opens
    /// the composer itself; and an email open on the Bundles page is
    /// written under there.
    private func showThread(_ row: ThreadRow, in model: AppModel) {
        guard model.view != .drafts, openThread?.id != row.id else { return }
        open(row, in: model)
    }

    /// The thread view's sparkle, from the keyboard or the menu: the AI
    /// writes the reply body and the composer opens on it.
    private func draftReply(for row: ThreadRow, in model: AppModel) {
        guard model.aiConfigured else { model.show("Connect an AI provider in Settings to draft."); return }
        showThread(row, in: model)
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

// MARK: - Dragging rows

/// A row dragged out of the list, onto a label, a bundle or a folder in
/// the sidebar: its thread id (every highlighted row's when it is one of
/// them) as text only this app's drop targets read.
enum ThreadDrag {
    static let prefix = "heypigeon.threads:"

    static func payload(for id: String, selection: Set<String>) -> String {
        let ids = selection.contains(id) && selection.count > 1 ? selection.sorted() : [id]
        return prefix + ids.joined(separator: ",")
    }

    /// The thread ids in what was dropped; none for any other text.
    static func ids(in items: [String]) -> [String] {
        items.filter { $0.hasPrefix(prefix) }
            .flatMap { $0.dropFirst(prefix.count).split(separator: ",").map(String.init) }
    }
}

// MARK: - What the window showed, across launches

/// The folder on screen and the open thread, kept in the defaults so a
/// relaunch (an update installs on quit) comes back where the reader was
/// instead of at the top of the inbox.
enum WindowRestoration {
    static let viewKey = "window.view"
    static let threadKey = "window.thread"
    /// Once per process: a second window starts on the inbox.
    @MainActor static var restored = false

    private static let plain: [MailView] = [.inbox, .scheduled, .needReply, .starred, .drafts, .sent, .archive, .all, .spam, .trash]

    /// A folder by its case name; a label as its id and name.
    static func encode(_ view: MailView) -> String {
        if case .label(let id, let name) = view { return "label\u{1F}\(id)\u{1F}\(name)" }
        return String(describing: view)
    }

    static func decode(_ raw: String) -> MailView? {
        let parts = raw.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3, parts[0] == "label" { return .label(id: parts[1], name: parts[2]) }
        return plain.first { String(describing: $0) == raw }
    }
}

// MARK: - Paging the thread

/// Space in a thread: a page down (⇧Space: up) in the window's main
/// scroll view. The shared ThreadView owns its ScrollView, so the page is
/// asked of AppKit: the largest scroll view on screen that has something
/// to scroll, the one drawn last when two are the same size.
@MainActor
enum WindowScroller {
    static func page(down: Bool) {
        guard let root = NSApp.keyWindow?.contentView else { return }
        var best: NSScrollView?
        var bestArea: CGFloat = 0
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, !scroll.isHiddenOrHasHiddenAncestor, !scroll.visibleRect.isEmpty,
               let document = scroll.documentView, document.frame.height > scroll.contentView.bounds.height + 1 {
                let area = scroll.frame.width * scroll.frame.height
                if area >= bestArea {
                    best = scroll
                    bestArea = area
                }
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        if down { best?.pageDown(nil) } else { best?.pageUp(nil) }
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

    // The words, the glyph, the colour and the key are the phone's too:
    // ios-app/HeyPigeon/Shared/RowActionPresentation.swift.
}
