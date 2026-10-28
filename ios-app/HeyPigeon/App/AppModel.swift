// Observable app state: the one object the views read. Owns the engine,
// the current view/account, the loaded rows, sync state, the synced
// preferences (engine-backed, like the desktop's), and the undo toast. All
// mutations go through here so optimistic UI + undo live in one place.

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

/// One AI summary — a day group's (desktop InboxList "Summarize N active")
/// or an open thread's — cached against the content it was made from.
struct GroupSummary: Equatable {
    var cacheKey: String
    var text: String?
    var error: String?
    var generating = false
}

/// What the summary sheet shows: the cache key and a title.
struct SummaryPresentation: Identifiable, Equatable {
    let id: String
    let title: String
}

struct RowGroup: Identifiable {
    let title: String
    let rows: [ThreadRow]
    let isPinned: Bool
    var id: String { title }
    /// Rows worth summarizing: not done.
    var active: [ThreadRow] { rows.filter { !$0.isDone } }
    var summaryKey: String { title + "|" + active.map(\.id).joined(separator: ",") }
}

@MainActor
@Observable
final class AppModel {
    static let refreshTaskId = "app.heypigeon.refresh"
    static let pageSize = 50

    /// The one model of the process, for the UIKit delegate (AppDelegate)
    /// that has no SwiftUI environment to read it from.
    private(set) static var current: AppModel?

    let engine: MailEngine
    let oauth = OAuthCoordinator()
    /// "New mail (push)" — the optional relay (relay/README.md).
    let push: PushController

    private(set) var accounts: [MailAccount] = []
    private(set) var accountStates: [String: AccountState] = [:]
    private(set) var labels: [MailLabelItem] = []
    private(set) var triageLabels: [TriageLabelItem] = []
    private(set) var counts: [String: Int] = [:]
    private(set) var aiConfigured = false

    /// nil = unified across accounts (desktop's `0`).
    var selectedAccountId: String? { didSet { reload() } }
    /// Bottom bar selection.
    var tab: MainTab = .inbox {
        didSet {
            Keyboard.dismiss()
            reload()
        }
    }
    /// Folder/label the Inbox tab shows; the other tabs have fixed views.
    var folder: MailView = .inbox {
        didSet {
            triageFilterId = nil
            reload()
        }
    }
    /// Jev label the list is narrowed to (the bottom pill). nil = all.
    var triageFilterId: String?

    /// What the list currently shows, derived from tab + folder.
    var view: MailView {
        switch tab {
        case .inbox, .search: folder
        case .scheduled: .scheduled
        case .needReply: .needReply
        }
    }

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
    var showSidebar = false
    var showSettings = false

    /// Scheduled / Need reply counts for the sidebar and the title.
    var scheduledCount: Int { scheduledThreads(accountId: selectedAccountId).count }
    var needReplyCount: Int { (try? engine.threads(in: .needReply, accountId: selectedAccountId, before: nil, limit: 500))?.count ?? 0 }
    /// Reminders due today — the Scheduled tab's badge. The app icon badge
    /// adds the unified count (NewMailNotifier.refreshBadge).
    var dueTodayCount: Int { Self.dueToday(scheduledThreads(accountId: selectedAccountId)).count }

    /// Every scheduled thread (archived and snoozed ones too, like the
    /// Scheduled tab), one account or all.
    func scheduledThreads(accountId: String?) -> [ThreadRow] {
        (try? engine.threads(in: .scheduled, accountId: accountId, before: nil, limit: 500)) ?? []
    }

    /// "Scheduled for today": the reminder's time falls on today's calendar
    /// day, fired already or not. Overdue from earlier days is not today's
    /// badge, and tomorrow's is not yet.
    static func dueToday(_ threads: [ThreadRow], now: Date = Date()) -> [ThreadRow] {
        let cal = Calendar.current
        return threads.filter { t in t.scheduledAt.map { cal.isDate($0, inSameDayAs: now) } ?? false }
    }

    var disconnectedAccountId: String?
    var currentAccount: MailAccount? { accounts.first { $0.id == selectedAccountId } }

    /// A notification tap asked for this thread; the inbox screen consumes it.
    var pendingThreadId: String?

    // MARK: Preferences — engine-backed and synced between devices
    // (DESIGN.md "Cross-device sync": `pref:<name>` keys in the same Drive
    // channel as reminders; the desktop reads the same names). UserDefaults
    // only seeds a value the engine has never seen, once, for installs that
    // predate the sync.

