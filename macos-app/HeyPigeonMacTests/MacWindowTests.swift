// The Mac window's pure parts over the mock engine: the keyboard map (the
// desktop's keys and the g-chords), the selection's moves and auto-advance,
// the palette filter and the Mac widgets' deep links.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import HeyPigeon

struct KeyboardMapTests {
    @Test func lettersMapToTheDesktopsActions() {
        #expect(KeyboardMap.resolve(.character("e")) == .run(.markDone))
        #expect(KeyboardMap.resolve(.character("h")) == .run(.remind))
        #expect(KeyboardMap.resolve(.character("n")) == .run(.needReply))
        #expect(KeyboardMap.resolve(.character("s")) == .run(.pin))
        #expect(KeyboardMap.resolve(.character("u")) == .run(.toggleRead))
        #expect(KeyboardMap.resolve(.character("#"), modifiers: .shift) == .run(.delete))
        #expect(KeyboardMap.resolve(.character("?"), modifiers: .shift) == .run(.shortcuts))
        #expect(KeyboardMap.resolve(.character("j")) == .run(.next))
        #expect(KeyboardMap.resolve(.down) == .run(.next))
        #expect(KeyboardMap.resolve(.character("k")) == .run(.previous))
        #expect(KeyboardMap.resolve(.return) == .run(.open))
        #expect(KeyboardMap.resolve(.escape) == .run(.escape))
        #expect(KeyboardMap.resolve(.delete) == .run(.delete))
        #expect(KeyboardMap.resolve(.character("/")) == .run(.search))
        #expect(KeyboardMap.resolve(.character("c")) == .run(.compose))
        #expect(KeyboardMap.resolve(.character("0")) == .run(.account(nil)))
        #expect(KeyboardMap.resolve(.character("2")) == .run(.account(1)))
        #expect(KeyboardMap.resolve(.character("q")) == .ignore)
        // The keys the pointer used to be needed for.
        #expect(KeyboardMap.resolve(.character(" ")) == .run(.peek))
        #expect(KeyboardMap.resolve(.character(" "), modifiers: .shift) == .run(.pageUp))
        #expect(KeyboardMap.resolve(.character("J"), modifiers: .shift) == .run(.extendNext))
        #expect(KeyboardMap.resolve(.character("K"), modifiers: .shift) == .run(.extendPrevious))
        #expect(KeyboardMap.resolve(.down, modifiers: .shift) == .run(.extendNext))
        #expect(KeyboardMap.resolve(.character("x")) == .run(.extendNext))
        #expect(KeyboardMap.resolve(.character("z")) == .run(.undo))
    }

    @Test func osChordsAreLeftToTheMenus() {
        #expect(KeyboardMap.resolve(.character("e"), modifiers: .command) == .ignore)
        #expect(KeyboardMap.resolve(.character("k"), modifiers: .control) == .ignore)
        #expect(KeyboardMap.resolve(.character("j"), modifiers: .option) == .ignore)
    }

    @Test func gArmsAChordAndTheNextKeyGoesSomewhere() {
        #expect(KeyboardMap.resolve(.character("g")) == .armChord)
        #expect(KeyboardMap.resolve(.character("i"), chordArmed: true) == .run(.go(.inbox)))
        #expect(KeyboardMap.resolve(.character("a"), chordArmed: true) == .run(.go(.archive)))
        #expect(KeyboardMap.resolve(.character("s"), chordArmed: true) == .run(.go(.scheduled)))
        #expect(KeyboardMap.resolve(.character("u"), chordArmed: true) == .run(.account(nil)))
        // Not a chord key: read on its own, as the desktop does (g, e = mark done).
        #expect(KeyboardMap.resolve(.character("e"), chordArmed: true) == .run(.markDone))
        // Without the chord, i is the thread summary.
        #expect(KeyboardMap.resolve(.character("i")) == .run(.summarizeThread))
    }
}

@MainActor
struct WindowStateTests {
    let model: AppModel
    let engine: MockEngine
    let state = WindowState()

