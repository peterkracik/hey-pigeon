// MailEngine over the UniFFI `Engine` (desktop-app/crates/ffi). Pure
// mapping: every record becomes its app-side model here and nowhere else.

import Foundation
import HeyPigeonCore
import UIKit // NSAttributedString's html import

@MainActor
final class RustEngine: MailEngine {
    var onThreadsUpdated: (() -> Void)?
    var onAccountDisconnected: ((String) -> Void)?
    var onPrefsUpdated: (() -> Void)?

    private let engine: Engine
    private var listener: Listener?

    /// `dataDir` is the app's Application Support directory; the database,
    /// the body/attachment cache and (off Apple targets) the dev secret file
    /// live there. Tokens go to the Keychain.
    init(dataDir: URL, clientId: String) throws {
        engine = try Engine.open(
            dataDir: dataDir.path,
            oauth: OauthClient(clientId: clientId, clientSecret: nil)
        )
        let l = Listener(owner: self)
        listener = l
        engine.setListener(listener: l)
    }

    // Engine callbacks arrive on Rust threads; hop to the main actor.
    private final class Listener: EngineListener, @unchecked Sendable {
        weak var owner: RustEngine?
        init(owner: RustEngine) { self.owner = owner }
        func onThreadsUpdated() {
            Task { @MainActor [weak owner] in owner?.onThreadsUpdated?() }
        }
        func onAccountDisconnected(accountId: String) {
            Task { @MainActor [weak owner] in owner?.onAccountDisconnected?(accountId) }
        }
        func onPrefsUpdated() {
            Task { @MainActor [weak owner] in owner?.onPrefsUpdated?() }
        }
    }

    func accounts() throws -> [MailAccount] {
        try engine.listAccounts().map(MailAccount.init)
    }

    func accountStates() throws -> [AccountState] {
        try engine.accountStatus().map { s in
            AccountState(
                id: s.accountId,
                isConnected: s.connection == .connected,
                syncState: {
                    switch s.sync {
                    case .pending: "pending"
                    case .ok: "ok"
                    case .unavailable: "unavailable"
                    case .authExpired: "auth_expired"
                    case .error: "error"
                    }
                }(),
                syncDetail: s.syncDetail,
                lastSyncAt: s.lastSyncAt.map(Date.init(epochMs:))
            )
        }
    }

    func labels() throws -> [MailLabelItem] {
        try engine.listLabels().map { MailLabelItem(id: $0.id, accountId: $0.accountId, name: $0.name) }
    }

    func triageLabels() throws -> [TriageLabelItem] {
        try engine.listTriageLabels().map { TriageLabelItem(id: $0.id, name: $0.name) }
    }

    func unreadCounts(accountId: String?) throws -> [String: Int] {
        try engine.unreadCounts(accountId: accountId).mapValues(Int.init)
    }

    func threads(in view: MailView, accountId: String?, before: Date?, limit: Int) throws -> [ThreadRow] {
        let rows: [MailThread]
        switch view {
        case .scheduled:
            rows = try engine.listScheduled().filter { accountId == nil || $0.accountId == accountId }
        case .needReply:
            rows = try engine.listNeedsReply().filter { accountId == nil || $0.accountId == accountId }
        default:
            rows = try engine.listThreads(
                filter: view.filter, accountId: accountId,
                before: before.map(\.epochMs), limit: UInt32(limit)
            )
        }
        return rows.map { ThreadRow($0) }
    }

    func search(_ query: String, limit: Int) throws -> [ThreadRow] {
        try engine.search(query: query, limit: UInt32(limit)).map { hit in
            ThreadRow(hit.thread, snippet: hit.snippet.highlightMarkersStripped)
        }
    }

    func thread(id: String) async throws -> ThreadDetail? {
        guard let t = try await engine.getThread(threadId: id) else { return nil }
        let me = t.thread.accountId
        return ThreadDetail(thread: ThreadRow(t.thread), messages: t.messages.map { MessageItem($0, myEmail: me) })
    }

    func draft(threadId: String) async throws -> SendDraft? {
        guard let d = try await engine.loadDraft(threadId: threadId) else { return nil }
        var draft = SendDraft()
        draft.to = d.to
        draft.cc = d.cc
        draft.bcc = d.bcc
        draft.subject = d.subject
        draft.bodyText = d.bodyText ?? d.bodyHtml.map(Self.plainText) ?? ""
        draft.attachments = d.attachments.map {
            DraftAttachment(filename: $0.filename, mimeType: $0.mimeType,
                            size: Data(base64Encoded: $0.dataB64)?.count ?? 0, dataBase64: $0.dataB64)
        }
        draft.replyToThreadId = d.replyToThread
        draft.fromAccountId = d.accountId
        draft.draftKey = d.messageId
        draft.draftSaved = true
        return draft
    }

