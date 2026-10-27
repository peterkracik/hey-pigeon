// Observable app state: the one object the views read. Owns the engine,
// the current view/account, the loaded rows, sync state and the undo toast.
// All mutations go through here so optimistic UI + undo live in one place.

import BackgroundTasks
import Foundation
import Observation
import SwiftUI

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var undo: (() -> Void)?

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

@MainActor
@Observable
final class AppModel {
    static let refreshTaskId = "app.heypigeon.refresh"
    static let pageSize = 50

    let engine: MailEngine
    let oauth = OAuthCoordinator()

    private(set) var accounts: [MailAccount] = []
    private(set) var accountStates: [String: AccountState] = [:]
    private(set) var labels: [MailLabelItem] = []
    private(set) var counts: [String: Int] = [:]

    /// nil = unified across accounts (desktop's `0`).
    var selectedAccountId: String? { didSet { reload() } }
    var view: MailView = .inbox { didSet { reload() } }

    private(set) var rows: [ThreadRow] = []
    private(set) var hasMore = true
    private(set) var isSyncing = false
    private(set) var lastSyncAt: Date?
    private(set) var hasLoadedOnce = false

    var searchText = "" { didSet { runSearch() } }
    private(set) var searchResults: [ThreadRow] = []
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var toast: Toast?
    var pendingRemind: ThreadRow?
    var composeDraft: SendDraft?
    var showAccounts = false
    var showSettings = false
    var disconnectedAccountId: String?

    var currentAccount: MailAccount? { accounts.first { $0.id == selectedAccountId } }
    var triageLevelsPresent: Bool { rows.contains { $0.priority != nil } }

    init(engine: MailEngine) {
        self.engine = engine
        engine.onThreadsUpdated = { [weak self] in self?.reload() }
        engine.onAccountDisconnected = { [weak self] id in
            self?.disconnectedAccountId = id
            self?.reloadAccounts()
        }
        reloadAccounts()
        reload()
    }

    // MARK: Loading

    func reloadAccounts() {
        accounts = (try? engine.accounts()) ?? []
        accountStates = Dictionary(uniqueKeysWithValues: ((try? engine.accountStates()) ?? []).map { ($0.id, $0) })
        labels = (try? engine.labels()) ?? []
        if let selected = selectedAccountId, !accounts.contains(where: { $0.id == selected }) {
            selectedAccountId = nil
        }
    }

    func reload() {
        rows = (try? engine.threads(in: view, accountId: selectedAccountId, before: nil, limit: Self.pageSize)) ?? []
        hasMore = rows.count == Self.pageSize
        counts = (try? engine.unreadCounts(accountId: selectedAccountId)) ?? [:]
        hasLoadedOnce = true
        if isSearching { runSearch() }
    }

    func loadMoreIfNeeded(current row: ThreadRow) {
        guard hasMore, row.id == rows.last?.id, let last = rows.last else { return }
        let more = (try? engine.threads(in: view, accountId: selectedAccountId, before: last.lastMessageAt, limit: Self.pageSize)) ?? []
        rows.append(contentsOf: more)
        hasMore = more.count == Self.pageSize
    }

    private func runSearch() {
        guard isSearching else { searchResults = []; return }
        searchResults = (try? engine.search(searchText, limit: 50)) ?? []
    }

