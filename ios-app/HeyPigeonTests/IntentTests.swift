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

    /// The index gets the participants, labels and body text when the store
    /// has them (a thread opened before), newest messages first and capped;
    /// a thread never opened indexes no body.
    @Test func entityIndexesLocalBodiesParticipantsAndLabels() async throws {
        let row = try #require(try engine.threadRow(id: "t5"))
        #expect(try engine.threadLocal(id: "t5")?.messages.isEmpty == true)
        #expect(SpotlightIndexer.entity(for: row, in: model).bodyText == nil)
        _ = try await engine.thread(id: "t5") // the first open brings the bodies
        let e = SpotlightIndexer.entity(for: row, in: model)
        let body = try #require(e.bodyText)
        #expect(body.contains("Ana:") && body.contains("Me:"))
        #expect(body.hasSuffix(row.snippet)) // the newest message ends the text
        #expect(e.participantAddresses.contains("ana@acme.test"))
        #expect(!e.participantAddresses.contains("me@work.test"))
        let attrs = e.attributeSet
        #expect(attrs.textContent == body)
        #expect(attrs.accountIdentifier == "me@work.test")
        #expect(attrs.recipientEmailAddresses?.contains("ana@acme.test") == true)
        #expect(e.searchableItem.uniqueIdentifier == "t5")
    }

    @Test func indexableBodyIsCappedNewestFirst() {
        func m(_ i: Int, _ text: String) -> MessageItem {
            MessageItem(id: "m\(i)", fromName: "A", fromAddress: "a@x", to: ["me"], date: Date(timeIntervalSince1970: Double(i)),
                        snippet: "", bodyHTML: nil, bodyText: text, isRead: true, isMine: false)
        }
        let long = String(repeating: "x", count: MailThreadEntity.bodyTextCap)
        let body = try? #require(MailThreadEntity.indexableBody([m(1, "first"), m(2, long), m(3, "last")]))
        #expect(body?.hasSuffix("A: last") == true)
        #expect(body?.contains("A: first") == false) // no room left after the long one
        #expect((body?.count ?? 0) <= MailThreadEntity.bodyTextCap + 10)
        #expect(MailThreadEntity.indexableBody([m(1, "   ")]) == nil)
    }

    @Test func askCitationsKeepOnlyKnownThreadsOnce() {
        let rows = InboxAsk.validCitations(["t2", "nope", "t2", "t1"], in: model)
        #expect(rows.map(\.id) == ["t2", "t1"])
        #expect(!InboxAsk.isAvailable(model) || AppleIntelligenceProvider.isAvailable)
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

/// The agentic triage's pure parts over the mock engine: the plan dedupes
/// and summarizes, applies through the same model methods as the swipes,
/// skips what is gone or already so; the tools' argument parsing; the
/// journal's persistence and grouping.
@MainActor
struct TriageAgentTests {
    let model: AppModel
    let engine: MockEngine

    init() {
        engine = MockEngine()
        model = AppModel(engine: engine)
    }

    @Test func planDedupesAndSummarizesTheBatch() {
        var plan = TriagePlan()
        #expect(plan.confirmationSummary == "Nothing to change.")
        #expect(plan.add(.markDone(threadId: "t3", subject: "CI")))
        #expect(!plan.add(.markDone(threadId: "t3", subject: "CI")))
        plan.add(.markDone(threadId: "t6", subject: "Receipt"))
        plan.add(.label(threadId: "t8", subject: "Invoice", labelId: "Label_2", labelName: "Travel", on: true))
        plan.add(.remind(threadId: "t4", subject: "Lisbon", at: Date().addingTimeInterval(86_400), onlyIfNoReply: false))
        #expect(plan.confirmationSummary == "Mark done 2, label 1 and remind 1?")
        #expect(plan.proposals.count == 4)
        var one = TriagePlan()
        one.add(.needReply(threadId: "t1", subject: "Roadmap", on: true))
        #expect(one.confirmationSummary == "Flag need reply 1?")
        #expect(one.proposals[0].line == "Need reply · Roadmap")
    }

    @Test func planAppliesThroughTheModelAndSkipsWhatIsAlreadySo() async throws {
        var plan = TriagePlan()
        plan.add(.markDone(threadId: "t3", subject: "CI"))
        plan.add(.needReply(threadId: "t1", subject: "Roadmap", on: true))
        plan.add(.label(threadId: "t8", subject: "Invoice", labelId: "Label_2", labelName: "Travel", on: true))
        plan.add(.remind(threadId: "t4", subject: "Lisbon", at: Date().addingTimeInterval(3_600), onlyIfNoReply: true))
        plan.add(.markDone(threadId: "gone", subject: "?"))
        try engine.setNeedsReply(threadId: "t1", true) // already flagged: skipped
        let applied = await plan.apply(to: model)
        try await Task.sleep(for: .milliseconds(80))
        #expect(applied == 3)
        #expect(try engine.threadRow(id: "t3")?.isDone == true)
        #expect(try engine.threadRow(id: "t1")?.needsReply == true)
        #expect(try engine.threadRow(id: "t8")?.labels.contains("Label_2") == true)
        #expect(try engine.threadRow(id: "t4")?.isFollowUp == true)
    }

    @Test func remindToolParsesIsoAndBareDates() {
        #expect(RemindTool.parse("2026-11-14T09:00:00+01:00") != nil)
        #expect(RemindTool.parse("2026-11-14T09:00:00.000Z") != nil)
        let day = RemindTool.parse("2026-11-14")
        #expect(day.map { Calendar.current.component(.hour, from: $0) } == ReminderPreset.dayStart)
        #expect(RemindTool.parse("tomorrow") == nil)
    }

    @Test func rowViewCarriesNamesNotIds() throws {
        let row = try #require(try engine.threadRow(id: "t4"))
        let v = TriageRowView(row, model: model)
        #expect(v.labels == ["Travel"]) // tl2 → its name; INBOX/STARRED are not user labels
        #expect(v.from == "Lufthansa" && !v.isUnread)
        #expect(TriageToolOutput.json([v]).contains("\"subject\":\"Your trip to Lisbon: check-in opens\""))
    }

    @Test func journalPersistsCapsAndGroupsByRun() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("triage-journal-\(UUID().uuidString).json")
        let journal = TriageJournal(url: url)
        let a = UUID(), b = UUID()
        journal.append(TriageJournalEntry(runId: a, at: Date(), phase: .scan, tool: "searchThreads", detail: "inbox · 8 rows", dryRun: true))
        journal.append(TriageJournalEntry(runId: a, at: Date(), phase: .act, tool: "markDone", detail: "Mark done · CI", dryRun: true))
        journal.append(TriageJournalEntry(runId: b, at: Date(), phase: .scan, tool: "run", detail: "started", dryRun: false))
        let runs = journal.runs
        #expect(runs.map(\.id) == [b, a]) // newest run first
        #expect(runs[1].entries.map(\.tool) == ["searchThreads", "markDone"])
        #expect(TriageJournal(url: url).entries.count == 3)
        for i in 0..<(TriageJournal.cap + 5) {
            journal.append(TriageJournalEntry(runId: b, at: Date(), phase: .decide, tool: "decide", detail: "\(i)", dryRun: false))
        }
        #expect(journal.entries.count == TriageJournal.cap)
        journal.clear()
        #expect(TriageJournal(url: url).entries.isEmpty)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func instructionsCarryTheUsersRules() {
        #expect(TriageAgent.scanInstructions(rules: "").contains("Pick the ones worth a decision"))
        #expect(!TriageAgent.scanInstructions(rules: "   ").contains("own rules"))
        let d = TriageAgent.decideInstructions(rules: "Newsletters are done.", labels: ["Invoices", "Travel"])
        #expect(d.contains("Labels that exist: Invoices, Travel"))
        #expect(d.hasSuffix("Newsletters are done."))
    }
}
