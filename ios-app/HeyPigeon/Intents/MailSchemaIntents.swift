// The Mail domain's intents, over AppModel like every other intent. The
// three use-case groups are complete — composing (createDraft ·
// updateDraft · saveDraft · sendDraft), replying (+ replyMail) and
// forwarding (+ forwardMail) — plus the standalone openMessage, openDraft,
// archiveMail, deleteMail, deleteDraft and updateMail. Xcode warns per
// schema missing from a group an app partially adopts.
//
// Composer intents open the app (they open an email composer, in the
// schema's own words) and never send. `sendDraft` is the one way a message
// leaves from Siri: it goes through the same 5-second undo as the Send
// button, and only for a draft that is open in the composer or saved in
// Gmail. Scheduling a send is declined.

import AppIntents
import Foundation

// MARK: - Replying · forwarding · composing

@AppIntent(schema: .mail.replyMail)
struct ReplyMailIntent {
    static let openAppWhenRun = true

    var isReplyAll: Bool
    var target: MailMessageEntity
    var body: AttributedString?
    var subject: String?
    var account: MailAccountEntity?
    var attachments: [IntentFile]
    var to: [IntentPerson]
    var cc: [IntentPerson]
    var bcc: [IntentPerson]

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<MailDraftEntity> {
        let model = try await IntentSupport.model()
        let row = try IntentSupport.row(id: target.id, in: model)
        try await model.openReply(to: row, all: isReplyAll, body: body.map { String($0.characters) })
        return .result(value: try model.applyToOpenDraft(to: to, cc: cc, bcc: bcc, subject: subject, body: nil, account: account))
    }
}

@AppIntent(schema: .mail.forwardMail)
struct ForwardMailIntent {
    static let openAppWhenRun = true

    var target: MailMessageEntity
    var to: [IntentPerson]
    var body: AttributedString?
    var cc: [IntentPerson]
    var bcc: [IntentPerson]
    var subject: String?
    var account: MailAccountEntity?
    var attachments: [IntentFile]

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<MailDraftEntity> {
        let model = try await IntentSupport.model()
        let row = try IntentSupport.row(id: target.id, in: model)
        try await model.openForward(of: row)
        // The user's words go above the quoted message.
        let prefix = body.map { String($0.characters) }
        return .result(value: try model.applyToOpenDraft(to: to, cc: cc, bcc: bcc, subject: subject, body: prefix, account: account, bodyIsPrefix: true))
    }
}

@AppIntent(schema: .mail.createDraft)
struct CreateDraftIntent {
    static let openAppWhenRun = true

    var body: AttributedString?
    var to: [IntentPerson]
    var subject: String?
    var cc: [IntentPerson]
    var bcc: [IntentPerson]
    var account: MailAccountEntity?
    var attachments: [IntentFile]

    @MainActor
    func perform() async throws -> some ReturnsValue<MailDraftEntity> {
        let model = try await IntentSupport.model()
        guard !model.accounts.isEmpty else { throw IntentError.noAccount }
        var draft = SendDraft()
        draft.to = to.emailAddresses
        draft.cc = cc.emailAddresses
        draft.bcc = bcc.emailAddresses
        draft.subject = subject ?? ""
        draft.bodyText = body.map { String($0.characters) } ?? ""
        draft.fromAccountId = account?.id
        model.compose(draft)
        guard let a = model.draftAccount(draft) else { throw IntentError.noAccount }
        return .result(value: MailDraftEntity(draft, account: a))
    }
}

@AppIntent(schema: .mail.updateDraft)
struct UpdateDraftIntent {
    var target: MailDraftEntity
    var to: [IntentPerson]?
    var cc: [IntentPerson]?
    var bcc: [IntentPerson]?
    var subject: String?
    var body: AttributedString?
    var account: MailAccountEntity?
    var attachments: [IntentFile]?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<MailDraftEntity> {
        let model = try await IntentSupport.model()
        let text = body.map { String($0.characters) }
        // Open in the composer: change it there.
        if model.composeDraft?.draftKey == target.id {
            return .result(value: try model.applyToOpenDraft(to: to ?? [], cc: cc ?? [], bcc: bcc ?? [], subject: subject, body: text, account: account))
        }
        // Saved in Gmail: load, change, save back.
        guard let found = await model.gmailDraft(key: target.id) else { throw IntentError.draftGone }
        var d = found.draft
        if let to, !to.isEmpty { d.to = to.emailAddresses }
        if let cc, !cc.isEmpty { d.cc = cc.emailAddresses }
        if let bcc, !bcc.isEmpty { d.bcc = bcc.emailAddresses }
        if let subject, !subject.isEmpty { d.subject = subject }
        if let text, !text.isEmpty { d.bodyText = text; d.bodyHTML = nil; d.bodyRich = nil }
        if let account { d.fromAccountId = account.id }
        guard let a = model.draftAccount(d) else { throw IntentError.noAccount }
        model.saveDraft(d, from: a.id)
        return .result(value: MailDraftEntity(d, account: a))
    }
}

@AppIntent(schema: .mail.saveDraft)
struct SaveDraftIntent {
    var target: MailDraftEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        if let d = model.composeDraft, d.draftKey == target.id, let a = model.draftAccount(d) {
            model.saveDraft(d, from: a.id)
            model.updateComposeDraft(key: d.draftKey) { $0.draftSaved = true }
        }
        // A Gmail draft is already saved.
        return .result()
    }
}