    /// An html-only draft's text, for the plain editor.
    private static func plainText(_ html: String) -> String {
        guard let data = html.data(using: .utf8),
              let s = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                    .characterEncoding: String.Encoding.utf8.rawValue],
                                              documentAttributes: nil)
        else { return html }
        return s.string
    }

    func threadRow(id: String) throws -> ThreadRow? {
        try engine.getThreadRow(threadId: id).map { ThreadRow($0) }
    }

    func perform(_ action: MailAction, accountId: String) async throws {
        try await engine.mutate(accountId: accountId, mutation: action.mutation)
    }

    func setReminder(threadId: String, at date: Date?, onlyIfNoReply: Bool) throws {
        try engine.setSchedule(threadId: threadId, scheduledAt: date.map(\.epochMs), followUp: onlyIfNoReply)
    }

    func setNeedsReply(threadId: String, _ value: Bool) throws {
        try engine.setNeedsReply(threadId: threadId, needsReply: value)
    }

    func setManualTriageLabels(threadId: String, ids: [String]) throws {
        try engine.setManualTriageLabels(threadId: threadId, labelIds: ids)
    }

    func updateAccount(id: String, displayName: String?, color: AccountColor?, signature: String?) throws {
        try engine.updateAccount(accountId: id, displayName: displayName, color: color?.rawValue, signature: signature)
    }

    // MARK: Prefs — JSON text over the FFI (Engine::get_prefs / set_pref)

    func prefs() throws -> [String: Any] {
        var out: [String: Any] = [:]
        for (name, json) in try engine.getPrefs() {
            guard let data = json.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            else { continue }
            out[name] = value
        }
        return out
    }

    func setPref(_ name: String, _ value: Any?) throws {
        var json: String?
        if let value {
            let data = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
            json = String(decoding: data, as: UTF8.self)
        }
        try engine.setPref(name: name, valueJson: json)
    }


    func removeAccount(id: String) async throws {
        try await engine.removeAccount(accountId: id)
    }

    func syncAll() async throws -> Bool {
        try await engine.syncAll()
    }

    func syncNow(accountId: String) async throws -> Bool {
        try await engine.syncNow(accountId: accountId)
    }

    func backfillOlder() async throws -> Bool {
        try await engine.backfillOlder()
    }

    // MARK: Push relay

    func registerPushToken(relayURL: String, deviceToken: String, environment: String) async throws {
        try await engine.registerPushToken(relayUrl: relayURL, deviceToken: deviceToken, environment: environment)
    }

    func disablePush() async throws {
        try await engine.disablePush()
    }

    func pushStatus() throws -> PushState {
        let s = try engine.pushStatus()
        return PushState(
            enabled: s.enabled,
            relayURL: s.relayUrl,
            topic: s.topic,
            accounts: s.accounts.map {
                PushAccountState(id: $0.accountId, watchExpiresAt: $0.watchExpiresAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) })
            }
        )
    }

    func beginOAuth(loginHint: String?) throws -> OAuthStart {
        let s = try engine.beginOauth(loginHint: loginHint, redirectUri: nil)
        guard let url = URL(string: s.url) else { throw URLError(.badURL) }
        return OAuthStart(url: url, callbackScheme: s.callbackScheme)
    }

    func finishOAuth(callbackURL: URL) async throws -> String {
        try await engine.finishOauth(callbackUrl: callbackURL.absoluteString)
    }

    // MARK: AI (only "openai" exists today, same as the desktop)

    private let provider = "openai"

    func aiStatus() throws -> AIStatus {
        let s = try engine.aiStatus()
        return AIStatus(configured: s.configured, providerId: s.providerId, model: s.model)
    }
    func aiModels() throws -> [AIModel] {
        try engine.aiModels(providerId: provider).map { AIModel(id: $0.id, label: $0.label) }
    }
    func setAIKey(_ key: String) async throws {
        try await engine.setAiKey(providerId: provider, apiKey: key)
    }
    func removeAIKey() throws { try engine.removeAiKey(providerId: provider) }
    func setAIModel(_ model: String) throws { try engine.setAiModel(providerId: provider, model: model) }
    func aiEditText(instruction: String, text: String, history: String?) async throws -> String {
        try await engine.aiEditText(providerId: provider, instruction: instruction, text: text, history: history)
    }
    func aiDraftReply(subject: String, history: String, notes: String?) async throws -> String {
        try await engine.aiDraftReply(providerId: provider, subject: subject, history: history, notes: notes)
    }
    func aiSummarizeThread(subject: String, items: [(from: String, snippet: String)]) async throws -> String {
        try await engine.aiSummarizeThread(
            providerId: provider, subject: subject,
            items: items.map { ThreadSummaryItem(from: $0.from, snippet: $0.snippet) }
        )
    }
    func aiSummarizeGroup(items: [(from: String, subject: String, snippet: String)]) async throws -> String {
        try await engine.aiSummarizeGroup(
            providerId: provider,
            items: items.map { SummaryItem(from: $0.from, subject: $0.subject, snippet: $0.snippet) }
        )
    }

    // MARK: Triage

    func triageStatus() throws -> TriageStatus {
        let s = try engine.triageStatus()
        return TriageStatus(configured: s.configured, enabled: s.enabled, lastError: s.lastError)
    }
    func setJevKey(_ key: String) async throws { try await engine.setJevKey(apiKey: key) }
    func removeJevKey() throws { try engine.removeJevKey() }
    func setAutoTriage(_ enabled: Bool) throws { try engine.setAutolabelEnabled(enabled: enabled) }
    func createTriageLabel(name: String) throws -> TriageLabelItem {
        let l = try engine.createTriageLabel(name: name)
        return TriageLabelItem(id: l.id, name: l.name)
    }
    func renameTriageLabel(id: String, name: String) throws { try engine.renameTriageLabel(id: id, newName: name) }
    func deleteTriageLabel(id: String) throws { try engine.deleteTriageLabel(id: id) }
    func reanalyzeTriage() throws { try engine.reanalyzeAllTriage() }
}