    /// Rows grouped by day (or by due bucket in Scheduled), newest first.
    var groupedRows: [(title: String, rows: [ThreadRow])] {
        let source = isSearching ? searchResults : rows
        var order: [String] = []
        var groups: [String: [ThreadRow]] = [:]
        for r in source {
            let key: String = switch view {
            case .scheduled where !isSearching: Formatters.dueGroup(r.scheduledAt ?? r.lastMessageAt)
            default: Formatters.dayGroup(r.lastMessageAt)
            }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(r)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    // MARK: Sync

    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            _ = try await engine.syncAll()
            lastSyncAt = Date()
            reloadAccounts()
            reload()
            await ReminderScheduler.reschedule((try? engine.threads(in: .scheduled, accountId: nil, before: nil, limit: 500)) ?? [])
        } catch {
            show("Sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: Actions (optimistic: the engine applies locally before returning)

    func archive(_ row: ThreadRow) {
        Haptics.archive()
        perform(.archive(threadId: row.id), on: row, toast: "Archived") { [weak self] in
            self?.perform(.unarchive(threadId: row.id), on: row)
        }
    }

    func unarchive(_ row: ThreadRow) {
        perform(.unarchive(threadId: row.id), on: row, toast: "Moved to inbox")
    }

    func toggleRead(_ row: ThreadRow) {
        Haptics.light()
        perform(.markRead(threadId: row.id, read: !row.isRead), on: row)
    }

    func markRead(_ row: ThreadRow) {
        guard !row.isRead else { return }
        perform(.markRead(threadId: row.id, read: true), on: row)
    }

    func toggleStar(_ row: ThreadRow) {
        Haptics.light()
        perform(.star(threadId: row.id, starred: !row.isStarred), on: row)
    }

    func trash(_ row: ThreadRow) {
        Haptics.warning()
        perform(.trash(threadId: row.id), on: row, toast: "Moved to trash")
    }

    func toggleNeedsReply(_ row: ThreadRow) {
        Haptics.light()
        do {
            try engine.setNeedsReply(threadId: row.id, !row.needsReply)
            show(row.needsReply ? "Removed from Need reply" : "Marked Need reply")
        } catch { show(error.localizedDescription) }
    }

    func remind(_ row: ThreadRow, at date: Date?, onlyIfNoReply: Bool) {
        do {
            try engine.setReminder(threadId: row.id, at: date, onlyIfNoReply: onlyIfNoReply)
            if let date {
                Haptics.success()
                show(onlyIfNoReply ? "Will remind you \(Formatters.reminder(date)) if nobody replies"
                                   : "Reminder set for \(Formatters.reminder(date))")
            } else {
                show("Reminder removed")
            }
            reload()
        } catch { show(error.localizedDescription) }
    }

    func send(_ draft: SendDraft, from accountId: String) async {
        do {
            try await engine.perform(.send(draft), accountId: accountId)
            Haptics.success()
            show("Sent")
        } catch { show("Couldn't send: \(error.localizedDescription)") }
    }

    private func perform(_ action: MailAction, on row: ThreadRow, toast text: String? = nil, undo: (() -> Void)? = nil) {
        // Slide the row out immediately in views where the action removes it.
        if view.archivesOut, case .archive = action { rows.removeAll { $0.id == row.id } }
        if case .trash = action { rows.removeAll { $0.id == row.id } }
        Task {
            do {
                try await engine.perform(action, accountId: row.accountId)
            } catch {
                show("Couldn't apply: \(error.localizedDescription)")
                reload()
            }
        }
        if let text { show(text, undo: undo) }
    }

    func show(_ text: String, undo: (() -> Void)? = nil) {
        toast = Toast(text: text, undo: undo)
    }

    // MARK: Accounts

    func addAccount(loginHint: String? = nil) async {
        do {
            let start = try engine.beginOAuth(loginHint: loginHint)
            let callback = try await oauth.authorize(start)
            let email = try await engine.finishOAuth(callbackURL: callback)
            reloadAccounts()
            show("Connected \(email)")
            if disconnectedAccountId == email { disconnectedAccountId = nil }
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            show("Couldn't connect: \(error.localizedDescription)")
        }
    }

    func removeAccount(_ account: MailAccount) {
        do {
            try engine.removeAccount(id: account.id)
            reloadAccounts()
            reload()
        } catch { show(error.localizedDescription) }
    }

    // MARK: Background refresh

    /// iOS decides when this runs (a few times a day in practice). It is the
    /// only "push" the phone has in v1 — DESIGN.md's relay stays optional.
    static func registerBackgroundRefresh(_ model: AppModel) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskId, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            let work = Task { @MainActor in
                await model.sync()
                task.setTaskCompleted(success: true)
                scheduleBackgroundRefresh()
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
