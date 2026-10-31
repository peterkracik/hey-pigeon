// The Mac window's pure parts over the mock engine: the keyboard map (the
// desktop's keys and the g-chords), the selection's moves and auto-advance,
// the palette filter and the Mac widgets' deep links.

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