    init() {
        engine = MockEngine()
        model = AppModel(engine: engine)
    }

    @Test func theSelectionGrowsFromTheKeyboardAndUndoTakesTheLastActionBack() {
        let ids = state.flatIds(model)
        state.run(.next, in: model)
        state.run(.extendNext, in: model)
        state.run(.extendNext, in: model)
        #expect(state.selection == Set(ids.prefix(3)))
        state.run(.selectAll, in: model)
        #expect(state.selection == Set(ids))
        // Done, then Z: the row is back.
        state.select(ids[1], in: model)
        state.run(.markDone, in: model)
        #expect(model.listIndex(of: ids[1]) == nil)
        #expect(model.canUndoLast)
        state.run(.undo, in: model)
        #expect(!model.canUndoLast)
    }

    @Test func movingWalksTheListInDisplayOrderAndClamps() {
        let ids = state.flatIds(model)
        #expect(ids.count == 8) // the sample inbox, the pinned row's group first
        #expect(ids.first == "t4") // Pinned comes before Today
        state.move(by: 1, in: model)
        #expect(state.selection == [ids[0]])
        state.move(by: 1, in: model)
        #expect(state.selection == [ids[1]])
        state.move(by: -5, in: model)
        #expect(state.selection == [ids[0]])
        state.move(by: 100, in: model)
        #expect(state.selection == [ids.last!])
        #expect(state.scrollTarget == ids.last)
    }

    @Test func aReplyOpensItsThreadToBeWrittenUnderIt() {
        let ids = state.flatIds(model)
        state.select(ids[1], in: model)
        #expect(state.path.isEmpty)
        state.run(.reply, in: model)
        #expect(state.path.last?.id == ids[1])
        // Pulled out into a window, the draft is the sheet's; a new draft starts under its thread again.
        var reply = SendDraft()
        reply.replyToThreadId = ids[1]
        model.composeDraft = reply
        model.composeDetached = true
        model.composeDraft = SendDraft.reply(to: makeMessage("m"), in: makeRow(ids[1]), all: false, history: nil)
        #expect(!model.composeDetached)
    }

    @Test func markDoneAdvancesToTheRowThatTookItsPlace() async throws {
        let ids = state.flatIds(model)
        state.select(ids[1], in: model)
        state.run(.markDone, in: model)
        // The optimistic removal already happened; the list tells the state.
        state.rowsChanged(in: model)
        let after = state.flatIds(model)
        #expect(!after.contains(ids[1]))
        #expect(state.selection == [after[1]])
        try await Task.sleep(for: .milliseconds(50))
        #expect(try engine.threadRow(id: ids[1])?.isDone == true)
    }

    @Test func aFolderSwitchClearsTheSelectionInsteadOfAdvancing() {
        let ids = state.flatIds(model)
        state.select(ids[0], in: model)
        state.run(.go(.starred), in: model)
        #expect(model.view == .starred)
        #expect(state.selection.isEmpty)
        // Rows changed with nothing pending: no auto-select.
        state.rowsChanged(in: model)
        #expect(state.selection.isEmpty)
    }

    @Test func openingMarksTheThreadReadAndEscapeComesBackToItsRow() async throws {
        let unread = try #require(try engine.threadRow(id: "t1"))
        #expect(!unread.isRead)
        state.select("t1", in: model)
        state.run(.open, in: model)
        #expect(state.path.map(\.id) == ["t1"] && state.isThreadOpen && state.canGoBack)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try engine.threadRow(id: "t1")?.isRead == true)
        // The toolbar's Back is the same step as Esc.
        state.run(.back, in: model)
        #expect(state.path.isEmpty && state.selection == ["t1"] && !state.canGoBack)
    }

