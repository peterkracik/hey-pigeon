// The intents through AppModel over the mock engine: what Siri does is
// what the swipe does. HEYPIGEON_MOCK is not needed — the model is built
// here with MockEngine directly, and AppModel.init registers it as
// AppModel.current, which is where the intents look.

import AppIntents
import Testing
@testable import HeyPigeon

@MainActor
struct IntentTests {
    let model: AppModel
    let engine: MockEngine

    init() {
        engine = MockEngine()
        model = AppModel(engine: engine)
    }

    private func entity(_ id: String) throws -> MailThreadEntity {
        let row = try #require(try engine.threadRow(id: id))
        return MailThreadEntity(row, account: model.account(for: row))
    }

    @Test func markDoneArchivesAndClearsFlags() async throws {
        try engine.setNeedsReply(threadId: "t1", true)
        var intent = MarkDoneIntent()
        intent.thread = try entity("t1")
        intent.done = true
        _ = try await intent.perform()
        // The mock applies the archive asynchronously, like the engine's outbox.
        try await Task.sleep(for: .milliseconds(50))
        let row = try #require(try engine.threadRow(id: "t1"))
        #expect(row.isDone)
        #expect(!row.needsReply)
    }

    @Test func markDoneIsIdempotent() async throws {
        var intent = MarkDoneIntent()
        intent.thread = try entity("t2")
        _ = try await intent.perform()
        _ = try await intent.perform()
        try await Task.sleep(for: .milliseconds(50))
        #expect(try engine.threadRow(id: "t2")?.isDone == true)
        intent.done = false
        _ = try await intent.perform()
        try await Task.sleep(for: .milliseconds(50))
        #expect(try engine.threadRow(id: "t2")?.isDone == false)
    }

    @Test func remindWithExplicitDateSetsTheReminder() async throws {
        let at = Date().addingTimeInterval(3_600)
        var intent = RemindMeIntent()
        intent.thread = try entity("t3")
        intent.when = .pickDate
        intent.date = at
        intent.onlyIfNoReply = true
        _ = try await intent.perform()
        let row = try #require(try engine.threadRow(id: "t3"))
        #expect(row.scheduledAt == at)
        #expect(row.isFollowUp)
        // Scheduled mail leaves the inbox.
        #expect(!(try engine.threads(in: .inbox, accountId: nil, before: nil, limit: 100)).contains { $0.id == "t3" })
    }

    @Test func remindWithPresetUsesTheSharedMaths() async throws {
        var intent = RemindMeIntent()
        intent.thread = try entity("t4")
        intent.when = .tomorrow
        _ = try await intent.perform()
        let row = try #require(try engine.threadRow(id: "t4"))
        #expect(row.scheduledAt == ReminderPreset.tomorrow.date())
    }

    @Test func needReplyPinAndReadAreExplicitSets() async throws {
        var need = NeedReplyIntent()
        need.thread = try entity("t5")
        need.on = true
        _ = try await need.perform()
        _ = try await need.perform()
        #expect(try engine.threadRow(id: "t5")?.needsReply == true)

        var pin = PinIntent()
        pin.thread = try entity("t5")
        pin.on = true
        _ = try await pin.perform()
        try await Task.sleep(for: .milliseconds(50))
        #expect(try engine.threadRow(id: "t5")?.isPinned == true)

        var read = MarkReadIntent()
        read.thread = try entity("t1")
        read.read = true
        _ = try await read.perform()
        try await Task.sleep(for: .milliseconds(50))
        #expect(try engine.threadRow(id: "t1")?.isRead == true)
    }

    @Test func whatNeedsReplyListsTheFlaggedThreads() async throws {
        try engine.setNeedsReply(threadId: "t2", true)
        try engine.setNeedsReply(threadId: "t6", true)
        let intent = WhatNeedsReplyIntent()
        let result = try await intent.perform()
        #expect(Set(result.value?.map(\.id) ?? []) == ["t2", "t6"])
    }

    @Test func whatsDueReturnsOnlyPastReminders() async throws {
        try engine.setReminder(threadId: "t7", at: Date().addingTimeInterval(-60), onlyIfNoReply: false)
        try engine.setReminder(threadId: "t8", at: Date().addingTimeInterval(86_400), onlyIfNoReply: false)
        let result = try await WhatsDueIntent().perform()
        #expect(result.value?.map(\.id) == ["t7"])
    }

    @Test func searchUsesTheEngineOperators() async throws {
        var intent = SearchMailIntent()
        intent.query = "from:priya"
        let result = try await intent.perform()
        #expect(result.value?.map(\.id) == ["t1"])
    }

