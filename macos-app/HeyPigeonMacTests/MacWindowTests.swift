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
        #expect(state.path.map(\.id) == ["t1"] && state.isThreadOpen)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try engine.threadRow(id: "t1")?.isRead == true)
        state.run(.escape, in: model)
        #expect(state.path.isEmpty && state.selection == ["t1"])
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

