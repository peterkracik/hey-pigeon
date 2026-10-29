// In-memory engine with sample mail. Used by SwiftUI previews and when the
// scheme sets HEYPIGEON_MOCK=1, so UX work needs neither an OAuth client
// nor the Rust build.

import Foundation

@MainActor
final class MockEngine: MailEngine {
    var onThreadsUpdated: (() -> Void)?
    var onAccountDisconnected: ((String) -> Void)?
    var onPrefsUpdated: (() -> Void)?

    private var accountList: [MailAccount]
    private var prefStore: [String: Any] = [:]
    private var rows: [String: ThreadRow]
    private var bodies: [String: [MessageItem]] = [:]
    private var triage: [TriageLabelItem] = [
        TriageLabelItem(id: "tl1", name: "Invoices"),
        TriageLabelItem(id: "tl2", name: "Travel"),
        TriageLabelItem(id: "tl3", name: "Newsletters"),
    ]
    private var aiKey: String?
    private var aiModel = "gpt-4o-mini"
    private var jevKey: String?
    private var autoTriage = false

    init() {
        accountList = [
            MailAccount(id: "me@personal.test", email: "me@personal.test", displayName: "Personal",
                        color: .sky, avatarURL: nil, signature: ""),
            MailAccount(id: "me@work.test", email: "me@work.test", displayName: "Work",
                        color: .coral, avatarURL: nil, signature: "— Peter"),
        ]
        let now = Date()
        func row(_ i: Int, _ account: String, _ from: String, _ addr: String, _ subject: String,
                 _ snippet: String, hoursAgo: Double, unread: Bool = false, count: Int = 1,
                 attachment: Bool = false, pin: Bool = false, priority: TriageLevel? = nil,
                 triage: [String] = []) -> ThreadRow
        {
            ThreadRow(id: "t\(i)", accountId: account, subject: subject, snippet: snippet,
                      lastMessageAt: now.addingTimeInterval(-hoursAgo * 3600), isRead: !unread,
                      isArchived: false, messageCount: count, fromSummary: from, lastFromAddress: addr,
                      scheduledAt: nil, isFollowUp: false, needsReply: false, isStarred: pin,
                      hasAttachment: attachment, priority: priority, triageLabelIds: triage,
                      labels: ["INBOX"] + (pin ? ["STARRED"] : []))
        }
        let sample: [ThreadRow] = [
            row(1, "me@work.test", "Priya Nair", "priya@acme.test", "Q4 roadmap review",
                "Attaching the deck — can you look at slides 4–7 before Thursday?", hoursAgo: 0.4,
                unread: true, count: 3, attachment: true, priority: .high),
            row(2, "me@personal.test", "Tomáš", "tomas@friends.test", "Weekend ride?",
                "Forecast looks good for Saturday morning. Usual place at 8?", hoursAgo: 2.5, unread: true),
            row(3, "me@work.test", "GitHub", "noreply@github.test", "[hey-pigeon] CI passed on main",
                "All 3 jobs succeeded.", hoursAgo: 5, priority: .low, triage: ["tl3"]),
            row(4, "me@personal.test", "Lufthansa", "news@lh.test", "Your trip to Lisbon: check-in opens",
                "Check-in for LH1172 is open. Save time at the airport.", hoursAgo: 20, pin: true, triage: ["tl2"]),
            row(5, "me@work.test", "Ana, Me (4)", "ana@acme.test", "Contract draft v3",
                "I've accepted your changes to §4. One open point on the termination clause.",
                hoursAgo: 27, count: 4, attachment: true, priority: .medium),
            row(6, "me@personal.test", "Apple", "no_reply@apple.test", "Your receipt",
                "Thanks for your purchase.", hoursAgo: 50, triage: ["tl1"]),
            row(7, "me@work.test", "Marek Kováč", "marek@acme.test", "Re: onboarding checklist",
                "Done — added the two missing steps and pinged IT.", hoursAgo: 75, count: 2),
            row(8, "me@personal.test", "Stripe", "receipts@stripe.test", "Invoice INV-0042 paid",
                "Your invoice for October was paid.", hoursAgo: 200, triage: ["tl1"]),
        ]
        rows = Dictionary(uniqueKeysWithValues: sample.map { ($0.id, $0) })
    }

    func accounts() throws -> [MailAccount] { accountList }

    func accountStates() throws -> [AccountState] {
        accountList.map { AccountState(id: $0.id, isConnected: true, syncState: "ok", syncDetail: nil, lastSyncAt: Date()) }
    }

