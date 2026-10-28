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
        let now = Date()
        var list = rows.values.filter { accountId == nil || $0.accountId == accountId }
        switch view {
        case .inbox:
            list = list.filter { !$0.isArchived && ($0.scheduledAt.map { $0 <= now } ?? true) }
        case .scheduled: list = list.filter { $0.scheduledAt != nil }
        case .needReply: list = list.filter { $0.needsReply }
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
        let q = query.lowercased()
        return rows.values
            .filter { $0.subject.lowercased().contains(q) || $0.fromSummary.lowercased().contains(q) || $0.snippet.lowercased().contains(q) }
            .sorted { $0.lastMessageAt > $1.lastMessageAt }
            .prefix(limit)
            .map { $0 }
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

    func perform(_ action: MailAction, accountId: String) async throws {
        switch action {
        case .archive(let id): update(id) { $0.isArchived = true }
        case .unarchive(let id): update(id) { $0.isArchived = false }
        case .markRead(let id, let read): update(id) { $0.isRead = read }
        case .trash(let id): rows.removeValue(forKey: id)
        case .star(let id, let starred): update(id) { $0.isStarred = starred }
        case .modifyLabel(let id, let label, let add):
            update(id) { $0.labels = add ? Array(Set($0.labels + [label])) : $0.labels.filter { $0 != label } }
        case .send: try? await Task.sleep(for: .milliseconds(300))
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

    func aiStatus() throws -> AIStatus {
        AIStatus(configured: aiKey != nil, providerId: aiKey == nil ? nil : "openai", model: aiKey == nil ? nil : aiModel)
    }
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

    // MARK: Triage

    func triageStatus() throws -> TriageStatus {
        TriageStatus(configured: jevKey != nil, enabled: autoTriage, lastError: nil)
    }
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