    @Test func inAnOpenThreadMarkDoneOpensTheNextOne() async throws {
        let ids = state.flatIds(model)
        let second = try #require(model.row(forThreadId: ids[1]))
        state.open(second, in: model)
        state.run(.markDone, in: model)
        state.rowsChanged(in: model)
        let after = state.flatIds(model)
        #expect(!after.contains(ids[1]))
        #expect(state.path.last?.id == after[1] && state.selection == [after[1]])
    }

    @Test func jAndKWalkTheThreadsWhileOneIsOpen() throws {
        let ids = state.flatIds(model)
        state.open(try #require(model.row(forThreadId: ids[0])), in: model)
        state.run(.next, in: model)
        #expect(state.path.last?.id == ids[1])
        state.run(.previous, in: model)
        #expect(state.path.last?.id == ids[0])
        // The thread's own close with the row still listed: the list comes back.
        state.closeOpen(in: model)
        #expect(state.path.isEmpty && state.selection == [ids[0]])
    }

    @Test func aFolderSwitchClosesTheThreadAndTheDrawerToggles() throws {
        state.open(try #require(model.row(forThreadId: "t1")), in: model)
        state.run(.go(.starred), in: model)
        #expect(state.path.isEmpty && model.view == .starred)
        let before = state.sidebarVisible
        state.run(.toggleSidebar, in: model)
        #expect(state.sidebarVisible != before)
        state.run(.toggleSidebar, in: model)
        #expect(state.sidebarVisible == before)
    }

    @Test func aClickOpensTheRowInPlaceAndEscapeOrASecondClickFoldsIt() async throws {
        let row = try #require(try engine.threadRow(id: "t1"))
        #expect(!row.isRead)
        state.expand(row, in: model)
        #expect(state.expanded == "t1" && state.selection == ["t1"] && !state.isThreadOpen)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try engine.threadRow(id: "t1")?.isRead == true)
        state.expand(row, in: model)
        #expect(state.expanded == nil)
        state.expand(row, in: model)
        state.run(.escape, in: model)
        #expect(state.expanded == nil && state.selection == ["t1"])
        // Return from the open card: the full thread.
        state.expand(row, in: model)
        state.run(.open, in: model)
        #expect(state.path.map(\.id) == ["t1"])
    }

    @Test func theOpenCardGoesWithItsRow() throws {
        let ids = state.flatIds(model)
        let row = try #require(model.row(forThreadId: ids[0]))
        state.expand(row, in: model)
        state.run(.markDone, in: model)
        state.rowsChanged(in: model)
        #expect(state.expanded == nil)
        #expect(!state.flatIds(model).contains(ids[0]))
    }

    @Test func settingsIsAPageEscapeAndAFolderLeaveIt() {
        state.showSettings = true
        state.run(.escape, in: model)
        #expect(!state.showSettings)
        state.showSettings = true
        state.run(.go(.starred), in: model)
        #expect(!state.showSettings && model.view == .starred)
    }

    @Test func bundlesAreAPageWhoseOpenEmailIsTheWindows() throws {
        let t4 = try #require(model.row(forThreadId: "t4")) // the sample's Lisbon trip bundle, b1
        state.select("t1", in: model)
        state.openBundles(at: "b1")
        #expect(state.showBundles && state.bundlePath == [.bundle("b1")])
        #expect(state.bundlesTitle(in: model) == "Lisbon trip" && state.canGoBack)
        // The list's highlight is under the page, out of sight: no key acts on it.
        #expect(state.focusRow(in: model) == nil && !state.hasTarget && !state.isThreadOpen)
        state.run(.next, in: model)
        #expect(state.selection == ["t1"])
        // An email open in the bundle is the window's open thread.
        state.bundlePath.append(.thread(t4))
        #expect(state.isThreadOpen && state.focusRow(in: model)?.id == "t4")
        #expect(state.bundlesTitle(in: model) == nil)
        // A reply is written under it there, not in the main stack and not in a sheet.
        state.run(.reply, in: model)
        #expect(state.path.isEmpty && state.showBundles)
        var reply = SendDraft()
        reply.replyToThreadId = "t4"
        #expect(ComposePlacement.isInline(reply, openThread: state.openThread?.id, detached: false))
        // Esc walks the stack back, then leaves the page where the cursor was.
        state.run(.escape, in: model)
        #expect(state.bundlePath == [.bundle("b1")])
        state.run(.escape, in: model)
        #expect(state.bundlePath.isEmpty && state.showBundles && !state.canGoBack)
        state.run(.escape, in: model)
        #expect(!state.showBundles && state.selection == ["t1"])
    }

    @Test func markDoneInABundlesEmailGoesBackToTheBundleAndAFolderLeavesThePage() async throws {
        let t4 = try #require(model.row(forThreadId: "t4"))
        state.openBundles(at: "b1")
        state.bundlePath.append(.thread(t4))
        state.run(.markDone, in: model)
        #expect(state.bundlePath == [.bundle("b1")] && state.showBundles)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try engine.threadRow(id: "t4")?.isDone == true)
        // The window's list changed under the page: nothing auto-selects.
        state.rowsChanged(in: model)
        #expect(state.selection.isEmpty)
        // Opening a thread in the main stack leaves the page.
        state.openBundles(at: nil)
        #expect(state.showBundles && state.bundlesTitle(in: model) == "Bundles")
        state.open(try #require(model.row(forThreadId: "t1")), in: model)
        #expect(!state.showBundles && state.bundlePath.isEmpty && state.path.map(\.id) == ["t1"])
        // So does a folder switch.
        state.openBundles(at: "b1")
        state.run(.go(.starred), in: model)
        #expect(!state.showBundles && state.bundlePath.isEmpty && model.view == .starred)
    }

    @Test func aBundlesRowOpensInPlaceAndThenInThePagesStack() throws {
        let t4 = try #require(model.row(forThreadId: "t4")) // in the Lisbon trip bundle, b1
        let t1 = try #require(model.row(forThreadId: "t1"))
        state.select("t1", in: model)
        state.expand(t1, in: model)
        // The list's open card does not follow into the page.
        state.openBundles(at: "b1")
        #expect(state.expanded == nil)
        // A click on a bundle's row: its card, the list's cursor untouched.
        state.expand(t4, in: model)
        #expect(state.expanded == "t4" && state.selection == ["t1"] && state.bundlePath == [.bundle("b1")])
        // Esc closes the card before it walks the stack back.
        state.run(.escape, in: model)
        #expect(state.expanded == nil && state.bundlePath == [.bundle("b1")])
        // The row's arrow: the thread in the page's stack, not the window's.
        state.open(t4, in: model)
        #expect(state.showBundles && state.path.isEmpty && state.bundlePath == [.bundle("b1"), .thread(t4)])
        #expect(state.openThread?.id == "t4" && state.selection == ["t1"])
        // A reply from a row's card opens its thread there too.
        state.bundlePath = [.bundle("b1")]
        state.run(.reply, in: model, rows: [t4])
        #expect(state.showBundles && state.path.isEmpty && state.openThread?.id == "t4")
        // Another bundle picked in the sidebar takes the page, from its top.
        state.openBundles(at: "b2")
        #expect(state.bundlePath == [.bundle("b2")] && state.openThread == nil)
        // An email that is not this bundle's opens in the window's stack.
        state.open(t1, in: model)
        #expect(!state.showBundles && state.path.map(\.id) == ["t1"])
    }

    @Test func typingInAFieldIsNotAShortcut() {
        #expect(WindowState.isTyping(NSTextField()))
        #expect(WindowState.isTyping(NSTextView()))
        let body = NSTextView()
        body.isEditable = false
        #expect(!WindowState.isTyping(body)) // a message's selectable text
        #expect(!WindowState.isTyping(nil))
    }

    @Test func escapeClosesTheSearchPanelBeforeTheOpenCard() throws {
        state.expand(try #require(model.row(forThreadId: "t1")), in: model)
        state.run(.search, in: model)
        model.searchText = "roadmap"
        state.run(.escape, in: model)
        #expect(!state.searching && model.searchText.isEmpty)
        #expect(state.expanded == "t1")
    }

    @Test func thePaletteAndTheSearchAreOnePanelAtATime() {
        state.run(.search, in: model)
        state.run(.palette, in: model)
        #expect(state.showPalette && !state.searching)
        state.run(.search, in: model)
        #expect(state.searching && !state.showPalette)
        state.run(.palette, in: model)
        state.run(.escape, in: model)
        #expect(!state.showPalette && !state.searching)
    }

    @Test func escapeClearsTheSearchThenTheSelection() {
        model.searchText = "roadmap"
        state.select("t1", in: model)
        state.run(.escape, in: model)
        #expect(model.searchText.isEmpty && !model.isSearching)
        #expect(state.selection == ["t1"])
        state.run(.escape, in: model)
        #expect(state.selection.isEmpty)
    }

    @Test func labelAndMoveOpenThePaletteOnTheirStage() {
        state.run(.label, in: model)
        #expect(!state.showPalette) // nothing selected
        state.select("t1", in: model)
        state.run(.label, in: model)
        #expect(state.showPalette && state.paletteStage == .label)
        state.showPalette = false
        state.run(.move, in: model)
        #expect(state.showPalette && state.paletteStage == .move)
        // ⌘B needs no selection: the bundles stage, from anywhere.
        state.showPalette = false
        state.selection = []
        state.run(.bundles, in: model)
        #expect(state.showPalette && state.paletteStage == .bundles)
        // A bundle picked there is the Bundles page, the palette gone.
        state.openBundles(at: "b1")
        #expect(!state.showPalette && state.showBundles && state.bundlePath == [.bundle("b1")])
    }

    @Test func accountsSwitchByIndex() {
        state.run(.account(1), in: model)
        #expect(model.selectedAccountId == "me@work.test")
        state.run(.account(7), in: model) // out of range: nothing changes
        #expect(model.selectedAccountId == "me@work.test")
        state.run(.account(nil), in: model)
        #expect(model.selectedAccountId == nil)
    }

    @Test func rowActionsCarryTheirKeysAndGlyphs() throws {
        let row = try #require(try engine.threadRow(id: "t4")) // pinned
        #expect(RowAction.pin.glyph(for: row) == "pin.slash" && RowAction.pin.label(for: row) == "Unpin")
        #expect(RowAction.done.command == .markDone && RowAction.read.command == .toggleRead)
        #expect(RowAction.allCases.map(\.key) == ["E", "#", "H", "N", "S", "U"])
    }
}

struct PaletteFilterTests {
    @Test func everyWordMustMatchTitleOrSubtitle() {
        #expect(PaletteFilter.matches("", title: "Mark done"))
        #expect(PaletteFilter.matches("mark", title: "Mark done"))
        #expect(PaletteFilter.matches("done mark", title: "Mark done"))
        #expect(PaletteFilter.matches("road", title: "Reply", subtitle: "Q4 roadmap review"))
        #expect(!PaletteFilter.matches("mark x", title: "Mark done"))
        let items = [
            PaletteItem(id: "a", title: "Go to Inbox", systemImage: "tray") {},
            PaletteItem(id: "b", title: "Go to Trash", systemImage: "trash") {},
        ]
        #expect(PaletteFilter.filter(items, query: "tra").map(\.id) == ["b"])
        #expect(PaletteFilter.filter(items, query: "go").map(\.id) == ["a", "b"])
    }

    @Test func theBestMatchComesFirstAndRecentsWinATie() {
        let items = [
            PaletteItem(id: "reply", title: "Reply", subtitle: "Mark's notes", systemImage: "arrowshape.turn.up.left") {},
            PaletteItem(id: "unread", title: "Mark unread", systemImage: "envelope.badge") {},
            PaletteItem(id: "done", title: "Mark done", systemImage: "checkmark") {},
            PaletteItem(id: "inbox", title: "Go to Inbox", systemImage: "tray") {},
        ]
        // A title that starts with the words beats a subtitle that holds them.
        #expect(PaletteFilter.filter(items, query: "mark").map(\.id) == ["unread", "done", "reply"])
        // Run lately: ahead of an equally good match.
        #expect(PaletteFilter.filter(items, query: "mark", recents: ["done"]).map(\.id) == ["done", "unread", "reply"])
        // Initials find a command: "gti" is Go to Inbox, "mu" Mark unread.
        #expect(PaletteFilter.filter(items, query: "gti").map(\.id) == ["inbox"])
        #expect(PaletteFilter.filter(items, query: "mu").map(\.id) == ["unread"])
        // An empty palette opens on what was run lately.
        #expect(PaletteFilter.filter(items, query: "", recents: ["inbox", "done"]).map(\.id) == ["inbox", "done", "reply", "unread"])
        #expect(PaletteRecents.pushed("b", onto: ["a", "b", "c"]) == ["b", "a", "c"])
        #expect(PaletteRecents.pushed("z", onto: (0..<8).map(String.init)).count == PaletteRecents.limit)
    }
}

struct ShortcutsSheetTests {
    /// The bare keys the sheet shows outside the composer: "J · K" is J
    /// and K, "Space" is the space bar; chords and ⌘ keys are not bare.
    private var listed: [String] {
        ShortcutsSheet.groups.filter { $0.0 != "In the composer" }.flatMap(\.1).flatMap { row in
            row.0.components(separatedBy: " · ").compactMap { token -> String? in
                if token == "Space" { return " " }
                if token.hasPrefix("G then ") { return "g" }
                if token.hasPrefix("⇧"), token.count == 2 { return String(token.dropFirst()) }
                return token.count == 1 && token != "↩" && token != "⌫" ? token.lowercased() : nil
            }
        }
    }

    @Test func theSheetAndTheKeyboardMapAgree() {
        // Every key the sheet promises does something…
        for key in listed where Int(key) == nil {
            #expect(KeyboardMap.resolve(.character(key)) != .ignore, "the sheet lists \(key), the map ignores it")
        }
        // …and every key the map acts on is on the sheet.
        for key in KeyboardMap.characters {
            #expect(listed.contains(key.lowercased()), "the map handles \(key), the sheet does not list it")
        }
    }
}

@MainActor
struct ComposeExtrasTests {
    @Test func snippetsSurviveThePrefAndAScheduledSendCanBeTakenBack() {
        let snippets = [Snippet(id: "a", name: "Address", body: "Hlavná 1\nBratislava"), Snippet(id: "b", name: "No", body: "Thanks, but no.")]
        #expect(SnippetStore.decode(SnippetStore.encode(snippets)) == snippets)
        #expect(SnippetStore.decode("not json").isEmpty)

        let model = AppModel(engine: MockEngine())
        var draft = SendDraft()
        draft.to = ["ana@example.com"]
        draft.subject = "Friday"
        let at = Date().addingTimeInterval(3600)
        model.sendLater(draft, from: model.accounts.first?.id ?? "me@example.com", at: at)
        #expect(model.scheduledSends.map(\.id) == [draft.draftKey])
        // Not due yet: nothing leaves.
        model.sendDueScheduled(now: Date())
        #expect(model.scheduledSends.count == 1)
        // The toast's Undo (and Z) puts it back in the composer.
        #expect(model.undoLast())
        #expect(model.scheduledSends.isEmpty)
        #expect(model.composeDraft?.draftKey == draft.draftKey)
    }

    @Test func laterTodayIsOfferedOnlyBeforeTheEvening() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Bratislava"))
        let noon = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12)))
        let night = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 21)))
        #expect(SendLaterPreset.laterToday.date(now: noon, calendar: calendar) != nil)
        #expect(SendLaterPreset.laterToday.date(now: night, calendar: calendar) == nil)
        #expect(SendLaterPreset.inAnHour.date(now: noon, calendar: calendar) == noon.addingTimeInterval(3600))
    }
}

