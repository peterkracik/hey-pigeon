// AppModel over the mock engine: the list grouping, navigation, the
// optimistic actions and their undo, the deferred send, the cached
// reminder list the badge and widgets read, the debounced free-text prefs
// and the people the Search pickers offer.

import Foundation
import Testing
@testable import HeyPigeon

@MainActor
struct AppModelTests {
    let model: AppModel
    let engine: MockEngine

    init() {
        engine = MockEngine()
        model = AppModel(engine: engine)
    }

    // MARK: Grouping

    @Test func inboxGroupsPinnedFirstThenByDay() {
        let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let rows = [
            makeRow("today", at: now.addingTimeInterval(-600)),
            makeRow("pinned", at: now.addingTimeInterval(-20 * 86_400), starred: true),
            makeRow("week", at: now.addingTimeInterval(-3 * 86_400)),
            makeRow("old", at: now.addingTimeInterval(-30 * 86_400)),
        ]
        let groups = AppModel.group(rows, view: .inbox, searching: false, triageFilterId: nil, pinList: true, now: now)
        #expect(groups.map(\.title) == ["Pinned", "Today", "Last 7 days", "Older"])
        #expect(groups[0].isPinned && groups[0].rows.map(\.id) == ["pinned"])
        // Pin list off, or another folder: the pinned row sits in its day.
        let flat = AppModel.group(rows, view: .inbox, searching: false, triageFilterId: nil, pinList: false, now: now)
        #expect(flat.map(\.title) == ["Today", "Last 7 days", "Older"])
        #expect(AppModel.group(rows, view: .starred, searching: false, triageFilterId: nil, pinList: true, now: now).first?.title == "Today")
    }

    @Test func scheduledGroupsByDueDateAndTheLabelFilterNarrows() {
        let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let rows = [
            makeRow("late", scheduledAt: now.addingTimeInterval(-2 * 86_400)),
            makeRow("soon", scheduledAt: now.addingTimeInterval(3_600), triage: ["tl1"]),
            makeRow("later", scheduledAt: now.addingTimeInterval(20 * 86_400), triage: ["tl1"]),
        ]
        let groups = AppModel.group(rows, view: .scheduled, searching: false, triageFilterId: nil, pinList: true, now: now)
        #expect(groups.map(\.title) == ["Overdue", "Today", "Later"])
        let filtered = AppModel.group(rows, view: .scheduled, searching: false, triageFilterId: "tl1", pinList: true, now: now)
        #expect(filtered.flatMap(\.rows).map(\.id) == ["soon", "later"])
        // A search ignores the filter and the due buckets.
        let searching = AppModel.group(rows, view: .scheduled, searching: true, triageFilterId: "tl1", pinList: true, now: now)
        #expect(searching.flatMap(\.rows).count == 3)
    }

    @Test func uniqueKeepsTheFirstOfEachThread() {
        let rows = [makeRow("a"), makeRow("b"), makeRow("a", subject: "dup")]
        #expect(AppModel.unique(rows).map(\.id) == ["a", "b"])
        #expect(AppModel.unique(rows)[0].subject == "Subject")
    }

    @Test func groupSummaryKeyFollowsTheActiveRows() {
        let g = RowGroup(title: "Today", rows: [makeRow("a"), makeRow("b", archived: true)], isPinned: false)
        #expect(g.active.map(\.id) == ["a"])
        #expect(g.summaryKey == "Today|a")
    }

    // MARK: Navigation

    @Test func navigateSetsTabAndFolderAndClearsTheLabelFilter() {
        model.triageFilterId = "tl1"
        model.navigate(to: .inbox, folder: .starred)
        #expect(model.tab == .inbox && model.folder == .starred && model.view == .starred)
        #expect(model.triageFilterId == nil)
        #expect(model.rows.map(\.id) == ["t4"]) // the one starred sample thread
        model.navigate(to: .scheduled)
        #expect(model.view == .scheduled)
        #expect(model.folder == .starred) // the Inbox tab keeps its folder
    }

    @Test func showClosesSheetsAndPicksTheTab() {
        model.showSettings = true
        model.showSidebar = true
        model.show(.needReply)
        #expect(model.tab == .needReply && !model.showSettings && !model.showSidebar)
        model.show(.archive)
        #expect(model.tab == .inbox && model.folder == .archive)
    }

    // MARK: Actions

    @Test func markDoneSlidesTheRowOutAndUndoBringsItBack() async throws {
        let row = try #require(model.rows.first { $0.id == "t3" })
        model.markDone(row)
        #expect(!model.rows.contains { $0.id == "t3" }) // optimistic, before the engine answers
        #expect(model.toast?.text == "Marked done")
        try await Task.sleep(for: .milliseconds(50))
        #expect(try engine.threadRow(id: "t3")?.isDone == true)
        model.toast?.undo?()
        try await Task.sleep(for: .milliseconds(50))
        #expect(try engine.threadRow(id: "t3")?.isDone == false)
        #expect(model.rows.contains { $0.id == "t3" })
    }