    func labels() throws -> [MailLabelItem] {
        [MailLabelItem(id: "Label_1", accountId: "me@work.test", name: "Invoices"),
         MailLabelItem(id: "Label_2", accountId: "me@personal.test", name: "Travel")]
    }

    func triageLabels() throws -> [TriageLabelItem] { triage }

    func unreadCounts(accountId: String?) throws -> [String: Int] {
        let inbox = try threads(in: .inbox, accountId: accountId, before: nil, limit: 1000)
        return ["inbox": inbox.filter { !$0.isRead }.count]
    }

    func threads(in view: MailView, accountId: String?, before: Date?, limit: Int) throws -> [ThreadRow] {
        var list = rows.values.filter { accountId == nil || $0.accountId == accountId }
        // Same rules as the core: a reminder or Need reply moves an inbox
        // thread into those lists; done mail is in neither.
        switch view {
        case .inbox:
            list = list.filter { !$0.isArchived && $0.scheduledAt == nil && !$0.needsReply }
        case .scheduled: list = list.filter { !$0.isArchived && $0.scheduledAt != nil }
        case .needReply: list = list.filter { !$0.isArchived && $0.needsReply }
        case .starred: list = list.filter { $0.isStarred }
        case .archive: list = list.filter { $0.isArchived }
        case .all: break
        case .trash, .spam, .drafts, .sent: list = []
        case .label(let id, _): list = list.filter { $0.labels.contains(id) }
        }
        if let before { list = list.filter { $0.lastMessageAt < before } }
        return Array(list.sorted { $0.lastMessageAt > $1.lastMessageAt }.prefix(limit))
    }