// MARK: - Mapping

private extension Date {
    init(epochMs: Int64) { self.init(timeIntervalSince1970: Double(epochMs) / 1000) }
    var epochMs: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}

private extension String {
    /// core::search wraps matches in U+E000 / U+E001; the row shows plain text.
    var highlightMarkersStripped: String {
        replacingOccurrences(of: "\u{E000}", with: "").replacingOccurrences(of: "\u{E001}", with: "")
    }
}

private extension MailAccount {
    init(_ a: Account) {
        self.init(
            id: a.id, email: a.email, displayName: a.displayName,
            color: AccountColor(rawValue: a.color) ?? .sky,
            avatarURL: a.avatarUrl.flatMap(URL.init(string:)), signature: a.signature
        )
    }
}

private extension ThreadRow {
    init(_ t: MailThread, snippet: String? = nil) {
        self.init(
            id: t.id, accountId: t.accountId, subject: t.subject, snippet: snippet ?? t.snippet,
            lastMessageAt: Date(epochMs: t.lastMsgAt), isRead: t.isRead, isArchived: t.isArchived,
            messageCount: Int(t.msgCount), fromSummary: t.fromSummary, lastFromAddress: t.lastFromAddr,
            scheduledAt: t.scheduledAt.map(Date.init(epochMs:)),
            isFollowUp: t.followUpSince != nil && t.scheduledAt != nil,
            needsReply: t.needsReply, isStarred: t.labels.contains("STARRED"),
            hasAttachment: t.hasAttachment,
            priority: t.priority.map {
                switch $0 {
                case .spam: .spam
                case .low: .low
                case .medium: .medium
                case .high: .high
                }
            },
            triageLabelIds: t.triageLabelIds, labels: t.labels
        )
    }
}

private extension MessageItem {
    init(_ m: MailMessage, myEmail: String) {
        let address = m.fromAddr.firstMatchInAngleBrackets ?? m.fromAddr
        let name = m.fromAddr.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        self.init(
            id: m.id,
            fromName: name.isEmpty ? address : name.trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
            fromAddress: address,
            to: m.toAddrs.map { a in
                let addr = a.firstMatchInAngleBrackets ?? a
                return addr.caseInsensitiveCompare(myEmail) == .orderedSame ? "me" : addr
            },
            date: Date(epochMs: m.date), snippet: m.snippet,
            bodyHTML: m.bodyHtml, bodyText: m.bodyText, isRead: m.isRead,
            isMine: m.fromAddr.localizedCaseInsensitiveContains(myEmail)
        )
    }
}

private extension String {
    var firstMatchInAngleBrackets: String? {
        guard let open = firstIndex(of: "<"), let close = self[open...].firstIndex(of: ">") else { return nil }
        return String(self[index(after: open)..<close])
    }
}

private extension MailView {
    var filter: ThreadFilter {
        switch self {
        case .inbox, .scheduled, .needReply: .inbox
        case .starred: .starred
        case .drafts: .drafts
        case .sent: .sent
        case .archive: .archive
        case .all: .all
        case .spam: .spam
        case .trash: .trash
        case .label(let id, _): .label(id: id)
        }
    }
}

private extension MailAction {
    var mutation: Mutation {
        switch self {
        case .archive(let id): .archive(threadId: id)
        case .unarchive(let id): .unarchive(threadId: id)
        case .markRead(let id, let read): .markRead(threadId: id, read: read)
        case .trash(let id): .trash(threadId: id)
        case .star(let id, let starred): .star(threadId: id, starred: starred)
        case .modifyLabel(let id, let label, let add): .modifyLabel(threadId: id, labelId: label, add: add)
        case .send(let d):
            .send(to: d.to, cc: d.cc, bcc: d.bcc, subject: d.subject, bodyText: d.bodyText,
                  bodyHtml: d.bodyHTML,
                  attachments: d.attachments.map { OutAttachment(filename: $0.filename, mimeType: $0.mimeType, dataB64: $0.dataBase64) },
                  replyToThread: d.replyToThreadId)
        case .saveDraft(let d):
            .saveDraft(key: d.draftKey, to: d.to, cc: d.cc, bcc: d.bcc, subject: d.subject, bodyText: d.bodyText,
                       bodyHtml: d.bodyHTML,
                       attachments: d.attachments.map { OutAttachment(filename: $0.filename, mimeType: $0.mimeType, dataB64: $0.dataBase64) },
                       replyToThread: d.replyToThreadId)
        case .deleteDraft(let key): .deleteDraft(key: key)
        }
    }
}
