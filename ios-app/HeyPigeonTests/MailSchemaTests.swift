// The Mail app-intent domain over the mock engine: the schema entities
// map the app's rows, the composer intents open the composer and never
// send, sendDraft goes through the model's undo window, and the triage
// intents do what the swipes do.

import AppIntents
import Testing
@testable import HeyPigeon

@MainActor
struct MailSchemaTests {
    let model: AppModel
    let engine: MockEngine

    init() {
        engine = MockEngine()
        model = AppModel(engine: engine)
    }

    private func message(_ id: String) throws -> MailMessageEntity {
        let row = try #require(try engine.threadRow(id: id))
        return MailMessageEntity(row, account: try #require(model.account(for: row)))
    }

    @Test func messageEntityIsTheThreadsLatestMessage() throws {
        let m = try message("t4")
        #expect(m.id == "t4")
        #expect(m.subject == "Your trip to Lisbon: check-in opens")
        #expect(m.sender.emailAddress == "news@lh.test")
        #expect(MailMessageEntity.personLabel(m.sender) == "Lufthansa")
        #expect(m.isFlagged) // pinned = Gmail star = flagged
        #expect(m.isRead)
        #expect(!m.isJunk)
        #expect(m.body == nil) // bodies never leave the engine
        #expect(m.mailbox.folder == .inbox)
        #expect(m.account.emailAddress == "me@personal.test")
    }

    @Test func personHelpersRoundTrip() {
        let p = IntentPerson.mail("ana@acme.test", name: "Ana")
        #expect(p.emailAddress == "ana@acme.test")
        #expect(MailMessageEntity.personLabel(p) == "Ana")
        let bare = IntentPerson.mail("x@y.test", name: nil)
        #expect(bare.emailAddress == "x@y.test")
        #expect([p, bare].emailAddresses == ["ana@acme.test", "x@y.test"])
    }

    @Test func replyOpensTheComposerWithSirisWords() async throws {
        var intent = ReplyMailIntent()
        intent.target = try message("t2")
        intent.isReplyAll = false
        intent.body = AttributedString("Yes, 8 works.")
        intent.attachments = []
        intent.to = []
        intent.cc = [.mail("maria@friends.test", name: nil)]
        intent.bcc = []
        let result = try await intent.perform()
        let draft = try #require(model.composeDraft)
        #expect(draft.replyToThreadId == "t2")
        #expect(draft.to == ["tomas@friends.test"])
        #expect(draft.cc == ["maria@friends.test"])
        #expect(draft.bodyText == "Yes, 8 works.")
        #expect(draft.externalRevision == 1)
        #expect(result.value?.id == draft.draftKey)
        // Nothing was sent: no toast, no pending send.
        #expect(model.toast == nil)
    }

    @Test func forwardPutsTheWordsAboveTheQuote() async throws {
        var intent = ForwardMailIntent()
        intent.target = try message("t5")
        intent.to = [.mail("legal@acme.test", name: nil)]
        intent.body = AttributedString("FYI")
        intent.cc = []
        intent.bcc = []
        intent.attachments = []
        _ = try await intent.perform()
        let draft = try #require(model.composeDraft)
        #expect(draft.to == ["legal@acme.test"])
        #expect(draft.subject == "Fwd: Contract draft v3")
        #expect(draft.bodyText.hasPrefix("FYI"))
        #expect(draft.bodyText.contains("Forwarded message"))
    }

    @Test func createUpdateAndSendDraft() async throws {
        var create = CreateDraftIntent()
        create.to = [.mail("ana@acme.test", name: "Ana")]
        create.subject = "Lunch"
        create.body = AttributedString("Tomorrow?")
        create.cc = []
        create.bcc = []
        create.attachments = []
        let created = try await create.perform()
        let entity = try #require(created.value)
        #expect(model.composeDraft?.draftKey == entity.id)
        #expect(entity.subject == "Lunch")

        var update = UpdateDraftIntent()
        update.target = entity
        update.subject = "Lunch on Friday"
        update.body = AttributedString("Friday at noon?")
        let updated = try await update.perform()
        #expect(updated.value?.subject == "Lunch on Friday")
        #expect(model.composeDraft?.bodyText == "Friday at noon?")
        #expect(model.composeDraft?.externalRevision == 1)

        var send = SendDraftIntent()
        send.target = entity
        send.sendLaterDate = Date().addingTimeInterval(3_600)
        await #expect(throws: IntentError.self) { _ = try await send.perform() }
        #expect(model.composeDraft != nil)

        send.sendLaterDate = nil
        _ = try await send.perform()
        // The composer closed and the send sits in the undo window.
        #expect(model.composeDraft == nil)
        #expect(model.toast?.text.hasPrefix("Sending") == true)
        #expect(model.toast?.undo != nil)
        // Undo brings the composer back with the draft.
        model.toast?.undo?()
        #expect(model.composeDraft?.subject == "Lunch on Friday")
    }

    @Test func sendRefusesADraftWithoutRecipients() async throws {
        var create = CreateDraftIntent()
        create.to = []
        create.cc = []
        create.bcc = []
        create.attachments = []
        create.subject = "Note to self"
        let entity = try #require(try await create.perform().value)
        var send = SendDraftIntent()
        send.target = entity
        await #expect(throws: IntentError.self) { _ = try await send.perform() }
        #expect(model.composeDraft != nil)
    }

    @Test func deleteDraftClosesTheComposer() async throws {
        var create = CreateDraftIntent()
        create.to = []
        create.cc = []
        create.bcc = []
        create.attachments = []
        let entity = try #require(try await create.perform().value)
        var delete = DeleteDraftIntent()
        delete.entities = [entity]
        _ = try await delete.perform()
        #expect(model.composeDraft == nil)
    }

    @Test func archiveDeleteAndUpdateMail() async throws {
        var archive = ArchiveMailIntent()
        archive.entities = [try message("t1"), try message("t2")]
        _ = try await archive.perform()
        try await Task.sleep(for: .milliseconds(50))
        #expect(try engine.threadRow(id: "t1")?.isDone == true)
        #expect(try engine.threadRow(id: "t2")?.isDone == true)

        var update = UpdateMailIntent()
        update.target = [try message("t3")]
        update.isRead = false
        update.isFlagged = true
        _ = try await update.perform()
        try await Task.sleep(for: .milliseconds(50))
        let t3 = try #require(try engine.threadRow(id: "t3"))
        #expect(!t3.isRead)
        #expect(t3.isPinned)

        var move = UpdateMailIntent()
        move.target = [try message("t6")]
        move.mailbox = MailboxEntity(folder: .archive, account: try #require(model.accounts.first { $0.id == "me@personal.test" }))
        _ = try await move.perform()
        try await Task.sleep(for: .milliseconds(50))
        #expect(try engine.threadRow(id: "t6")?.isDone == true)

        var bad = UpdateMailIntent()
        bad.target = [try message("t7")]
        bad.mailbox = MailboxEntity(folder: .sent, account: try #require(model.accounts.first))
        await #expect(throws: IntentError.self) { _ = try await bad.perform() }

        var delete = DeleteMailIntent()
        delete.entities = [try message("t8")]
        _ = try await delete.perform()
        try await Task.sleep(for: .milliseconds(50))
        #expect(try engine.threadRow(id: "t8") == nil)
    }

    @Test func mailboxQueryListsEveryAccountsFolders() async throws {
        let all = try await MailboxQuery().suggestedEntities()
        #expect(all.count == model.accounts.count * MailboxEntity.folders.count)
        let inbox = try await MailboxQuery().entities(for: ["me@work.test|inbox"])
        #expect(inbox.first?.name == "Inbox")
        #expect(inbox.first?.account.emailAddress == "me@work.test")
    }

    @Test func messageQueryResolvesSearchAndTheOpenThread() async throws {
        let q = MailMessageQuery()
        #expect(try await q.entities(matching: "contract").map(\.id) == ["t5"])
        #expect(await q.defaultResult() == nil)
        model.showThread(try #require(try engine.threadRow(id: "t2")))
        #expect(await q.defaultResult()?.id == "t2")
    }
}
