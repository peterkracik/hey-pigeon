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

    // MARK: Analysis

    @Test func analysisProgressMath() {
        let p = AnalysisProgress(done: 30, total: 120, isRunning: true)
        #expect(p.isActive && p.isVisible && p.remaining == 90 && p.fraction == 0.25)
        #expect(!AnalysisProgress.idle.isActive && AnalysisProgress.idle.fraction == 0)
        // A couple of new emails is not worth a bar.
        #expect(!AnalysisProgress(done: 0, total: AnalysisProgress.visibleFrom - 1).isVisible)
        #expect(AnalysisProgress(done: 9, total: 3).remaining == 0)
    }

    /// "Reanalyze all emails" runs the pass to the end while in front: the
    /// progress climbs email by email, then the model goes idle.
    @Test func reanalyzeRunsThePassToTheEnd() async throws {
        try engine.setAutoTriage(true)
        var seen: [AnalysisProgress] = []
        let forward = engine.onAnalysisProgress
        engine.onAnalysisProgress = { p in
            seen.append(p)
            forward?(p)
        }
        try model.reanalyzeAllEmails()
        await model.analyzePending()
        #expect(model.analysis == .idle)
        let total = try #require(seen.first?.total)
        #expect(total > MockEngine.analysisBatch, "the sample inbox spans more than one round")
        #expect(seen.contains(AnalysisProgress(done: total, total: total, isRunning: true)))
        // Between rounds the pass pauses with the rest still to do.
        #expect(seen.contains(AnalysisProgress(done: MockEngine.analysisBatch, total: total)))
    }

    // MARK: Reloading

    /// The engine's change notices share one reload a moment later, read off
    /// the main actor: a sync round notifies several times in a row.
    @Test func changeNoticesShareOneReload() async {
        let before = model.reloadCount
        for _ in 0..<5 { engine.onThreadsUpdated?() }
        #expect(model.reloadCount == before) // not on this turn
        await model.settleReloads()
        #expect(model.reloadCount == before + 1)
    }

    /// A reload that finds the store unchanged leaves the rows alone (no
    /// redraw, no animation); one that finds a change moves them.
    @Test func aReloadThatMovesNothingLeavesTheRowsAlone() async throws {
        let generation = model.listGeneration
        model.reload()
        engine.onThreadsUpdated?()
        await model.settleReloads()
        #expect(model.listGeneration == generation)
        try engine.setNeedsReply(threadId: "t1", true)
        await model.settleReloads()
        #expect(model.listGeneration > generation)
        #expect(!model.rows.contains { $0.id == "t1" })
    }

    /// A reload keeps the pages the user scrolled through (it used to cut
    /// the list back to the first page under the finger); another view
    /// starts over at one page.
    @Test func reloadKeepsTheLoadedPages() async throws {
        let base = Date().addingTimeInterval(-30 * 86_400)
        engine.insert((0..<120).map { i in makeRow("old\(i)", at: base.addingTimeInterval(-Double(i) * 60)) })
        await model.settleReloads()
        let total = 128 // the sample inbox's 8 and these
        #expect(model.rows.count == AppModel.pageSize && model.hasMore)
        model.loadMoreIfNeeded(current: try #require(model.rows.last))
        #expect(model.rows.count == 2 * AppModel.pageSize && model.hasMore)
        model.loadMoreIfNeeded(current: try #require(model.rows.last))
        #expect(model.rows.count == total && !model.hasMore)
        model.reload()
        #expect(model.rows.count == total && !model.hasMore)
        try engine.setNeedsReply(threadId: "t1", true)
        await model.settleReloads()
        #expect(model.rows.count == total - 1 && !model.hasMore)
        model.navigate(to: .scheduled)
        model.navigate(to: .inbox)
        #expect(model.rows.count == AppModel.pageSize && model.hasMore)
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
        await model.settleReloads() // the engine's notice brings the row back
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

    /// "Marked done" used to replace "Sending · Undo": the send then had
    /// nothing left to stop it.
    @Test func aSendKeepsItsUndoWhileOtherToastsShow() throws {
        var draft = SendDraft()
        draft.to = ["ana@acme.test"]
        model.send(draft, from: "me@work.test")
        model.markDone(try #require(model.rows.first { $0.id == "t3" }))
        #expect(model.toast?.text == "Sending · to ana@acme.test")
        #expect(model.sideToast?.text == "Marked done")
        #expect(model.toasts.map(\.text) == ["Marked done", "Sending · to ana@acme.test"])
        model.toast?.undo?()
        #expect(model.composeDraft != nil)
        // Without a send in its window a toast replaces the last, as before.
        model.dismissToast(try #require(model.toast?.id))
        model.show("One")
        model.show("Two")
        #expect(model.toast?.text == "Two")
    }

    @Test func reminderListIsCachedForTheBadgeAndTheWidgets() async throws {
        #expect(model.scheduledAcrossAccounts.isEmpty && model.dueCount == 0)
        try engine.setReminder(threadId: "t2", at: Date().addingTimeInterval(-60), onlyIfNoReply: false)
        try engine.setReminder(threadId: "t3", at: Date().addingTimeInterval(3_600), onlyIfNoReply: false)
        await model.settleReloads()
        #expect(Set(model.scheduledAcrossAccounts.map(\.id)) == ["t2", "t3"])
        #expect(model.inboxUnreadAllAccounts == 1) // t1 stays unread; t2 left the inbox for Remind me
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

    // MARK: AI suggestions (the mock's t1 asks a question, t2 names a day)

    @Test func acceptingNeedReplyFlagsTheThreadAndDropsTheProposal() throws {
        let row = try #require(try engine.threadRow(id: "t1"))
        #expect(row.openSuggestion == .needsReply)
        model.acceptSuggestion(row)
        let after = try #require(try engine.threadRow(id: "t1"))
        #expect(after.needsReply && after.suggestion == nil)
        #expect(!model.rows.contains { $0.id == "t1" }) // moved to Need reply
    }

    @Test func acceptingRemindSetsTheProposedReminder() throws {
        let row = try #require(try engine.threadRow(id: "t2"))
        guard case .remind(let at) = row.openSuggestion else {
            Issue.record("t2 should propose a reminder")
            return
        }
        model.acceptSuggestion(row)
        let after = try #require(try engine.threadRow(id: "t2"))
        #expect(after.scheduledAt == at && after.suggestion == nil && !after.isFollowUp)
    }

    @Test func aPastReminderProposalAsksForATimeInstead() throws {
        let row = makeRow("t2", read: false)
        var stale = row
        stale.suggestion = .remind(at: Date().addingTimeInterval(-3_600))
        model.acceptSuggestion(stale)
        #expect(model.pendingRemind?.id == "t2")
        #expect(try engine.threadRow(id: "t2")?.scheduledAt == nil)
    }

    @Test func dismissingKeepsTheThreadWhereItIs() throws {
        let row = try #require(try engine.threadRow(id: "t1"))
        model.dismissSuggestion(row)
        let after = try #require(try engine.threadRow(id: "t1"))
        #expect(after.suggestion == nil && !after.needsReply && after.scheduledAt == nil)
        #expect(model.rows.contains { $0.id == "t1" })
    }

    @Test func aFlaggedOrDoneThreadOffersNoSuggestion() {
        var flagged = makeRow("a", needsReply: true)
        flagged.suggestion = .needsReply
        var done = makeRow("b", archived: true)
        done.suggestion = .needsReply
        var open = makeRow("c", read: false)
        open.suggestion = .needsReply
        #expect(flagged.openSuggestion == nil && done.openSuggestion == nil)
        #expect(open.openSuggestion == .needsReply)
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

    /// iOS only: the Mac has no Search tab and searches in the list it is on.
    @Test(.enabled(if: AppModel.searchHasOwnTab))
    func otherTabsShowTheirWholeListWhileASearchIsKept() {
        model.navigate(to: .search)
        model.searchFilters.unreadOnly = true
        let results = Set(model.groupedRows.flatMap(\.rows).map(\.id))
        #expect(results == Set(model.searchResults.map(\.id)))

        model.navigate(to: .inbox)
        #expect(!model.showsSearchResults)
        let inbox = Set(model.groupedRows.flatMap(\.rows).map(\.id))
        #expect(inbox == Set(model.rows.map(\.id)))
        #expect(inbox != results) // the read threads are back

        // The query is still there when the user comes back to Search.
        model.navigate(to: .search)
        #expect(model.showsSearchResults)
        #expect(Set(model.groupedRows.flatMap(\.rows).map(\.id)) == results)
        model.searchFilters = SearchFilters()
    }

    @Test func typedWordsSearchAfterAPauseAndTheNewestQueryWins() async throws {
        let subject = try #require(model.rows.first?.subject)
        let word = try #require(subject.split(separator: " ").first.map(String.init))
        model.searchText = "zzzz-no-such-word"
        model.searchText = word // within the typing pause: the first never runs
        #expect(model.isSearchPending)
        for _ in 0..<100 where model.isSearchPending { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.isSearchPending)
        #expect(!model.searchResults.isEmpty)
        model.searchText = ""
        #expect(!model.isSearchPending && model.searchResults.isEmpty)
    }

    @Test func sidebarShowsPinnedLabelsUntilExpanded() {
        let all = ["a", "b", "c", "d"].map { MailLabelItem(id: $0, accountId: "x", name: $0.uppercased()) }
        // Nothing pinned: nothing to hide.
        var r = AppModel.sidebarLabels(all, pinned: [], expanded: false, current: nil)
        #expect(r.shown.map(\.id) == ["a", "b", "c", "d"] && r.hidden == 0)
        // Pinned only, in the list's order; the open label stays in view.
        r = AppModel.sidebarLabels(all, pinned: ["c", "a"], expanded: false, current: "d")
        #expect(r.shown.map(\.id) == ["a", "c", "d"] && r.hidden == 1)
        // ••• opens the whole list.
        r = AppModel.sidebarLabels(all, pinned: ["c"], expanded: true, current: nil)
        #expect(r.shown.count == 4 && r.hidden == 0)
        // A pin for a label this list doesn't hold (another account) hides nothing.
        r = AppModel.sidebarLabels(all, pinned: ["zz"], expanded: false, current: nil)
        #expect(r.shown.count == 4)
    }

    @Test func pinningALabelIsASyncedPref() throws {
        let label = try #require(model.labels.first)
        model.togglePinned(label)
        #expect(model.pinnedLabelIds == [label.id])
        #expect(try engine.prefs()["sidebar.pinned_labels"] as? [String] == [label.id])
        model.togglePinned(label)
        #expect(model.pinnedLabelIds.isEmpty)
    }

    @Test func inlinePicturesSwapCidForData() {
        let html = #"<p>Hi</p><img src="cid:image001.png@01DB"><img src='CID:Sig%40x'><img src="cid:missing">"#
        #expect(InlineImages.references(in: html) == ["image001.png@01db", "sig@x", "missing"])
        let out = InlineImages.inlined(html, dataURIs: ["image001.png@01db": "data:image/png;base64,AA", "sig@x": "data:image/gif;base64,BB"])
        #expect(out == #"<p>Hi</p><img src="data:image/png;base64,AA"><img src='data:image/gif;base64,BB'><img src="cid:missing">"#)
        // Only web pictures need the per-sender "Load".
        #expect(!InlineImages.hasRemoteImages(html))
        #expect(InlineImages.hasRemoteImages(#"<IMG width=1 src="https://t.example/p.gif">"#))
        #expect(InlineImages.hasRemoteImages(#"<img src=//cdn.example/a.png>"#))
        // The chip for a picture the body shows goes away; a real file stays.
        let logo = AttachmentItem(threadId: "t", messageId: "m", attachmentId: "a", filename: "logo.png",
                                  mimeType: "image/png", size: 10, contentId: "Image001.png@01DB")
        let pdf = AttachmentItem(threadId: "t", messageId: "m", attachmentId: "b", filename: "x.pdf",
                                 mimeType: "application/pdf", size: 10)
        #expect(InlineImages.isShownInline(logo, in: html))
        #expect(!InlineImages.isShownInline(pdf, in: html))
    }

    @Test func loadRemoteImagesIsASyncedPref() throws {
        model.loadRemoteImages = true
        #expect(try engine.prefs()["mail.remote_images"] as? Bool == true)
        #expect(model.loadsImages(from: "anyone@x.test"))
        model.loadRemoteImages = false
    }

    @Test func alwaysLoadingASendersImagesIsSynced() throws {
        #expect(!model.loadsImages(from: "news@shop.test"))
        model.alwaysLoadImages(from: "News@Shop.test")
        #expect(model.loadsImages(from: "news@shop.test"))
        #expect(!model.loadsImages(from: "other@shop.test"))
        #expect(try engine.prefs()["mail.image_senders"] as? [String] == ["news@shop.test"])
        model.imageSenders = []
    }

    @Test func triageLabelsFollowTheUsersOrder() {
        let l = ["a", "b", "c", "d"].map { TriageLabelItem(id: $0, name: $0.uppercased()) }
        // Ordered ones first; a new label (d) and an unknown id (zz) don't break it.
        #expect(AppModel.orderedTriageLabels(l, by: ["c", "zz", "a"]).map(\.id) == ["c", "a", "b", "d"])
        #expect(AppModel.orderedTriageLabels(l, by: []).map(\.id) == ["a", "b", "c", "d"])
    }

    @Test func movingATriageLabelIsSynced() throws {
        let before = model.triageLabels.map(\.id)
        try #require(before.count >= 2)
        model.moveTriageLabels(from: [before.count - 1], to: 0)
        let after = model.triageLabels.map(\.id)
        #expect(after.first == before.last)
        #expect(try engine.prefs()["triage.label_order"] as? [String] == after)
        // A reload keeps the order.
        model.reloadAccounts()
        #expect(model.triageLabels.map(\.id) == after)
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
