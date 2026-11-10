// The iPad's split layout without its views: the key map, and the open
// thread's moves over the mock inbox (j / k, auto-advance, a folder
// switch). The Mac compiles and runs these too: the state has no view.

import Foundation
import SwiftUI
import Testing
@testable import HeyPigeon

struct PadKeysTests {
    @Test func theDesktopsLettersMapToCommands() {
        #expect(PadKeys.command(for: "j") == .next)
        #expect(PadKeys.command(for: .downArrow) == .next)
        #expect(PadKeys.command(for: "k") == .previous)
        #expect(PadKeys.command(for: .upArrow) == .previous)
        #expect(PadKeys.command(for: "#") == .delete)
        #expect(PadKeys.command(for: "3", modifiers: .shift) == .delete)
        #expect(PadKeys.command(for: "u") == .toggleRead)
        #expect(PadKeys.command(for: "a") == .replyAll)
        #expect(PadKeys.command(for: "f") == .forward)
        #expect(PadKeys.command(for: "c") == .compose)
        #expect(PadKeys.command(for: "/") == .search)
        #expect(PadKeys.command(for: "z") == .undo)
        #expect(PadKeys.command(for: .escape) == .close)
    }

    @Test func theThreadsOwnKeysAndSystemChordsAreLeftAlone() {
        // e · h · n · s · r belong to the open thread's buttons (ThreadView).
        for key in ["e", "h", "n", "s", "r", "q"] as [KeyEquivalent] {
            #expect(PadKeys.command(for: key) == nil)
        }
        #expect(PadKeys.command(for: "c", modifiers: .command) == nil)
        #expect(PadKeys.command(for: "j", modifiers: .option) == nil)
        #expect(PadKeys.command(for: .downArrow, modifiers: .control) == nil)
        #expect(PadKeys.command(for: "3") == nil)
    }

    @Test func noKeyIsBoundTwice() {
        let keys = PadKeys.bindings.map { "\($0.key.character)|\($0.modifiers.rawValue)" }
        #expect(Set(keys).count == keys.count)
    }
}

@MainActor
struct PadStateTests {
    @Test func jAndKWalkTheListAndOpenWhatTheyLandOn() throws {
        let model = AppModel(engine: MockEngine())
        let state = PadState()
        let ids = model.flatRowIds
        try #require(ids.count >= 2)
        state.run(.next, in: model)
        #expect(state.openRow?.id == ids[0])
        #expect(state.scrollTarget == ids[0])
        state.run(.next, in: model)
        #expect(state.openRow?.id == ids[1])
        state.run(.previous, in: model)
        state.run(.previous, in: model) // clamped at the top
        #expect(state.openRow?.id == ids[0])
        state.run(.close, in: model)
        #expect(state.openRow == nil)
        // With nothing open, K starts from the bottom.
        state.run(.previous, in: model)
        #expect(state.openRow?.id == ids.last)
    }

    @Test func theNextThreadOpensWhenTheUserDealsWithTheOpenOne() throws {
        let model = AppModel(engine: MockEngine())
        let state = PadState()
        let ids = model.flatRowIds
        try #require(ids.count >= 2)
        let first = try #require(model.row(forThreadId: ids[0]))
        state.open(first, in: model)
        // Done from the thread's own bar: its row leaves, the next one opens.
        model.markDone(first)
        state.closeOpen(in: model)
        #expect(state.openRow?.id == ids[1])
        // Another folder is another list: nothing of it is "the next one".
        model.navigate(to: .inbox, folder: .trash)
        state.rowsChanged(in: model)
        state.closeOpen(in: model)
        #expect(state.openRow == nil)
    }

    /// A row that leaves on its own opens nothing and marks nothing read:
    /// a folder switch, a search typed with a thread open, another device.
    @Test func aListThatChangesOnItsOwnOpensNothing() throws {
        let model = AppModel(engine: MockEngine())
        let state = PadState()
        let ids = model.flatRowIds
        try #require(ids.count >= 3)
        let first = try #require(model.row(forThreadId: ids[0]))
        state.open(first, in: model)
        // The other rows' unread marks, before and after.
        let unreadBefore = model.rows.filter { !$0.isRead && $0.id != ids[0] }.map(\.id)
        // Done elsewhere: the row is gone from the list, the thread stays.
        model.markDone(first)
        state.rowsChanged(in: model)
        #expect(state.openRow?.id == ids[0])
        model.navigate(to: .inbox, folder: .trash)
        state.rowsChanged(in: model)
        #expect(state.openRow?.id == ids[0])
        model.navigate(to: .inbox, folder: .inbox)
        state.rowsChanged(in: model)
        #expect(state.openRow?.id == ids[0])
        #expect(model.rows.filter { !$0.isRead && $0.id != ids[0] }.map(\.id) == unreadBefore)
    }

    @Test func aThreadThatWasNeverInTheListDoesNotAdvance() throws {
        let model = AppModel(engine: MockEngine())
        let state = PadState()
        // Opened from a banner or a search: not a row of what is shown.
        state.open(makeRow("elsewhere"), in: model)
        state.rowsChanged(in: model)
        #expect(state.openRow?.id == "elsewhere")
        state.closeOpen(in: model)
        #expect(state.openRow == nil)
    }
}
