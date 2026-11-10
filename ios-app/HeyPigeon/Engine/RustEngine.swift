// MailEngine over the UniFFI `Engine` (desktop-app/crates/ffi). Pure
// mapping: every record becomes its app-side model here and nowhere else.

import Foundation
import HeyPigeonCore
// NSAttributedString's HTML import (`plainText`) lives in the UI framework.
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class RustEngine: MailEngine {
    var onThreadsUpdated: (() -> Void)?
    var onAccountDisconnected: ((String) -> Void)?
    var onPrefsUpdated: (() -> Void)?
    var onAnalysisProgress: ((AnalysisProgress) -> Void)?

    private let engine: Engine
    /// The same reads as the ones below, usable off the main actor
    /// (`readInBackground`); the main-actor methods answer through it too,
    /// so there is one mapping.
    private let reader: RustStoreReader
    private var listener: Listener?

    /// `dataDir` is the app's Application Support directory; the database,
    /// the body/attachment cache and (off Apple targets) the dev secret file
    /// live there. Tokens go to the Keychain.
    init(dataDir: URL, clientId: String) throws {
        engine = try Engine.open(
            dataDir: dataDir.path,
            oauth: OauthClient(clientId: clientId, clientSecret: nil)
        )
        reader = RustStoreReader(engine: engine)
        let l = Listener(owner: self)
        listener = l
        engine.setListener(listener: l)
        // Apple Intelligence on device, Apple's Private Cloud Compute and
        // any registered package model: AI and triage with no key. One
        // backend per provider; the core decides who answers (Settings › AI
        // shows it) and falls back along pref:ai.fallback.
        refreshAIProviders()
    }

    /// Register a backend for every provider this device can run now and
    /// drop the ones it cannot (the cloud model offline, Apple Intelligence
    /// turned off). Called at open and on every foreground sync.
    func refreshAIProviders() {
        for provider in ModelProviderRegistry.all {
            if provider.availability.isAvailable {
                engine.addAiBackend(backend: FoundationModelsBackend(provider: provider))
            } else {
                engine.removeAiBackend(providerId: provider.id)
            }
        }
    }

    func aiProviders() -> [AIProviderInfo] {
        ModelProviderRegistry.all.map { p in
            let a = p.availability
            return AIProviderInfo(id: p.id, title: p.label, modelLabel: p.modelLabel, leavesDevice: p.leavesDevice,
                                  available: a.isAvailable, unavailableReason: a.reason)
        }
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
        func onAnalysisProgress(progress: AnalysisPass) {
            let p = AnalysisProgress(progress)
            Task { @MainActor [weak owner] in owner?.onAnalysisProgress?(p) }
        }
    }

    func accounts() throws -> [MailAccount] { try reader.accounts() }

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

    func labels() throws -> [MailLabelItem] { try reader.labels() }

    func triageLabels() throws -> [TriageLabelItem] {
        try engine.listTriageLabels().map { TriageLabelItem(id: $0.id, name: $0.name) }
    }

    func unreadCounts(accountId: String?) throws -> [String: Int] { try reader.unreadCounts(accountId: accountId) }

    func threads(in view: MailView, accountId: String?, before: Date?, limit: Int) throws -> [ThreadRow] {
        try reader.threads(in: view, accountId: accountId, before: before, limit: limit)
    }

    func readInBackground<T: Sendable>(_ read: @escaping @Sendable (any StoreReader) throws -> T) async throws -> T {
        let reader = reader
        return try await Task.detached(priority: .userInitiated) { try read(reader) }.value
    }

    func search(_ query: String, limit: Int) throws -> [ThreadRow] {
        try Self.search(engine, query, limit: limit)
    }

    func searchInBackground(_ query: String, limit: Int) async -> [ThreadRow] {
        let engine = engine
        return await Task.detached(priority: .userInitiated) {
            (try? Self.search(engine, query, limit: limit)) ?? []
        }.value
    }

    /// The FTS query and the row mapping, callable from any thread.
    private nonisolated static func search(_ engine: Engine, _ query: String, limit: Int) throws -> [ThreadRow] {
        try engine.search(query: query, limit: UInt32(limit)).map { hit in
            ThreadRow(hit.thread, snippet: hit.snippet.highlightMarkersStripped)
        }
    }

    func thread(id: String) async throws -> ThreadDetail? {
        guard let t = try await engine.getThread(threadId: id) else { return nil }
        let me = t.thread.accountId
        return ThreadDetail(thread: ThreadRow(t.thread), messages: t.messages.map { MessageItem($0, myEmail: me) })
    }

    func threadLocal(id: String) throws -> ThreadDetail? { try reader.threadLocal(id: id) }

    func draft(threadId: String) async throws -> SendDraft? {
        guard let d = try await engine.loadDraft(threadId: threadId) else { return nil }
        var draft = SendDraft()
        draft.to = d.to
        draft.cc = d.cc
        draft.bcc = d.bcc
        draft.subject = d.subject
        draft.bodyText = d.bodyText ?? d.bodyHtml.map(Self.plainText) ?? ""
        // The formatting too: without the html part a reopened draft lost
        // its bold and its links, and was then sent as plain text.
        draft.bodyHTML = d.bodyHtml
        // The size from the base64 length: decoding an 18 MB attachment
        // only to count its bytes cost a copy of it on every draft open.
        draft.attachments = d.attachments.map {
            DraftAttachment(filename: $0.filename, mimeType: $0.mimeType,
                            size: Base64.decodedLength($0.dataB64), dataBase64: $0.dataB64)
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

    func threadRow(id: String) throws -> ThreadRow? { try reader.threadRow(id: id) }

    func attachments(threadId: String) async throws -> [AttachmentItem] {
        try await engine.listAttachments(threadId: threadId).map {
            AttachmentItem(threadId: $0.threadId, messageId: $0.messageId, attachmentId: $0.attachmentId,
                           filename: $0.filename, mimeType: $0.mimeType, size: Int($0.size),
                           contentId: $0.contentId)
        }
    }

    func attachmentFile(_ a: AttachmentItem) async throws -> URL {
        let path = try await engine.fetchAttachment(attachment: MailAttachment(
            threadId: a.threadId, messageId: a.messageId, attachmentId: a.attachmentId,
            filename: a.filename, mimeType: a.mimeType, size: Int64(a.size),
            contentId: a.contentId
        ))
        return URL(fileURLWithPath: path)
    }

    func perform(_ action: MailAction, accountId: String) async throws {
        try await engine.mutate(accountId: accountId, mutation: action.mutation)
    }

    func pendingChanges() -> Int { Int(engine.pendingMutations()) }

    func createLabel(accountId: String, name: String) async throws -> MailLabelItem {
        let l = try await engine.createLabel(accountId: accountId, name: name)
        return MailLabelItem(id: l.id, accountId: l.accountId, name: l.name)
    }

    func renameLabel(_ label: MailLabelItem, to name: String) async throws {
        try await engine.renameLabel(accountId: label.accountId, labelId: label.id, newName: name)
    }

    func deleteLabel(_ label: MailLabelItem) async throws {
        try await engine.deleteLabel(accountId: label.accountId, labelId: label.id)
    }

    func searchRemote(_ query: String, accountId: String?, limit: Int) async throws -> [ThreadRow] {
        try await engine.searchRemote(query: query, accountId: accountId, limit: UInt32(limit)).map { ThreadRow($0) }
    }

    func sendAliases(accountId: String) async throws -> [SendAlias] {
        try await engine.listSendAs(accountId: accountId).map { SendAlias(email: $0.email, name: $0.name, isDefault: $0.isDefault) }
    }

    func searchContacts(_ query: String, limit: Int) async -> [ContactMatch] {
        let found = (try? await engine.searchContacts(query: query, limit: UInt32(limit))) ?? []
        return found.map { ContactMatch(name: $0.name, email: $0.email) }
    }

    func setReminder(threadId: String, at date: Date?, onlyIfNoReply: Bool) throws {
        try engine.setSchedule(threadId: threadId, scheduledAt: date.map(\.epochMs), followUp: onlyIfNoReply)
    }

    func setNeedsReply(threadId: String, _ value: Bool) throws {
        try engine.setNeedsReply(threadId: threadId, needsReply: value)
    }

    func dismissSuggestion(threadId: String) throws {
        try engine.dismissSuggestion(threadId: threadId)
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
                PushAccountState(id: $0.accountId, watchExpiresAt: $0.watchExpiresAtMs.map(Date.init(epochMs:)))
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

    // MARK: AI — the key paths name the keyed provider; the core picks who
    // answers (Engine::active_provider), so the AI actions only pass an id
    // it accepts.

    private let provider = "openai"

    func aiStatus() throws -> AIStatus {
        let s = try engine.aiStatus()
        return AIStatus(configured: s.configured, providerId: s.providerId, model: s.model,
                        preferredProviderId: s.preferredProviderId, onDeviceAvailable: s.onDeviceAvailable,
                        openaiConfigured: s.openaiConfigured, keyedProviderIds: s.keyedProviderIds,
                        availableProviderIds: s.availableProviderIds, fallbackOrder: s.fallbackOrder)
    }
    func setAIProvider(_ provider: AIProvider) throws { try engine.setAiProvider(providerId: provider.rawValue) }
    func setAIFallback(_ order: [AIProvider]) throws { try engine.setAiFallback(order: order.map(\.rawValue)) }
    func aiModels(for provider: AIProvider) throws -> [AIModel] {
        try engine.aiModels(providerId: provider.rawValue).map { AIModel(id: $0.id, label: $0.label) }
    }
    func aiSelectedModel(for provider: AIProvider) throws -> String? {
        try engine.aiSelectedModel(providerId: provider.rawValue)
    }
    func setAIKey(_ key: String, for provider: AIProvider) async throws {
        try await engine.setAiKey(providerId: provider.rawValue, apiKey: key)
    }
    func removeAIKey(for provider: AIProvider) throws { try engine.removeAiKey(providerId: provider.rawValue) }
    func setAIModel(_ model: String, for provider: AIProvider) throws {
        try engine.setAiModel(providerId: provider.rawValue, model: model)
    }
    func aiEditText(instruction: String, text: String, history: String?, context: AIWriteContext?) async throws -> String {
        try await engine.aiEditText(providerId: provider, instruction: instruction, text: text, history: history,
                                    context: context.map(Self.ffi))
    }
    func aiDraftReply(subject: String, history: String, notes: String?, context: AIWriteContext?) async throws -> String {
        try await engine.aiDraftReply(providerId: provider, subject: subject, history: history, notes: notes,
                                      context: context.map(Self.ffi))
    }
    private static func ffi(_ c: AIWriteContext) -> AiWriteContext {
        AiWriteContext(senderName: c.senderName, senderEmail: c.senderEmail, recipients: c.recipients, subject: c.subject)
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

    func aiPrompts() -> AIPrompts {
        let p = engine.aiPrompts()
        return AIPrompts(summary: p.summary, threadSummary: p.threadSummary, draftReply: p.draftReply, edit: p.edit)
    }

    // MARK: Triage

    func triageStatus() throws -> TriageStatus {
        let s = try engine.triageStatus()
        return TriageStatus(configured: s.configured, enabled: s.enabled, lastError: s.lastError,
                            classifierId: s.classifierId, onDeviceAvailable: s.onDeviceAvailable, jevConfigured: s.jevConfigured,
                            availableClassifierIds: s.availableClassifierIds)
    }
    func setTriageClassifier(_ classifier: TriageClassifier) throws {
        try engine.setTriageClassifier(classifierId: classifier.rawValue)
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
    func analysisProgress() -> AnalysisProgress { AnalysisProgress(engine.analysisProgress()) }
    func analyzePending() async -> AnalysisProgress { AnalysisProgress(await engine.analyzePending()) }

    func bundles() throws -> [BundleItem] { try reader.bundles() }
    func bundleContents(id: String) throws -> BundleContents? {
        try engine.bundleDetail(bundleId: id).map {
            BundleContents(
                bundle: BundleItem($0.bundle),
                facts: $0.facts.map(BundleFactItem.init),
                links: $0.links.compactMap { l in
                    URL(string: l.url).map { BundleLinkItem(url: $0, host: l.host, threadId: l.threadId, subject: l.subject) }
                },
                threads: $0.threads.map { ThreadRow($0) }
            )
        }
    }
    func createBundle(name: String, category: BundleCategory, description: String, threadIds: [String]) throws -> BundleItem {
        BundleItem(try engine.createBundle(name: name, kind: category.ffi, description: description, threadIds: threadIds))
    }
    func updateBundle(id: String, name: String, category: BundleCategory, description: String) throws {
        try engine.updateBundle(bundleId: id, name: name, kind: category.ffi, description: description)
    }
    func setBundleArchived(id: String, _ archived: Bool) throws {
        try engine.setBundleArchived(bundleId: id, archived: archived)
    }
    func deleteBundle(id: String) throws { try engine.deleteBundle(bundleId: id) }
    @discardableResult
    func addToBundle(threadId: String, bundleId: String) throws -> Int {
        Int(try engine.addToBundle(threadId: threadId, bundleId: bundleId))
    }
    func removeFromBundle(threadId: String) throws { try engine.removeFromBundle(threadId: threadId) }
    func suggestedBundle(threadId: String) throws -> String? { try engine.suggestBundle(threadId: threadId) }
    func aiSummarizeBundle(id: String) async throws -> BundleBrief {
        let s = try await engine.aiSummarizeBundle(providerId: provider, bundleId: id)
        return BundleBrief(status: s.status, actions: s.actions)
    }
}

// MARK: - Mapping

/// The store's reads over the UniFFI engine, from any thread: the Rust side
/// serializes access to the database itself, and the records are mapped
/// here with the same initializers the main-actor methods use.
struct RustStoreReader: StoreReader, Sendable {
    let engine: Engine

    func accounts() throws -> [MailAccount] {
        try engine.listAccounts().map(MailAccount.init)
    }

    func labels() throws -> [MailLabelItem] {
        try engine.listLabels().map { MailLabelItem(id: $0.id, accountId: $0.accountId, name: $0.name) }
    }

    func bundles() throws -> [BundleItem] { try engine.listBundles().map(BundleItem.init) }

    func unreadCounts(accountId: String?) throws -> [String: Int] {
        try engine.unreadCounts(accountId: accountId).mapValues(Int.init)
    }

    func threads(in view: MailView, accountId: String?, before: Date?, limit: Int) throws -> [ThreadRow] {
        let rows: [MailThread]
        switch view {
        // Bounded lists, whole: MailView.isPaged is false for both, so the
        // model never asks for a page after them.
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

    func threadRow(id: String) throws -> ThreadRow? {
        try engine.getThreadRow(threadId: id).map { ThreadRow($0) }
    }

    func threadLocal(id: String) throws -> ThreadDetail? {
        guard let t = try engine.getThreadLocal(threadId: id) else { return nil }
        let me = t.thread.accountId
        return ThreadDetail(thread: ThreadRow(t.thread), messages: t.messages.map { MessageItem($0, myEmail: me) })
    }
}

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
            triageLabelIds: t.triageLabelIds, labels: t.labels,
            suggestion: t.suggestion.map {
                switch $0 {
                case .needsReply: .needsReply
                case .remind(let at): .remind(at: Date(epochMs: at))
                }
            },
            bundleId: t.bundleId
        )
    }
}

private extension BundleItem {
    init(_ b: MailBundle) {
        self.init(
            id: b.id, name: b.name, category: BundleCategory(b.kind), description: b.description,
            isArchived: b.archived, createdAt: Date(epochMs: b.createdAt),
            threadCount: Int(b.threadCount), openCount: Int(b.openCount),
            lastActivityAt: b.lastActivityAt > 0 ? Date(epochMs: b.lastActivityAt) : nil,
            isAutomatic: b.automatic
        )
    }
}

private extension BundleFactItem {
    init(_ f: BundleFact) {
        let category: BundleFactCategory = switch f.kind {
        case .flight: .flight
        case .booking: .booking
        case .order: .order
        case .invoice: .invoice
        case .tracking: .tracking
        }
        self.init(category: category, value: f.value, threadId: f.threadId, at: Date(epochMs: f.at),
                  url: f.url.flatMap(URL.init(string:)))
    }
}

private extension MessageItem {
    /// `myEmail` is the account's address: recipients matching it become
    /// "me", and the message is the user's own when its sender is that
    /// address exactly (a substring test made "hana@…" the user's own
    /// mail on the "ana@…" account).
    init(_ m: MailMessage, myEmail: String) {
        self.init(
            id: m.id,
            fromName: EmailAddress.displayName(in: m.fromAddr),
            fromAddress: EmailAddress.address(in: m.fromAddr),
            to: m.toAddrs.map { a in EmailAddress.same(a, myEmail) ? "me" : EmailAddress.address(in: a) },
            date: Date(epochMs: m.date), snippet: m.snippet,
            bodyHTML: m.bodyHtml, bodyText: m.bodyText, isRead: m.isRead,
            isMine: EmailAddress.same(m.fromAddr, myEmail),
            isDraft: m.labelIds.contains("DRAFT"),
            cc: m.ccAddrs.map { a in EmailAddress.same(a, myEmail) ? "me" : EmailAddress.address(in: a) },
            listUnsubscribe: m.listUnsubscribe,
            unsubscribeOneClick: m.listUnsubscribeOneClick,
            replyTo: m.replyToAddrs.map { a in EmailAddress.same(a, myEmail) ? "me" : EmailAddress.address(in: a) }
        )
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
        case .untrash(let id): .untrash(threadId: id)
        case .markSpam(let id, let spam): .markSpam(threadId: id, spam: spam)
        case .send(let d):
            .send(to: d.to, cc: d.cc, bcc: d.bcc, subject: d.subject, bodyText: d.bodyText,
                  bodyHtml: d.bodyHTML,
                  attachments: d.attachments.map { OutAttachment(filename: $0.filename, mimeType: $0.mimeType, dataB64: $0.dataBase64) },
                  replyToThread: d.replyToThreadId, fromAddr: d.fromAddress)
        case .saveDraft(let d):
            .saveDraft(key: d.draftKey, to: d.to, cc: d.cc, bcc: d.bcc, subject: d.subject, bodyText: d.bodyText,
                       bodyHtml: d.bodyHTML,
                       attachments: d.attachments.map { OutAttachment(filename: $0.filename, mimeType: $0.mimeType, dataB64: $0.dataBase64) },
                       replyToThread: d.replyToThreadId, fromAddr: d.fromAddress)
        case .deleteDraft(let key): .deleteDraft(key: key)
        }
    }
}

extension AnalysisProgress {
    init(_ p: AnalysisPass) {
        self.init(done: Int(p.done), total: Int(p.total), isRunning: p.running)
    }
}