    func search(_ query: String, limit: Int) throws -> [ThreadRow] {
        // The core's operators (core/src/search.rs); mock rows carry no
        // recipients, so `to:` matches nothing.
        var list = Array(rows.values)
        var words: [String] = []
        for token in query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) {
            if token.hasPrefix("from:"), token.count > 5 {
                let v = token.dropFirst(5)
                list = list.filter { $0.lastFromAddress.lowercased().contains(v) }
            } else if token.hasPrefix("to:"), token.count > 3 {
                list = []
            } else if token.hasPrefix("account:"), token.count > 8 {
                let v = token.dropFirst(8)
                list = list.filter { $0.accountId.lowercased().contains(v) }
            } else if token == "is:unread" {
                list = list.filter { !$0.isRead }
            } else {
                words.append(token)
            }
        }
        let q = words.joined(separator: " ")
        return list
            .filter { q.isEmpty || $0.subject.lowercased().contains(q) || $0.fromSummary.lowercased().contains(q) || $0.snippet.lowercased().contains(q) }
            .sorted { $0.lastMessageAt > $1.lastMessageAt }
            .prefix(limit)
            .map { $0 }
    }

    func draft(threadId: String) async throws -> SendDraft? {
        guard let row = rows[threadId] else { return nil }
        var d = SendDraft()
        d.to = [row.lastFromAddress]
        d.subject = row.subject
        d.bodyText = row.snippet
        d.fromAccountId = row.accountId
        d.draftKey = "mock\(threadId)"
        d.draftSaved = true
        return d
    }

    func thread(id: String) async throws -> ThreadDetail? {
        guard let row = rows[id] else { return nil }
        if bodies[id] == nil {
            try? await Task.sleep(for: .milliseconds(250)) // the first-open body fetch
            var msgs: [MessageItem] = []
            for i in 0..<row.messageCount {
                let mine = i % 2 == 1
                msgs.append(MessageItem(
                    id: "\(id)-m\(i)", fromName: mine ? "Me" : row.fromSummary.components(separatedBy: ",").first ?? row.fromSummary,
                    fromAddress: mine ? row.accountId : row.lastFromAddress, to: [mine ? row.lastFromAddress : "me"],
                    date: row.lastMessageAt.addingTimeInterval(Double(i - row.messageCount + 1) * 5400),
                    snippet: row.snippet,
                    bodyHTML: "<p>\(row.snippet)</p><p>Second paragraph with a <a href=\"https://example.com\">link</a> and an image that must not load: <img src=\"https://tracker.example/pixel.gif\"></p>",
                    bodyText: row.snippet, isRead: true, isMine: mine))
            }
            bodies[id] = msgs
        }
        return ThreadDetail(thread: row, messages: bodies[id] ?? [])
    }

    /// Bodies only once `thread(id:)` fetched them, like the store.
    func threadLocal(id: String) throws -> ThreadDetail? {
        guard let row = rows[id] else { return nil }
        return ThreadDetail(thread: row, messages: bodies[id] ?? [])
    }

    func threadRow(id: String) throws -> ThreadRow? { rows[id] }

    /// The rows with a paperclip get a PDF and, for the contract, an image.
    func attachments(threadId: String) async throws -> [AttachmentItem] {
        guard let row = rows[threadId], row.hasAttachment else { return [] }
        var out = [AttachmentItem(threadId: threadId, messageId: "\(threadId)-m0", attachmentId: "a1",
                                  filename: threadId == "t1" ? "Q4-roadmap.pdf" : "contract-v3.pdf", mimeType: "application/pdf", size: 184_320)]
        if threadId == "t5" {
            out.append(AttachmentItem(threadId: threadId, messageId: "\(threadId)-m0", attachmentId: "a2",
                                      filename: "receipt.png", mimeType: "image/png", size: 2_048))
        }
        return out
    }

    /// A tiny file in the temporary directory stands in for the download.
    func attachmentFile(_ a: AttachmentItem) async throws -> URL {
        try? await Task.sleep(for: .milliseconds(200))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mock-\(a.attachmentId)-\(a.filename)")
        if !FileManager.default.fileExists(atPath: url.path) {
            // A 1×1 white PNG; the PDF is a minimal one-page document.
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=")!
            let pdf = Data("%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\ntrailer<</Root 1 0 R>>".utf8)
            try (a.isPDF ? pdf : png).write(to: url)
        }
        return url
    }

    func perform(_ action: MailAction, accountId: String) async throws {
        switch action {
        case .archive(let id): update(id) { $0.isArchived = true; $0.scheduledAt = nil; $0.isFollowUp = false; $0.needsReply = false }
        case .unarchive(let id): update(id) { $0.isArchived = false }
        case .markRead(let id, let read): update(id) { $0.isRead = read }
        case .trash(let id): rows.removeValue(forKey: id)
        case .star(let id, let starred): update(id) { $0.isStarred = starred }
        case .modifyLabel(let id, let label, let add):
            update(id) { $0.labels = add ? Array(Set($0.labels + [label])) : $0.labels.filter { $0 != label } }
        case .send, .saveDraft, .deleteDraft: try? await Task.sleep(for: .milliseconds(300))
        }
        onThreadsUpdated?()
    }

    func setReminder(threadId: String, at date: Date?, onlyIfNoReply: Bool) throws {
        update(threadId) { $0.scheduledAt = date; $0.isFollowUp = date != nil && onlyIfNoReply }
        onThreadsUpdated?()
    }

    func setNeedsReply(threadId: String, _ value: Bool) throws {
        update(threadId) { $0.needsReply = value }
        onThreadsUpdated?()
    }

    func setManualTriageLabels(threadId: String, ids: [String]) throws {
        update(threadId) { $0.triageLabelIds = ids }
        onThreadsUpdated?()
    }

    func updateAccount(id: String, displayName: String?, color: AccountColor?, signature: String?) throws {
        guard let i = accountList.firstIndex(where: { $0.id == id }) else { return }
        let a = accountList[i]
        accountList[i] = MailAccount(id: a.id, email: a.email, displayName: displayName ?? a.displayName,
                                     color: color ?? a.color, avatarURL: a.avatarURL, signature: signature ?? a.signature)
        onThreadsUpdated?()
    }

    func prefs() throws -> [String: Any] { prefStore }
    func setPref(_ name: String, _ value: Any?) throws { prefStore[name] = value }

    func removeAccount(id: String) async throws {
        accountList.removeAll { $0.id == id }
        rows = rows.filter { $0.value.accountId != id }
        onThreadsUpdated?()
    }

    func syncAll() async throws -> Bool {
        try? await Task.sleep(for: .milliseconds(600))
        return false
    }

    func syncNow(accountId: String) async throws -> Bool {
        try await syncAll()
    }

    func backfillOlder() async throws -> Bool { false }

    // MARK: Push relay (pretend)

    private var pushRelayURL: String?
    private var pushWatchExpiry: Date?

    func registerPushToken(relayURL: String, deviceToken: String, environment: String) async throws {
        try? await Task.sleep(for: .milliseconds(400))
        pushRelayURL = relayURL
        pushWatchExpiry = Date().addingTimeInterval(7 * 86_400)
    }

    func disablePush() async throws {
        pushRelayURL = nil
        pushWatchExpiry = nil
    }

    func pushStatus() throws -> PushState {
        PushState(
            enabled: pushRelayURL != nil,
            relayURL: pushRelayURL,
            topic: pushRelayURL == nil ? nil : "projects/mock/topics/gmail-push",
            accounts: accountList.map { PushAccountState(id: $0.id, watchExpiresAt: pushWatchExpiry) }
        )
    }

    func beginOAuth(loginHint: String?) throws -> OAuthStart {
        OAuthStart(url: URL(string: "https://accounts.google.com/")!, callbackScheme: "mock")
    }

    func finishOAuth(callbackURL: URL) async throws -> String { "new@account.test" }

    // MARK: AI

    /// The sample inbox pretends to have no on-device model and no reach to
    /// Apple's cloud; set these true in a preview to see the rows in Settings.
    var onDeviceAI = false
    var cloudAI = false
    private var aiProvider: AIProvider?
    private var aiFallback: [AIProvider] = []
    private var triageClassifier: TriageClassifier?

    /// The engine's rule (crates/ffi/src/settings.rs active_provider): the
    /// preferred provider when it can answer, else the first of the
    /// fallback order that can.
    private func canAnswer(_ p: AIProvider) -> Bool {
        switch p {
        case .apple: onDeviceAI
        case .appleCloud: cloudAI
        case .openai: aiKey != nil
        case .other: false
        }
    }

    private var availableProviderIds: [String] {
        (onDeviceAI ? ["apple"] : []) + (cloudAI ? ["apple-cloud"] : [])
    }

    func aiStatus() throws -> AIStatus {
        let fallback = aiFallback.isEmpty ? AIProvider.defaultFallback : aiFallback
        let preferred = aiProvider ?? AIProvider.defaultFallback.first { $0 != .openai && canAnswer($0) } ?? .openai
        let active = ([preferred] + fallback).first(where: canAnswer)
        return AIStatus(configured: active != nil, providerId: active?.rawValue, model: aiKey == nil ? nil : aiModel,
                        preferredProviderId: preferred.rawValue, onDeviceAvailable: onDeviceAI, openaiConfigured: aiKey != nil,
                        availableProviderIds: availableProviderIds, fallbackOrder: fallback.map(\.rawValue))
    }
    func setAIProvider(_ provider: AIProvider) throws { aiProvider = provider }
    func setAIFallback(_ order: [AIProvider]) throws { aiFallback = order }
    func aiProviders() -> [AIProviderInfo] {
        [AIProviderInfo(id: "apple", title: "On this \(Device.name)", modelLabel: "On this \(Device.name)", leavesDevice: false,
                        available: onDeviceAI, unavailableReason: onDeviceAI ? nil : "Apple Intelligence isn't available in the sample inbox."),
         AIProviderInfo(id: "apple-cloud", title: "Apple's cloud", modelLabel: "Private Cloud Compute", leavesDevice: true,
                        available: cloudAI, unavailableReason: cloudAI ? nil : "Private Cloud Compute isn't reachable in the sample inbox.")]
    }
    func refreshAIProviders() {}
    func aiModels() throws -> [AIModel] {
        [AIModel(id: "gpt-4o-mini", label: "GPT-4o mini"), AIModel(id: "gpt-4o", label: "GPT-4o")]
    }
    func setAIKey(_ key: String) async throws {
        try? await Task.sleep(for: .milliseconds(400))
        aiKey = key
    }
    func removeAIKey() throws { aiKey = nil }
    func setAIModel(_ model: String) throws { aiModel = model }
    func aiEditText(instruction: String, text: String, history: String?) async throws -> String {
        try? await Task.sleep(for: .milliseconds(500))
        if instruction.hasPrefix(AIEditSheet.writePrefix) {
            // Compose from a brief (AIEditSheet's Write mode).
            return "Hi,\n\n\(text)\n\nLet me know if [detail] works for you.\n\nThanks"
        }
        return "\(text)\n\n(\(instruction.lowercased()))"
    }
    func aiDraftReply(subject: String, history: String, notes: String?) async throws -> String {
        try? await Task.sleep(for: .milliseconds(500))
        return "Thanks — I'll take a look and get back to you by [day]."
    }
    func aiSummarizeThread(subject: String, items: [(from: String, snippet: String)]) async throws -> String {
        try? await Task.sleep(for: .milliseconds(500))
        return "\(items.first?.from ?? "They") is waiting on you about \"\(subject)\"."
    }
    func aiSummarizeGroup(items: [(from: String, subject: String, snippet: String)]) async throws -> String {
        try? await Task.sleep(for: .milliseconds(500))
        return "You've got \(items.count) active emails; \(items.first?.from ?? "someone") wants a look at \"\(items.first?.subject ?? "")\"."
    }

    /// The desktop's prompts, abridged: the evaluation harness only needs
    /// the format rules it checks for.
    func aiPrompts() -> AIPrompts {
        AIPrompts(
            summary: "You write a factual digest of the user's active emails. Return 1 to 4 bullet points, each on its own line starting with \"- \". Wrap the key facts in **double asterisks** for bold. Use only \"- \" bullets and **bold**. No headers, no other markdown, no preamble, no closing line.",
            threadSummary: "You write a factual recap of one email conversation. Return 1 to 4 bullet points, each on its own line starting with \"- \". Wrap the key facts in **double asterisks** for bold. No headers, no other markdown.",
            draftReply: "You are drafting an email reply on behalf of the user. Return ONLY the reply body as plain text.",
            edit: "Apply the user's instruction to the given text and return ONLY the revised text."
        )
    }

    // MARK: Triage

    func triageStatus() throws -> TriageStatus {
        let preferred = triageClassifier ?? (onDeviceAI ? .apple : cloudAI ? .appleCloud : .jev)
        let available = availableProviderIds + (jevKey != nil ? ["jev"] : [])
        return TriageStatus(configured: !available.isEmpty, enabled: autoTriage, lastError: nil,
                            classifierId: preferred.rawValue, onDeviceAvailable: onDeviceAI, jevConfigured: jevKey != nil,
                            availableClassifierIds: available)
    }
    func setTriageClassifier(_ classifier: TriageClassifier) throws { triageClassifier = classifier }
    func setJevKey(_ key: String) async throws {
        try? await Task.sleep(for: .milliseconds(400))
        jevKey = key
    }
    func removeJevKey() throws { jevKey = nil }
    func setAutoTriage(_ enabled: Bool) throws { autoTriage = enabled }
    func createTriageLabel(name: String) throws -> TriageLabelItem {
        let l = TriageLabelItem(id: "tl\(triage.count + 1)-\(UUID().uuidString.prefix(4))", name: name)
        triage.append(l)
        return l
    }
    func renameTriageLabel(id: String, name: String) throws {
        triage = triage.map { $0.id == id ? TriageLabelItem(id: id, name: name) : $0 }
    }
    func deleteTriageLabel(id: String) throws {
        triage.removeAll { $0.id == id }
        for r in rows.values where r.triageLabelIds.contains(id) {
            update(r.id) { $0.triageLabelIds.removeAll { $0 == id } }
        }
        onThreadsUpdated?()
    }
    func reanalyzeTriage() throws {}

    // ThreadRow is immutable on purpose; rebuild it through a mutable copy.
    private struct Draft {
        var isRead: Bool, isArchived: Bool, scheduledAt: Date?, isFollowUp: Bool,
            needsReply: Bool, isStarred: Bool, labels: [String], triageLabelIds: [String]
    }

    private func update(_ id: String, _ change: (inout Draft) -> Void) {
        guard let r = rows[id] else { return }
        var d = Draft(isRead: r.isRead, isArchived: r.isArchived, scheduledAt: r.scheduledAt,
                      isFollowUp: r.isFollowUp, needsReply: r.needsReply, isStarred: r.isStarred,
                      labels: r.labels, triageLabelIds: r.triageLabelIds)
        change(&d)
        rows[id] = ThreadRow(id: r.id, accountId: r.accountId, subject: r.subject, snippet: r.snippet,
                             lastMessageAt: r.lastMessageAt, isRead: d.isRead, isArchived: d.isArchived,
                             messageCount: r.messageCount, fromSummary: r.fromSummary, lastFromAddress: r.lastFromAddress,
                             scheduledAt: d.scheduledAt, isFollowUp: d.isFollowUp, needsReply: d.needsReply,
                             isStarred: d.isStarred, hasAttachment: r.hasAttachment, priority: r.priority,
                             triageLabelIds: d.triageLabelIds, labels: d.labels)
    }
}