@MainActor
struct ThreadPrinterTests {
    @Test func theThreadPrintsAsOnePageWithNothingFromTheWeb() {
        let row = makeRow("t1", subject: "Q4 <plan> & budget")
        var first = makeMessage("m1", from: "Ana", address: "ana@acme.test", text: "Numbers attached.\n<b>not markup</b>")
        first.cc = ["ben@acme.test"]
        let html = ThreadPrinter.document(ThreadDetail(thread: row, messages: [first, makeMessage("m2", mine: true)]))
        #expect(html.contains("<h1>Q4 &lt;plan&gt; &amp; budget</h1>"))
        #expect(html.contains("Cc: ben@acme.test"))
        // A plain-text body is text, not markup; and no remote sources.
        #expect(html.contains("&lt;b&gt;not markup&lt;/b&gt;"))
        #expect(html.contains("default-src 'none'"))
        #expect(!html.contains("img-src *"))
    }
}

struct WindowRestorationTests {
    @Test func aViewSurvivesARelaunch() {
        for view in [MailView.inbox, .needReply, .archive, .label(id: "Label_7", name: "Receipts / 2026")] {
            #expect(WindowRestoration.decode(WindowRestoration.encode(view)) == view)
        }
        #expect(WindowRestoration.decode("nonsense") == nil)
    }
}

