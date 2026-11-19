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

    /// The answer shows on the invitation while its send stands, and goes
    /// with the send's Undo.
    @Test func anInvitationsAnswerIsKeptUntilItsSendIsUndone() {
        var draft = SendDraft()
        draft.to = ["organizer@acme.test"]
        model.answerInvite(.accepted, with: draft, threadId: "t1", from: "me@work.test")
        #expect(model.inviteAnswers["t1"]?.answer == .accepted)
        model.toast?.undo?()
        #expect(model.inviteAnswers["t1"] == nil)
    }

    /// The phone's Settings is a sheet: the question opens once it closed.
    @Test func askFromSettingsWaitsForTheSheetToClose() {
        model.showSettings = true
        model.askFromSettings()
        #expect(!model.showSettings && model.askSheet == nil)
        model.settingsClosed()
        #expect(model.askSheet != nil)
        // With no Settings sheet up (the Mac's page) it opens at once.
        model.askSheet = nil
        model.askFromSettings()
        #expect(model.askSheet != nil)
        model.settingsClosed() // nothing waiting: nothing more opens
    }

    /// The composer's link alert: a bare host gets https://, nothing typed
    /// is no link.
    @Test func theLinkAlertsAddressBecomesAURL() {
        #expect(ComposeView.linkAddress(from: " example.com/a ")?.absoluteString == "https://example.com/a")
        #expect(ComposeView.linkAddress(from: "http://example.com")?.absoluteString == "http://example.com")
        #expect(ComposeView.linkAddress(from: "   ") == nil)
    }

    /// docs/specs/read-status.md R8, R10, R25: read status is off for
    /// every account, cannot be turned on in a build without a relay, and
    /// with one is one mailbox's switch.
    @Test func readStatusIsOffByDefaultAndDisabledWithoutARelay() async throws {
        // Whatever relay the test host's build carries, start without.
        try engine.configureRelay(url: "")
        #expect(model.accounts.count == 2)
        #expect(model.accounts.allSatisfy { !$0.readStatus })
        #expect(!model.readStatusAvailable)
        let first = model.accounts[0]
        await model.setReadStatus(true, for: first)
        #expect(model.accounts.allSatisfy { !$0.readStatus })
        // Off is never refused.
        await model.setReadStatus(false, for: first)
        #expect(model.accounts.allSatisfy { !$0.readStatus })

        #expect(throws: (any Error).self) { try engine.configureRelay(url: "http://plain.example") }
        try engine.configureRelay(url: "https://relay.example")
        #expect(model.readStatusAvailable)
        await model.setReadStatus(true, for: first)
        #expect(model.accounts[0].readStatus)
        #expect(!model.accounts[1].readStatus)
        // Another setting of the account does not take it back.
        model.updateAccount(model.accounts[0], signature: "— P")
        #expect(model.accounts[0].readStatus)
        await model.setReadStatus(false, for: model.accounts[0])
        #expect(!model.accounts[0].readStatus)
    }

    /// The row is in Settings, and its footer says what the app and the
    /// relay do — the sentences the spec's privacy table holds it to.
    @Test func theReadStatusRowSaysWhatItDoes() {
        #expect(ReadStatusSetting.isShown)
        #expect(ReadStatusSetting.title == "Read status")
        #expect(ReadStatusSetting.unavailable == "Not available in this build")
        let footer = ReadStatusSetting.footer
        for part in ["invisible picture", "a small relay records", "never who or where", "never the message itself",
                     "30 days", "require their consent", "Apple Mail hides opens", "Gmail on the web",
                     "Turning this off stops it on this device at once",
                     "asks the relay to delete what it holds for this account",
                     "your other devices follow when they next sync",
                     "Removing the account asks the relay for the same deletion",
                     "stays on that device until the account is removed from it",
                     "left to expire within 30 days"] {
            #expect(footer.contains(part), "\(part)")
        }
    }

    /// R15, R16: a message asks to be tracked only when a composer showed
    /// its switch and it is on, the account it goes from has read status
    /// on, and the build has a relay. A draft no composer touched carries
    /// no choice and is never tracked.
    @Test func trackOpensDefaultsOnOnlyWhenTheAccountsSettingIsOn() throws {
        #expect(SendDraft().trackOpens == nil)
        var on = model.accounts[0]
        on.readStatus = true
        #expect(!AppModel.tracksOpens(SendDraft(), account: on, available: true))
        // As the composer hands it over: the switch, which starts on.
        var draft = SendDraft()
        draft.trackOpens = true
        let off = model.accounts[1]
        #expect(AppModel.tracksOpens(draft, account: on, available: true))
        #expect(!AppModel.tracksOpens(draft, account: off, available: true))
        #expect(!AppModel.tracksOpens(draft, account: on, available: false))
        #expect(!AppModel.tracksOpens(draft, account: nil, available: true))
        var declined = draft
        declined.trackOpens = false
        #expect(!AppModel.tracksOpens(declined, account: on, available: true))
    }

    /// R15: the choice follows the From account — the same draft is
    /// tracked from the account with read status on and not from the other.
    @Test func changingFromReevaluatesTrackOpens() async throws {
        try engine.configureRelay(url: "https://relay.example")
        await model.setReadStatus(true, for: model.accounts[0])
        let tracked = model.accounts[0].id, untracked = model.accounts[1].id
        var draft = SendDraft()
        draft.trackOpens = true
        #expect(model.tracksOpens(draft, from: tracked))
        #expect(!model.tracksOpens(draft, from: untracked))
        #expect(!model.tracksOpens(draft, from: "nobody@x.test"))
        // Turned off again: the next message from it is not tracked.
        await model.setReadStatus(false, for: model.accounts[0])
        #expect(!model.tracksOpens(draft, from: tracked))
    }

    /// R16: what a message waiting to be sent carries is the choice as it
    /// stood when the user let it go — a setting turned on afterwards
    /// does not track it.
    @Test func aScheduledMessageKeepsTheChoiceMadeWhenItWasSent() async throws {
        try engine.configureRelay(url: "https://relay.example")
        let account = model.accounts[0]
        var draft = SendDraft()
        draft.to = ["ana@acme.test"]
        draft.trackOpens = true
        model.sendLater(draft, from: account.id, at: Date().addingTimeInterval(3_600))
        #expect(model.scheduledSends.last?.draft.trackOpens == false)
        await model.setReadStatus(true, for: account)
        #expect(model.scheduledSends.last?.draft.trackOpens == false)
        // Scheduled with the setting on, it is.
        var second = SendDraft()
        second.to = ["ana@acme.test"]
        second.trackOpens = true
        model.sendLater(second, from: account.id, at: Date().addingTimeInterval(7_200))
        #expect(model.scheduledSends.last?.draft.trackOpens == true)
    }

    /// S1: mail that never passes a composer is not tracked, even from an
    /// account with read status on — an unsubscribe request (a draft made
    /// from a mailto link), an invitation's answer, a saved draft a
    /// Shortcut sends. Only what a composer hands over carries a choice.
    @Test func mailSentWithoutAComposerIsNotTracked() async throws {
        try engine.configureRelay(url: "https://relay.example")
        let account = model.accounts[0]
        await model.setReadStatus(true, for: account)
        // The three ways mail is sent with no composer shown.
        let unsubscribe = SendDraft(mailto: try #require(URL(string: "mailto:leave@list.test?subject=unsubscribe")))
        var answer = SendDraft()
        answer.to = ["organizer@acme.test"]
        answer.subject = "Accepted: Lunch"
        var saved = SendDraft()
        saved.to = ["ana@acme.test"]
        saved.draftSaved = true
        for draft in [unsubscribe, answer, saved] {
            #expect(draft.trackOpens == nil)
            #expect(!model.tracksOpens(draft, from: account.id))
        }
        // Scheduled without a composer's choice: stored as untracked.
        model.sendLater(saved, from: account.id, at: Date().addingTimeInterval(3_600))
        #expect(model.scheduledSends.last?.draft.trackOpens == false)
        // The same draft out of a composer, switch on, is tracked; switched off, not.
        var composed = answer
        composed.trackOpens = true
        #expect(model.tracksOpens(composed, from: account.id))
        composed.trackOpens = false
        #expect(!model.tracksOpens(composed, from: account.id))
    }

    /// R7: Recent Opens is read from the store when the sheet opens,
    /// newest open first, for the account the app is filtered to; a row
    /// opens its thread at that message and closes the sheet.
    @Test func recentOpensAreNewestFirstAndRespectTheAccountFilter() async throws {
        let now = Date()
        let (work, personal) = ("me@work.test", "me@personal.test")
        #expect(model.recentOpens.isEmpty && !model.recentOpensLoaded)
        engine.recordOpen(messageId: "t1-m1", threadId: "t1", accountId: work, subject: "Q4 roadmap review",
                          recipients: ["Priya Nair"], at: now.addingTimeInterval(-3_600))
        engine.recordOpen(messageId: "t2-m1", threadId: "t2", accountId: personal, subject: "Weekend ride?",
                          recipients: ["Tomáš", "Ana"], at: now.addingTimeInterval(-600))
        // Opened again later: the same row, moved up.
        engine.recordOpen(messageId: "t1-m1", threadId: "t1", accountId: work, subject: "Q4 roadmap review",
                          recipients: ["Priya Nair"], at: now.addingTimeInterval(-60))

        model.showSidebar = true
        model.showRecentOpens()
        #expect(model.recentOpensSheet != nil && !model.showSidebar)
        await model.loadRecentOpens()
        #expect(model.recentOpensLoaded)
        #expect(model.recentOpens.map(\.messageId) == ["t1-m1", "t2-m1"])
        #expect(model.recentOpens[0].opens == 2)
        #expect(RecentOpens.who(model.recentOpens[1]) == "One of 2 recipients")

        // One account's.
        model.selectedAccountId = personal
        await model.loadRecentOpens()
        #expect(model.recentOpens.map(\.messageId) == ["t2-m1"])
        model.selectedAccountId = nil
        await model.loadRecentOpens()

        // A row: the sheet closes and its thread opens at that message.
        model.open(model.recentOpens[0])
        #expect(model.recentOpensSheet == nil)
        #expect(model.pendingThreadId == "t1")
        #expect(model.pendingMessageId == "t1-m1")
        // A plain open of a thread forgets a message left over.
        model.openThread(id: "t3")
        #expect(model.pendingMessageId == nil)

        // An account that is removed takes its rows with it.
        await model.removeAccount(try #require(model.accounts.first { $0.id == work }))
        await model.loadRecentOpens()
        #expect(model.recentOpens.map(\.messageId) == ["t2-m1"])
    }

    /// Having a relay is not being able to push: the Mac build carries the
    /// relay for read status and has no push entitlement, so "New mail
    /// (push)" is never offered there.
    @Test func pushIsOfferedOnlyWhereTheAppCanBePushedTo() {
        #if os(macOS)
        #expect(!RemoteNotifications.isSupported)
        #expect(!model.push.canEnable)
        #expect(!model.push.enabled)
        #else
        #expect(RemoteNotifications.isSupported)
        #expect(model.push.canEnable == model.push.isBaked)
        #endif
    }

    /// The sign-in is offered by an empty list only while no account is
    /// connected (the sample inbox has two).
    @Test func theSignInIsOfferedOnlyWithNoAccount() {
        #expect(!model.accounts.isEmpty)
        #expect(model.connectFirstAccount == nil)
    }

    /// The composer's trash: gone at once, and Undo opens the composer on
    /// the message again, as one no Gmail draft stands behind.
    @Test func aDiscardedDraftComesBackWithUndo() throws {
        var draft = SendDraft()
        draft.to = ["ana@acme.test"]
        draft.subject = "Lunch"
        draft.draftSaved = true
        model.discardDraft(draft, savedFrom: "me@work.test")
        #expect(model.toast?.text == "Draft discarded")
        #expect(model.composeDraft == nil)
        model.toast?.undo?()
        let reopened = try #require(model.composeDraft)
        #expect(reopened.subject == "Lunch" && reopened.draftKey == draft.draftKey && !reopened.draftSaved)
    }

    /// A draft deleted under its thread: Undo saves it back, and the thread
    /// shows it again at once.
    @Test func aDeletedThreadDraftIsSavedBackWithUndo() throws {
        var draft = SendDraft()
        draft.to = ["ana@acme.test"]
        draft.bodyText = "On it."
        draft.replyToThreadId = "t1"
        model.saveDraft(draft, from: "me@work.test")
        #expect(model.unsyncedDrafts["t1"]?.draftKey == draft.draftKey)
        model.discardSavedDraft(draft, from: "me@work.test")
        #expect(model.toast?.text == "Draft deleted")
        #expect(model.unsyncedDrafts["t1"] == nil)
        model.toast?.undo?()
        #expect(model.unsyncedDrafts["t1"]?.bodyText == "On it.")
    }

    /// The inbox bar's AI circle: a menu only when there are two things in it.
    @Test func theInboxBarFoldsTheAIIntoOneCircle() {
        #expect(MailListScreen.aiBarItem(summarize: true, ask: true) == .menu)
        #expect(MailListScreen.aiBarItem(summarize: true, ask: false) == .summarize)
        #expect(MailListScreen.aiBarItem(summarize: false, ask: true) == .ask)
        #expect(MailListScreen.aiBarItem(summarize: false, ask: false) == .nothing)
    }

    /// The list's title, as VoiceOver reads it: the number is reminders in
    /// Remind me and threads in Need reply, not "unread".
    @Test func theListTitleSaysWhatItsNumberCounts() {
        #expect(ListTitle.spoken(title: "Inbox", count: 3, tab: .inbox) == "Inbox, 3 unread")
        #expect(ListTitle.spoken(title: "Inbox", count: 0, tab: .inbox) == "Inbox")
        #expect(ListTitle.spoken(title: "Remind me", count: 1, tab: .scheduled) == "Remind me, 1 reminder")
        #expect(ListTitle.spoken(title: "Remind me", count: 4, tab: .scheduled) == "Remind me, 4 reminders")
        #expect(ListTitle.spoken(title: "Need reply", count: 2, tab: .needReply) == "Need reply, 2 waiting for a reply")
    }

    /// With VoiceOver on a toast stays long enough to reach its Undo; a
    /// send's toast keeps the send's own window.
    @Test func toastsStayLongerForVoiceOver() {
        #expect(AppModel.toastDuration(.seconds(5), holds: false, voiceOver: false) == .seconds(5))
        #expect(AppModel.toastDuration(.seconds(5), holds: false, voiceOver: true) == AppModel.voiceOverToastDuration)
        #expect(AppModel.toastDuration(.seconds(30), holds: false, voiceOver: true) == .seconds(30))
        #expect(AppModel.toastDuration(.seconds(5), holds: true, voiceOver: true) == .seconds(5))
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

    /// The sidebar lists the user's own labels of the account on screen:
    /// no Gmail category, no other account's label (the phone listed both).
    @Test func sidebarLeavesOutCategoriesAndOtherAccounts() {
        let all = [MailLabelItem(id: "Label_1", accountId: "x", name: "Travel"),
                   MailLabelItem(id: "CATEGORY_PROMOTIONS", accountId: "x", name: "Promotions"),
                   MailLabelItem(id: "Label_2", accountId: "y", name: "Clients")]
        #expect(AppModel.visibleLabels(all, accountId: nil).map(\.id) == ["Label_1", "Label_2"])
        #expect(AppModel.visibleLabels(all, accountId: "x").map(\.id) == ["Label_1"])
        let r = AppModel.sidebarLabels(all, accountId: "y", pinned: [], expanded: false, current: nil)
        #expect(r.shown.map(\.id) == ["Label_2"] && r.hidden == 0)
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
        // A body with such a picture has its parts listed though the thread
        // has no attachment; a plain one does not.
        let banner = MessageItem(id: "m", fromName: "Ana", fromAddress: "ana@acme.test", to: ["me"], date: Date(),
                                 snippet: "", bodyHTML: html, bodyText: nil, isRead: true, isMine: false, isDraft: false)
        #expect(ThreadDetail.showsInlinePictures([makeMessage("p", text: "plain"), banner]))
        #expect(!ThreadDetail.showsInlinePictures([makeMessage("p", text: "plain")]))
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