@AppIntent(schema: .mail.sendDraft)
struct SendDraftIntent {
    var target: MailDraftEntity
    var sendLaterDate: Date?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard sendLaterDate == nil else { throw IntentError.scheduledSendUnsupported }
        let model = try await IntentSupport.model()
        if model.composeDraft?.draftKey == target.id {
            try model.sendComposeDraft(key: target.id)
            return .result(dialog: "Sending. You have a few seconds to undo in Hey Pigeon.")
        }
        guard let found = await model.gmailDraft(key: target.id) else { throw IntentError.draftGone }
        let d = found.draft
        guard !(d.to.isEmpty && d.cc.isEmpty && d.bcc.isEmpty) else { throw IntentError.noRecipients }
        guard let a = model.draftAccount(d) else { throw IntentError.noAccount }
        model.send(d, from: a.id)
        return .result(dialog: "Sending. You have a few seconds to undo in Hey Pigeon.")
    }
}

// MARK: - Opening

@AppIntent(schema: .mail.openMessage)
struct OpenMessageIntent: OpenIntent {
    var target: MailMessageEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        _ = try IntentSupport.row(id: target.id, in: model)
        model.openThread(id: target.id)
        return .result()
    }
}

@AppIntent(schema: .mail.openDraft)
struct OpenDraftIntent: OpenIntent {
    var target: MailDraftEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        if model.composeDraft?.draftKey == target.id { return .result() }
        guard let found = await model.gmailDraft(key: target.id) else { throw IntentError.draftGone }
        model.compose(found.draft)
        return .result()
    }
}

// MARK: - Triage

@AppIntent(schema: .mail.archiveMail)
struct ArchiveMailIntent {
    var entities: [MailMessageEntity]

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentSupport.model()
        var n = 0
        for e in entities {
            guard let row = try? IntentSupport.row(id: e.id, in: model), !row.isDone else { continue }
            model.markDone(row)
            n += 1
        }
        return .result(dialog: n == 1 ? "Marked done." : "Marked \(n) done.")
    }
}

@AppIntent(schema: .mail.deleteMail)
struct DeleteMailIntent: DeleteIntent {
    var entities: [MailMessageEntity]

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentSupport.model()
        var n = 0
        for e in entities {
            guard let row = try? IntentSupport.row(id: e.id, in: model) else { continue }
            model.delete(row)
            n += 1
        }
        return .result(dialog: n == 1 ? "Deleted." : "Deleted \(n).")
    }
}

@AppIntent(schema: .mail.deleteDraft)
struct DeleteDraftIntent: DeleteIntent {
    var entities: [MailDraftEntity]

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        for e in entities {
            if model.discardComposeDraft(key: e.id) { continue }
            if let found = await model.gmailDraft(key: e.id) {
                model.deleteDraft(found.draft.draftKey, from: found.row.accountId)
            }
        }
        return .result()
    }
}

@AppIntent(schema: .mail.updateMail)
struct UpdateMailIntent {
    var target: [MailMessageEntity]
    var isRead: Bool?
    var isFlagged: Bool?
    var isJunk: Bool?
    var mailbox: MailboxEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        for e in target {
            guard let row = try? IntentSupport.row(id: e.id, in: model) else { continue }
            if let isRead, row.isRead != isRead { model.toggleRead(row) }
            if let isFlagged, row.isPinned != isFlagged { model.togglePin(row) }
            if let isJunk, row.labels.contains("SPAM") != isJunk { model.setSpam(row, isJunk) }
            if let mailbox { try model.move(row, toMailbox: mailbox) }
        }
        return .result()
    }
}

// MARK: - Model glue for the schema intents

extension AppModel {
    /// Apply Siri's recipients, subject, body and account to the open
    /// composer and return it as the draft entity. Empty lists and nil
    /// strings leave the field alone. `bodyIsPrefix` puts the text above
    /// what the draft already holds (a forward's quoted message).
    func applyToOpenDraft(to: [IntentPerson], cc: [IntentPerson], bcc: [IntentPerson], subject: String?,
                          body: String?, account: MailAccountEntity?, bodyIsPrefix: Bool = false) throws -> MailDraftEntity {
        guard let key = composeDraft?.draftKey else { throw IntentError.draftGone }
        updateComposeDraft(key: key) { d in
            if !to.isEmpty { d.to = to.emailAddresses }
            if !cc.isEmpty { d.cc = cc.emailAddresses }
            if !bcc.isEmpty { d.bcc = bcc.emailAddresses }
            if let subject, !subject.isEmpty { d.subject = subject }
            if let body, !body.isEmpty {
                d.bodyText = bodyIsPrefix ? body + d.bodyText : body
                d.bodyHTML = nil
                d.bodyRich = nil
            }
            if let account { d.fromAccountId = account.id }
        }
        guard let d = composeDraft, let a = draftAccount(d) else { throw IntentError.draftGone }
        return MailDraftEntity(d, account: a)
    }

    /// Gmail's SPAM label, on or off.
    func setSpam(_ row: ThreadRow, _ on: Bool) {
        setLabel(row, MailLabelItem(id: "SPAM", accountId: row.accountId, name: "Spam"), on: on)
    }

    /// Siri's "move to": the folders that are a move in this app's words.
    func move(_ row: ThreadRow, toMailbox mailbox: MailboxEntity) throws {
        switch mailbox.folder {
        case .inbox: if row.isDone { markNotDone(row) }
        case .archive: if !row.isDone { markDone(row) }
        case .trash: delete(row)
        case .spam: setSpam(row, true)
        default: throw IntentError.unsupportedMailbox(name: mailbox.name)
        }
    }
}