@MainActor
struct MacDeepLinkTests {
    @Test func doneAndSnoozeLinksActThroughTheModel() async throws {
        let engine = MockEngine()
        let model = AppModel(engine: engine)
        #expect(DeepLink(url: AppGroup.Link.done("t 3")) == .done(id: "t 3"))
        #expect(DeepLink(url: AppGroup.Link.snooze("t6", hours: 2)) == .snooze(id: "t6", hours: 2))
        #expect(DeepLink(url: URL(string: "heypigeon://snooze/t6")!) == .snooze(id: "t6", hours: 1))
        model.handle(.done(id: "t3"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(try engine.threadRow(id: "t3")?.isDone == true)
        #expect(model.toast?.undo != nil)
        try engine.setReminder(threadId: "t6", at: Date().addingTimeInterval(-60), onlyIfNoReply: false)
        model.handle(.snooze(id: "t6", hours: 3))
        let at = try #require(try engine.threadRow(id: "t6")?.scheduledAt)
        #expect(at > Date().addingTimeInterval(2.5 * 3600))
        #expect(model.tab == .scheduled)
    }

    @Test func sidebarBadgePrefersTheDueCount() {
        #expect(SidebarColumn.badgeText(count: 0, due: 0) == nil)
        #expect(SidebarColumn.badgeText(count: 3, due: 0) != nil)
        #expect(SidebarColumn.badgeText(count: 0, due: 2) != nil)
    }

    @Test func theToolbarsTabsStartPastTheSidebar() {
        // The item starts where the traffic lights end; it fills the rest
        // of the sidebar column, and nothing when it is already past it.
        #expect(SidebarInset.width(sidebar: 233, itemX: 80) == 153)
        #expect(SidebarInset.width(sidebar: 233, itemX: 0) == 233)
        #expect(SidebarInset.width(sidebar: 233, itemX: 300) == 0)
    }
}

// MARK: - Where a draft is written

struct ComposePlacementTests {
    @Test func aReplyGoesUnderItsThreadUnlessPulledOut() {
        var reply = SendDraft()
        reply.replyToThreadId = "t1"
        #expect(ComposePlacement.isInline(reply, openThread: "t1", detached: false))
        #expect(!ComposePlacement.isInline(reply, openThread: "t2", detached: false))
        #expect(ComposePlacement.isInline(reply, openThread: nil, threadWindows: ["t1"], detached: false))
        #expect(!ComposePlacement.isInline(reply, openThread: "t1", detached: true))
        // A new message or a forward has no thread to go under.
        #expect(!ComposePlacement.isInline(SendDraft(), openThread: "t1", detached: false))
    }
}

// MARK: - The composer's editor

/// The Mac editor's pure parts: text ⇄ html, what a draft opens on, and
/// how the page's messages land in the model (the page itself is a web
/// view the tests do not load).
@MainActor
struct MacComposeEditorTests {
    @Test func textBecomesParagraphsWithLineBreaks() {
        #expect(MacComposeEditor.html(fromText: "Hi <Ana>\nLine 2\n\nBye & co") == "<p>Hi &lt;Ana&gt;<br>Line 2</p><p>Bye &amp; co</p>")
        // The signature prefill: an empty first paragraph to type into.
        #expect(MacComposeEditor.html(fromText: "\n\nSig") == "<p><br></p><p>Sig</p>")
        #expect(MacComposeEditor.html(fromText: "") == "<p><br></p>")
        #expect(MacComposeEditor.html(fromText: "a\r\n\r\nb") == "<p>a</p><p>b</p>")
    }

    @Test func aDraftOpensOnItsHTMLElseItsText() {
        var d = SendDraft()
        d.bodyText = "Hello"
        let plain = MacComposeEditor(draft: d)
        #expect(plain.html == "<p>Hello</p>")
        #expect(plain.text == "Hello")
        #expect(plain.htmlPart == "<p>Hello</p>")
        // An undone send keeps the formatting it was sent with.
        d.bodyHTML = "<p><b>Hello</b></p>"
        #expect(MacComposeEditor(draft: d).html == "<p><b>Hello</b></p>")
        // An empty body sends no html part.
        #expect(MacComposeEditor(draft: SendDraft()).htmlPart == nil)
    }

    @Test func thePagesMessagesLandInTheModel() {
        let e = MacComposeEditor(draft: SendDraft())
        e.receive(["type": "change", "html": "<p>a</p>", "text": "a"])
        #expect(e.html == "<p>a</p>" && e.text == "a")
        e.receive(["type": "height", "value": 40.0])
        #expect(e.height == MacComposeEditor.minHeight) // never under the minimum
        e.receive(["type": "height", "value": 400.0])
        #expect(e.height == 400)
        e.receive(["type": "selection", "text": "a", "formats": ["bold"],
                   "rect": ["x": 10.0, "y": 20.0, "w": 30.0, "h": 16.0]])
        #expect(e.selection == MacComposeEditor.Selection(text: "a", rect: CGRect(x: 10, y: 20, width: 30, height: 16)))
        #expect(e.activeFormats == ["bold"])
        // The focus leaves (the AI panel's field): the toolbar's selection
        // goes, the one the AI works on stays.
        e.receive(["type": "blur"])
        #expect(e.selection == nil && e.savedSelection?.text == "a")
        // A caret placed somewhere ends it.
        e.receive(["type": "selection", "text": "", "formats": []])
        #expect(e.savedSelection == nil)
        var commands: [MacComposeEditor.Command] = []
        e.onCommand = { commands.append($0) }
        e.receive(["type": "command", "name": "send"])
        e.receive(["type": "command", "name": "ai"])
        e.receive(["type": "command", "name": "nope"])
        #expect(commands == [.send, .ai])
    }

    @Test func siriTakesTheTextOverAStaleMirror() {
        var d = SendDraft()
        d.bodyText = "Hello"
        d.bodyHTML = "<p>Hello</p>"
        let e = MacComposeEditor(draft: d)
        d.bodyText = "Friday at noon?"
        e.set(draft: d)
        #expect(e.text == "Friday at noon?" && e.html == "<p>Friday at noon?</p>")
    }

    @Test func scriptStringsAreJavaScriptLiterals() {
        #expect(MacComposeEditor.json("a \"b\"\n") == "\"a \\\"b\\\"\\n\"")
        #expect(MacComposeEditor.json("x\u{2028}y") == "\"x\\u2028y\"")
    }
}