    private enum PrefName {
        static let pinList = "pin_list"
        static let autoSummarize = "auto_summarize"
        /// Separate from the desktop's `hover_actions`: the gesture sets differ.
        static let swipeActions = "swipe_actions"
    }

    /// Group pinned messages at the top of the inbox.
    var pinListEnabled = true {
        didSet { savePref(PrefName.pinList, pinListEnabled) }
    }
    /// Generate AI summaries without a click.
    var autoSummarize = false {
        didSet { savePref(PrefName.autoSummarize, autoSummarize) }
    }
    /// Swipe tiers: right short, right long, left short, left long — the
    /// desktop's "Hover actions", translated to the phone's gesture.
    var swipeActions: [RowAction] = AppModel.defaultSwipeActions {
        didSet { savePref(PrefName.swipeActions, swipeActions.map(\.rawValue)) }
    }
    static let defaultSwipeActions: [RowAction] = [.read, .done, .remind, .needReply]
    /// Bumped when another device changed a synced setting; views that
    /// cache engine status (Settings' AI and Triage sections) reload on it.
    private(set) var prefsVersion = 0
    /// True while prefs are being adopted from the engine, so the didSets
    /// above do not write them straight back.
    private var adoptingPrefs = false

    private func savePref(_ name: String, _ value: Any) {
        guard !adoptingPrefs else { return }
        do { try engine.setPref(name, value) } catch { show("Couldn't save setting: \(error.localizedDescription)") }
    }

    /// Read the synced prefs; a name the engine has never seen but
    /// UserDefaults has (a pre-sync install) is migrated in, once.
    private func loadPrefs() {
        var prefs = (try? engine.prefs()) ?? [:]
        let defaults = UserDefaults.standard
        let legacy: [(name: String, key: String, value: Any?)] = [
            (PrefName.pinList, "pinListEnabled", defaults.object(forKey: "pinListEnabled") as? Bool),
            (PrefName.autoSummarize, "autoSummarize", defaults.object(forKey: "autoSummarize") as? Bool),
            (PrefName.swipeActions, "swipeActions", defaults.stringArray(forKey: "swipeActions")),
        ]
        for item in legacy where prefs[item.name] == nil {
            guard let value = item.value else { continue }
            guard (try? engine.setPref(item.name, value)) != nil else { continue }
            prefs[item.name] = value
            defaults.removeObject(forKey: item.key)
        }
        adoptingPrefs = true
        if let v = prefs[PrefName.pinList] as? Bool { pinListEnabled = v }
        if let v = prefs[PrefName.autoSummarize] as? Bool { autoSummarize = v }
        if let raw = prefs[PrefName.swipeActions] as? [String] {
            let actions = raw.compactMap(RowAction.init(rawValue:))
            if actions.count == 4 { swipeActions = actions }
        }
        adoptingPrefs = false
    }

    /// Another device changed a synced setting: re-read the prefs, the
    /// accounts (name, colour, signature), the triage labels and the AI
    /// model, and tell the views that cache engine status.
    private func adoptRemoteSettings() {
        loadPrefs()
        reloadAccounts()
        reload()
        prefsVersion += 1
    }

    private(set) var groupSummaries: [String: GroupSummary] = [:]
    /// The summary sheet, when one is open (slides up like compose).
    var summarySheet: SummaryPresentation?

    init(engine: MailEngine) {
        self.engine = engine
        push = PushController(engine: engine)
        engine.onThreadsUpdated = { [weak self] in self?.reload() }
        engine.onAccountDisconnected = { [weak self] id in
            self?.disconnectedAccountId = id
            self?.reloadAccounts()
        }
        engine.onPrefsUpdated = { [weak self] in self?.adoptRemoteSettings() }
        loadPrefs()
        reloadAccounts()
        reload()
        push.notify = { [weak self] text in self?.show(text) }
        AppModel.current = self
    }

    // MARK: Loading

    func reloadAccounts() {
        accounts = (try? engine.accounts()) ?? []
        accountStates = Dictionary(uniqueKeysWithValues: ((try? engine.accountStates()) ?? []).map { ($0.id, $0) })
        labels = (try? engine.labels()) ?? []
        triageLabels = (try? engine.triageLabels()) ?? []
        aiConfigured = (try? engine.aiStatus())?.configured ?? false
        if let selected = selectedAccountId, !accounts.contains(where: { $0.id == selected }) {
            selectedAccountId = nil
        }
        if let f = triageFilterId, !triageLabels.contains(where: { $0.id == f }) {
            triageFilterId = nil
        }
    }

