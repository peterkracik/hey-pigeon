// The iPad's split layout without its views: the key map, and the open
// thread's moves over the mock inbox (j / k, auto-advance, a folder
// switch). The Mac compiles and runs these too: the state has no view.

import Foundation
import SwiftUI
import Testing
@testable import HeyPigeon

struct PadKeysTests {
    @Test func theDesktopsLettersMapToCommands() {
        #expect(PadKeys.resolve(.character("j")) == .next)
        #expect(PadKeys.resolve(.down) == .next)
        #expect(PadKeys.resolve(.character("k")) == .previous)
        #expect(PadKeys.resolve(.up) == .previous)
        #expect(PadKeys.resolve(.character("#"), modifiers: .shift) == .delete)
        #expect(PadKeys.resolve(.character("u")) == .toggleRead)
        #expect(PadKeys.resolve(.character("r")) == .reply)
        #expect(PadKeys.resolve(.character("a")) == .replyAll)
        #expect(PadKeys.resolve(.character("f")) == .forward)
        #expect(PadKeys.resolve(.character("c")) == .compose)
        #expect(PadKeys.resolve(.character("/")) == .search)
        #expect(PadKeys.resolve(.character("z")) == .undo)
        #expect(PadKeys.resolve(.escape) == .close)
    }

    @Test func theThreadsOwnKeysAndSystemChordsAreLeftAlone() {
        // e · h · n · s belong to the open thread's buttons (ThreadView).
        for key in ["e", "h", "n", "s", "q"] {
            #expect(PadKeys.resolve(.character(key)) == nil)
        }
        #expect(PadKeys.resolve(.character("c"), modifiers: .command) == nil)
        #expect(PadKeys.resolve(.character("j"), modifiers: .option) == nil)
        #expect(PadKeys.resolve(.down, modifiers: .control) == nil)
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

    @Test func theNextThreadOpensWhenTheOpenOneLeavesTheList() throws {
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
        #expect(state.openRow == nil)
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