    @Test func undoneSendReopensTheComposerAndNeverSends() throws {
        var draft = SendDraft()
        draft.to = ["ana@acme.test"]
        draft.subject = "Lunch"
        model.send(draft, from: "me@work.test")
        #expect(model.toast?.text == "Sending · to ana@acme.test")
        #expect(model.composeDraft == nil)
        model.toast?.undo?()
        let reopened = try #require(model.composeDraft)
        #expect(reopened.subject == "Lunch" && reopened.fromAccountId == "me@work.test")
        // A second Undo (a stale toast) must not reopen it twice.
        model.composeDraft = nil
        model.toast?.undo?()
        #expect(model.composeDraft == nil)
    }

    @Test func reminderListIsCachedForTheBadgeAndTheWidgets() throws {
        #expect(model.scheduledAcrossAccounts.isEmpty && model.dueCount == 0)
        try engine.setReminder(threadId: "t2", at: Date().addingTimeInterval(-60), onlyIfNoReply: false)
        try engine.setReminder(threadId: "t3", at: Date().addingTimeInterval(3_600), onlyIfNoReply: false)
        #expect(Set(model.scheduledAcrossAccounts.map(\.id)) == ["t2", "t3"])
        #expect(model.scheduledCount == 2 && model.dueCount == 1)
        // One account: the counts narrow, the cross-account cache does not.
        model.selectedAccountId = "me@work.test"
        #expect(model.scheduledCount == 1 && model.dueCount == 0)
        #expect(model.scheduledAcrossAccounts.count == 2)
    }

    @Test func remindMovesTheThreadToScheduled() throws {
        let row = try #require(try engine.threadRow(id: "t1"))
        model.remind(row, at: Date().addingTimeInterval(7_200), onlyIfNoReply: true)
        #expect(!model.rows.contains { $0.id == "t1" })
        #expect(model.toast?.text.hasPrefix("Will remind you") == true)
        model.navigate(to: .scheduled)
        #expect(model.rows.map(\.id) == ["t1"])
        model.run(.remind, on: try #require(try engine.threadRow(id: "t1"))) // a reminder there: the swipe removes it
        #expect(try engine.threadRow(id: "t1")?.scheduledAt == nil)
    }

    // MARK: Prefs

    @Test func triageRulesAreSavedOnceTypingPausesOrOnFlush() throws {
        model.triageRules = "N"
        model.triageRules = "Newsletters are done."
        #expect(try engine.prefs()["triage.rules"] == nil) // not on every keystroke
        model.flushPendingPrefs()
        #expect(try engine.prefs()["triage.rules"] as? String == "Newsletters are done.")
    }

    @Test func togglePrefsAreSavedAtOnce() throws {
        model.pinListEnabled = false
        model.swipeActions = [.done, .delete, .pin, .read]
        #expect(try engine.prefs()["pin_list"] as? Bool == false)
        #expect(try engine.prefs()["swipe_actions"] as? [String] == ["done", "delete", "pin", "unread"])
    }

    // MARK: Search

    @Test func peopleAreRankedByHowOftenTheyWrite() {
        let rows = [
            makeRow("1", from: "Ana", fromAddress: "Ana@acme.test"),
            makeRow("2", from: "Marek", fromAddress: "marek@acme.test"),
            makeRow("3", from: "Ana, Me (2)", fromAddress: "ana@acme.test"),
            makeRow("4", from: "Me", fromAddress: "me@work.test"),
            makeRow("5", from: "Me (3)", fromAddress: "bot@x.test"),
        ]
        let people = AppModel.people(from: rows, excluding: ["me@work.test"])
        #expect(people.map(\.person.address) == ["ana@acme.test", "marek@acme.test", "bot@x.test"])
        #expect(people[0].person.name == "Ana")
        #expect(people[2].person.name == "bot@x.test") // no name but the user's: the address
    }

    @Test func searchComposesFiltersWithTheTypedWords() {
        model.searchFilters.unreadOnly = true
        #expect(model.isSearching)
        #expect(Set(model.searchResults.map(\.id)) == ["t1", "t2"])
        model.searchText = "roadmap from:x"
        #expect(model.searchTerms == ["roadmap"]) // hand-typed operators are not underlined
        model.searchFilters = SearchFilters()
        model.searchText = ""
        #expect(!model.isSearching && model.searchResults.isEmpty)
    }

    @Test func recentSearchesDedupeAndCap() {
        model.clearRecentSearches()
        defer { model.clearRecentSearches() }
        for word in ["a", "b", "a", "c", "d", "e", "f", "g"] {
            model.searchText = word
            model.rememberSearch()
        }
        #expect(model.recentSearches.map(\.text) == ["g", "f", "e", "d", "c", "a"])
        model.searchText = "   "
        model.rememberSearch() // nothing typed, no filter: not kept
        #expect(model.recentSearches.count == 6)
    }
}