    @Test func addLabelRefusesAnotherAccountsLabel() async throws {
        var intent = AddLabelIntent()
        intent.thread = try entity("t1") // work account
        intent.label = MailLabelEntity(MailLabelItem(id: "Label_2", accountId: "me@personal.test", name: "Travel"))
        await #expect(throws: IntentError.self) { _ = try await intent.perform() }
    }

    @Test func summarizeNeedsAnAIProvider() async throws {
        await #expect(throws: IntentError.self) { _ = try await SummarizeInboxIntent().perform() }
        try await engine.setAIKey("sk-test")
        model.reloadAccounts()
        let result = try await SummarizeInboxIntent().perform()
        #expect(result.value?.isEmpty == false)
    }

    @Test func composeOpensTheComposerWithoutSending() async throws {
        var intent = ComposeIntent()
        intent.to = ["ana@acme.test"]
        intent.subject = "Lunch"
        intent.body = "Tomorrow?"
        _ = try await intent.perform()
        let draft = try #require(model.composeDraft)
        #expect(draft.to == ["ana@acme.test"])
        #expect(draft.subject == "Lunch")
        #expect(draft.bodyText == "Tomorrow?")
    }

    @Test func replyPrefillsTheThreadsReply() async throws {
        var intent = ReplyIntent()
        intent.thread = try entity("t2")
        intent.body = "Yes, 8 works."
        _ = try await intent.perform()
        let draft = try #require(model.composeDraft)
        #expect(draft.replyToThreadId == "t2")
        #expect(draft.to == ["tomas@friends.test"])
        #expect(draft.subject == "Re: Weekend ride?")
        #expect(draft.bodyText == "Yes, 8 works.")
        #expect(draft.fromAccountId == "me@personal.test")
    }

    @Test func openFolderSwitchesTabsAndFolders() async throws {
        var intent = OpenFolderIntent()
        intent.folder = .scheduled
        _ = try await intent.perform()
        #expect(model.tab == .scheduled)
        intent.folder = .starred
        _ = try await intent.perform()
        #expect(model.tab == .inbox)
        #expect(model.folder == .starred)
    }

    @Test func entityCarriesTheRowAndIndexesNoBody() throws {
        let row = try #require(try engine.threadRow(id: "t1"))
        let e = MailThreadEntity(row, account: model.account(for: row))
        #expect(e.subject == "Q4 roadmap review")
        #expect(e.from == "Priya Nair")
        #expect(e.isUnread)
        #expect(e.account.name == "Work")
        let attrs = e.attributeSet
        #expect(attrs.title == "Q4 roadmap review")
        #expect(attrs.authorNames == ["Priya Nair"])
        #expect(attrs.contentDescription == row.snippet)
        #expect(attrs.containerIdentifier == "me@work.test")
    }

    @Test func threadQueryResolvesIdsSearchAndTheOpenThread() async throws {
        let q = MailThreadQuery()
        #expect(try await q.entities(for: ["t1", "nope"]).map(\.id) == ["t1"])
        #expect(try await q.entities(matching: "lisbon").map(\.id) == ["t4"])
        #expect(await q.defaultResult() == nil)
        let row = try #require(try engine.threadRow(id: "t5"))
        model.showThread(row)
        #expect(await q.defaultResult()?.id == "t5")
    }
}

struct ReminderPresetTests {
    @Test func presetsLandOnTheDayStartHour() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Bratislava")!
        // Wednesday 2026-10-28 10:00
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 10)))
        let tomorrow = try #require(ReminderPreset.tomorrow.date(now: now, dayStart: 9, calendar: cal))
        #expect(cal.dateComponents([.day, .hour], from: tomorrow) == DateComponents(day: 29, hour: 9))
        let weekend = try #require(ReminderPreset.thisWeekend.date(now: now, dayStart: 9, calendar: cal))
        #expect(cal.component(.weekday, from: weekend) == 7)
        let nextWeek = try #require(ReminderPreset.nextWeek.date(now: now, dayStart: 9, calendar: cal))
        #expect(cal.component(.weekday, from: nextWeek) == 2)
        #expect(nextWeek > weekend)
        let later = try #require(ReminderPreset.laterToday.date(now: now, dayStart: 9, calendar: cal))
        #expect(cal.component(.hour, from: later) == 18)
        // After 18:00 there is no "later today".
        let evening = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 19)))
        #expect(ReminderPreset.laterToday.date(now: evening, dayStart: 9, calendar: cal) == nil)
        #expect(!RemindWhen.offered(now: evening).contains(.laterToday))
        #expect(RemindWhen.offered(now: evening).last == .pickDate)
    }
}