    func reload() {
        rows = (try? engine.threads(in: view, accountId: selectedAccountId, before: nil, limit: Self.pageSize)) ?? []
        hasMore = rows.count == Self.pageSize
        counts = (try? engine.unreadCounts(accountId: selectedAccountId)) ?? [:]
        hasLoadedOnce = true
        if isSearching { runSearch() }
        if autoSummarize && aiConfigured { runAutoSummaries() }
        // Anything that changes the list can change the icon badge: a read,
        // a reminder set for later today, another device's edit.
        Task { await NewMailNotifier.refreshBadge(self) }
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

    /// The desktop's groups exactly: Pinned (inbox, when enabled) · Today ·
    /// Last 7 days · Older; the Scheduled tab buckets by due date instead.
    var groupedRows: [RowGroup] {
        var source = isSearching ? searchResults : rows
        if let f = triageFilterId, tab == .inbox, !isSearching {
            source = source.filter { $0.triageLabelIds.contains(f) }
        }
        if view == .scheduled && !isSearching {
            return bucket(source, titles: ["Overdue", "Today", "Tomorrow", "This week", "Later"]) {
                Formatters.dueGroup($0.scheduledAt ?? $0.lastMessageAt)
            }
        }
        var head: [RowGroup] = []
        if pinListEnabled && view == .inbox && !isSearching {
            let pinned = source.filter(\.isPinned)
            if !pinned.isEmpty {
                head = [RowGroup(title: "Pinned", rows: pinned, isPinned: true)]
                source = source.filter { !$0.isPinned }
            }
        }
        return head + bucket(source, titles: ["Today", "Last 7 days", "Older"]) { Formatters.dayGroup($0.lastMessageAt) }
    }

    private func bucket(_ rows: [ThreadRow], titles: [String], key: (ThreadRow) -> String) -> [RowGroup] {
        var groups: [String: [ThreadRow]] = [:]
        for r in rows { groups[key(r), default: []].append(r) }
        return titles.compactMap { t in groups[t].map { RowGroup(title: t, rows: $0, isPinned: false) } }
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
        // The app icon badge is the unified unread count plus today's
        // reminders — with or without push. Awaited here so a background
        // refresh finishes it before the task is marked complete.
        await NewMailNotifier.refreshBadge(self)
    }

    /// Deep link from a notification (reminder or new mail): the inbox tab
    /// pushes the thread when it sees `pendingThreadId`.
    func openThread(id: String) {
        tab = .inbox
        pendingThreadId = id
    }

    /// Resolve a pending deep link to a row, searching the loaded inbox
    /// first and the store second. Nil clears nothing — the screen decides.
    func row(forThreadId id: String) -> ThreadRow? {
        if let r = groupedRows.flatMap(\.rows).first(where: { $0.id == id }) { return r }
        for view in [MailView.inbox, .scheduled, .needReply, .all] {
            if let r = (try? engine.threads(in: view, accountId: nil, before: nil, limit: 500))?.first(where: { $0.id == id }) {
                return r
            }
        }
        return nil
    }

    // MARK: Actions — the desktop's set, same names (optimistic; the
    // engine applies locally before returning)

    /// Desktop `e`: archive is "done".
    func markDone(_ row: ThreadRow) {
        Haptics.archive()
        perform(.archive(threadId: row.id), on: row, toast: "Marked done") { [weak self] in
            self?.perform(.unarchive(threadId: row.id), on: row)
        }
    }

    func markNotDone(_ row: ThreadRow) {
        perform(.unarchive(threadId: row.id), on: row, toast: "Moved to inbox")
    }

    func toggleDone(_ row: ThreadRow) {
        if row.isDone { markNotDone(row) } else { markDone(row) }
    }

    func toggleRead(_ row: ThreadRow) {
        Haptics.light()
        perform(.markRead(threadId: row.id, read: !row.isRead), on: row)
    }

    func markRead(_ row: ThreadRow) {
        guard !row.isRead else { return }
        perform(.markRead(threadId: row.id, read: true), on: row)
    }

    /// Desktop `s`: pin is the Gmail star.
    func togglePin(_ row: ThreadRow) {
        Haptics.light()
        perform(.star(threadId: row.id, starred: !row.isPinned), on: row, toast: row.isPinned ? "Unpinned" : "Pinned")
    }

    /// Desktop `#`.
    func delete(_ row: ThreadRow) {
        Haptics.warning()
        perform(.trash(threadId: row.id), on: row, toast: "Deleted")
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

    /// Desktop `l`: add or remove one Gmail label.
    func setLabel(_ row: ThreadRow, _ label: MailLabelItem, on: Bool) {
        perform(.modifyLabel(threadId: row.id, labelId: label.id, add: on), on: row,
                toast: on ? "Label added · \(label.name)" : "Label removed · \(label.name)")
    }

    /// Desktop `v`: classic Gmail move — the label AND done.
    func move(_ row: ThreadRow, to label: MailLabelItem) {
        if view == .trash || view == .spam {
            setLabel(row, label, on: true)
            show("Labeled, not moved · \(label.name) added — mail stays in \(view.title)")
            return
        }
        perform(.modifyLabel(threadId: row.id, labelId: label.id, add: true), on: row)
        markDone(row)
    }

    /// Manual Jev label edit — sticky until "Reanalyze all emails".
    func setTriageLabels(_ row: ThreadRow, _ ids: [String]) {
        do { try engine.setManualTriageLabels(threadId: row.id, ids: ids) } catch { show(error.localizedDescription) }
    }

    /// Swipe tiers and the Settings picker dispatch through here.
    func run(_ action: RowAction, on row: ThreadRow) {
        switch action {
        case .done: toggleDone(row)
        case .delete: delete(row)
        case .remind: pendingRemind = row
        case .needReply: toggleNeedsReply(row)
        case .pin: togglePin(row)
        case .read: toggleRead(row)
        }
    }

    // MARK: Send — deferred, with an undo window (desktop `sendCompose`)

    /// How long a send waits in the toast before it commits. Same window
    /// as the toast itself, so Undo is available exactly while it shows.
    static let sendUndoWindow: Duration = .seconds(5)

    private struct PendingSend {
        let draft: SendDraft
        let accountId: String
        var task: Task<Void, Never>?
    }
    private var pendingSends: [UUID: PendingSend] = [:]

    /// The draft does not touch the outbox until the undo window runs out:
    /// the toast's Undo cancels it and reopens the composer prefilled, with
    /// no backend call to take back.
    func send(_ draft: SendDraft, from accountId: String) {
        var d = draft
        d.fromAccountId = accountId
        let id = UUID()
        pendingSends[id] = PendingSend(draft: d, accountId: accountId)
        pendingSends[id]?.task = Task { [weak self] in
            try? await Task.sleep(for: Self.sendUndoWindow)
            guard !Task.isCancelled else { return }
            await self?.commitSend(id)
        }
        let n = d.to.count + d.cc.count + d.bcc.count
        let first = d.to.first ?? d.cc.first ?? d.bcc.first ?? ""
        show("Sending · \(n == 1 ? "to \(first)" : "to \(n) recipients")") { [weak self] in
            // A send that already committed must not reopen the composer
            // (that is how duplicates get sent).
            guard let self, let pending = self.pendingSends.removeValue(forKey: id) else { return }
            pending.task?.cancel()
            Keyboard.dismiss()
            self.composeDraft = pending.draft
        }
    }

    private func commitSend(_ id: UUID) async {
        guard let pending = pendingSends.removeValue(forKey: id) else { return } // undone
        do {
            try await engine.perform(.send(pending.draft), accountId: pending.accountId)
            Haptics.success()
            show("Sent")
        } catch { show("Couldn't send: \(error.localizedDescription)") }
    }

    /// Leaving the app inside the undo window: commit now rather than risk
    /// iOS ending the process with the message never sent.
    func flushPendingSends() {
        for (id, pending) in pendingSends {
            pending.task?.cancel()
            Task { await commitSend(id) }
        }
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

    // MARK: AI summaries (desktop InboxList + ThreadView), shown in a sheet

    func summary(for group: RowGroup) -> GroupSummary? {
        guard let s = groupSummaries[group.title], s.cacheKey == group.summaryKey else { return nil }
        return s
    }

    func summarize(_ group: RowGroup) {
        let key = group.summaryKey
        let items = group.active.map { (from: $0.fromSummary, subject: $0.subject, snippet: $0.snippet) }
        guard !items.isEmpty else { return }
        groupSummaries[group.title] = GroupSummary(cacheKey: key, generating: true)
        Task {
            do {
                let text = try await engine.aiSummarizeGroup(items: items)
                groupSummaries[group.title] = GroupSummary(cacheKey: key, text: text)
            } catch {
                groupSummaries[group.title] = GroupSummary(cacheKey: key, error: error.localizedDescription)
            }
        }
    }

    /// The sparkle on a group header: generate if needed, then present.
    func openSummary(_ group: RowGroup) {
        if summary(for: group) == nil { summarize(group) }
        summarySheet = SummaryPresentation(id: group.title, title: group.title)
    }

    /// The top-right sparkle: one summary of everything the list shows
    /// right now (folder, account, label filter), active rows only.
    private var viewKey: String { "view:\(view.countKey):\(selectedAccountId ?? "all"):\(triageFilterId ?? "")" }

    private var viewTitle: String {
        var t = tab == .inbox ? folder.title : tab.title
        if let f = triageFilterId, let l = triageLabels.first(where: { $0.id == f }) { t += " · \(l.name)" }
        if let a = currentAccount { t += " · \(a.displayName)" }
        return t
    }

    func openViewSummary() {
        let rows = groupedRows.flatMap(\.active).prefix(40)
        let key = rows.map(\.id).joined(separator: ",")
        let storeKey = viewKey
        if groupSummaries[storeKey]?.cacheKey != key {
            let items = rows.map { (from: $0.fromSummary, subject: $0.subject, snippet: $0.snippet) }
            if items.isEmpty {
                groupSummaries[storeKey] = GroupSummary(cacheKey: key, text: "Nothing active here.")
            } else {
                groupSummaries[storeKey] = GroupSummary(cacheKey: key, generating: true)
                Task {
                    do {
                        let text = try await engine.aiSummarizeGroup(items: items)
                        groupSummaries[storeKey] = GroupSummary(cacheKey: key, text: text)
                    } catch {
                        groupSummaries[storeKey] = GroupSummary(cacheKey: key, error: error.localizedDescription)
                    }
                }
            }
        }
        summarySheet = SummaryPresentation(id: storeKey, title: viewTitle)
    }

    private func threadKey(_ row: ThreadRow) -> String { "thread:\(row.id)" }

    func threadSummary(_ row: ThreadRow, messages: [MessageItem]) -> GroupSummary? {
        let key = messages.map(\.id).joined(separator: ",")
        guard let s = groupSummaries[threadKey(row)], s.cacheKey == key else { return nil }
        return s
    }

    func summarizeThread(_ row: ThreadRow, messages: [MessageItem]) {
        guard !messages.isEmpty, threadSummary(row, messages: messages) == nil else { return }
        let key = messages.map(\.id).joined(separator: ",")
        let storeKey = threadKey(row)
        groupSummaries[storeKey] = GroupSummary(cacheKey: key, generating: true)
        let items = messages.map { (from: $0.isMine ? "Me" : $0.fromName, snippet: String(($0.bodyText ?? $0.snippet).prefix(1500))) }
        Task {
            do {
                let text = try await engine.aiSummarizeThread(subject: row.subject, items: items)
                groupSummaries[storeKey] = GroupSummary(cacheKey: key, text: text)
            } catch {
                groupSummaries[storeKey] = GroupSummary(cacheKey: key, error: error.localizedDescription)
            }
        }
    }

    func openThreadSummary(_ row: ThreadRow, messages: [MessageItem]) {
        summarizeThread(row, messages: messages)
        summarySheet = SummaryPresentation(id: threadKey(row), title: row.subject.isEmpty ? "(no subject)" : row.subject)
    }

    /// Auto-summarize: pre-generate so the sheet opens instantly. One group
    /// at a time, only ones not already cached for their content.
    private func runAutoSummaries() {
        if groupSummaries.values.contains(where: \.generating) { return }
        if let g = groupedRows.first(where: { !$0.active.isEmpty && summary(for: $0) == nil }) {
            summarize(g)
        }
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
            // A push registration covers every account: redo it for the new one.
            await push.accountsChanged()
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch let e as NSError where e.domain == "com.apple.AuthenticationServices.WebAuthenticationSession" && e.code == 1 {
            // The user closed the consent sheet.
        } catch {
            show("Couldn't connect: \(error.localizedDescription)")
        }
    }

    func updateAccount(_ account: MailAccount, displayName: String? = nil, color: AccountColor? = nil, signature: String? = nil) {
        do {
            try engine.updateAccount(id: account.id, displayName: displayName, color: color, signature: signature)
            reloadAccounts()
        } catch { show(error.localizedDescription) }
    }

    func removeAccount(_ account: MailAccount) async {
        do {
            try await engine.removeAccount(id: account.id)
            reloadAccounts()
            reload()
            push.refreshStatus()
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
