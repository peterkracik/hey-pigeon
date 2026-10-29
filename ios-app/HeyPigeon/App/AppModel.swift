// Observable app state: the one object the views read. Owns the engine,
// the current view/account, the loaded rows, sync state, the synced
// preferences (engine-backed, like the desktop's), and the undo toast. All
// mutations go through here so optimistic UI + undo live in one place.

import BackgroundTasks
import Foundation
import Observation
import SwiftUI
import UIKit

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

/// The Ask sheet, optionally opened on a question.
struct AskPresentation: Identifiable, Equatable {
    let id = UUID()
    var question: String?
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
    var triageFilterId: String? { didSet { regroup() } }

    /// What the list currently shows, derived from tab + folder.
    var view: MailView {
        switch tab {
        case .inbox, .search: folder
        case .scheduled: .scheduled
        case .needReply: .needReply
        }
    }

    /// The loaded page(s) of the current view. Never holds a thread twice:
    /// SwiftUI's List aborts the process on duplicate row ids.
    private(set) var rows: [ThreadRow] = [] { didSet { regroup() } }
    private(set) var hasMore = true
    private(set) var isSyncing = false
    private var isBackfillingOlder = false
    private(set) var lastSyncAt: Date?
    private(set) var hasLoadedOnce = false

    var searchText = "" { didSet { runSearch() } }
    /// The Search tab's filter buttons, added to the typed words as operators.
    var searchFilters = SearchFilters() { didSet { runSearch() } }
    private(set) var searchResults: [ThreadRow] = [] { didSet { regroup() } }
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty || !searchFilters.isEmpty }
    /// The typed words (hand-typed operators left out), underlined in result rows.
    var searchTerms: [String] {
        searchText.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.contains(":") }
    }
    /// Search tab "Recent": newest first, on this device only.
    private(set) var recentSearches: [RecentSearch] = AppModel.loadRecentSearches() {
        didSet { AppModel.saveRecentSearches(recentSearches) }
    }

    /// The thread on screen, re-read from the store on every change so its
    /// header badges and triage bar follow each action. The lists can't
    /// serve it: an action can take it out of the list it was opened from
    /// (a reminder hides it from the inbox, clearing Need reply drops it
    /// from that tab), and the stale copy made the next toggle undo the last.
    private(set) var openThread: ThreadRow?

    var toast: Toast?
    var pendingRemind: ThreadRow?
    var composeDraft: SendDraft?
    var showSidebar = false
    var showSettings = false
    /// "Ask my inbox" (AskSheet); the string is a question to ask at once.
    var askSheet: AskPresentation?

    /// Scheduled / Need reply / Drafts totals for the sidebar, the tab
    /// badges and the list title, and the reminders whose time has passed
    /// (the Scheduled tab's badge; the app icon badge adds the unified
    /// count in NewMailNotifier.refreshBadge). Read from the store once per
    /// reload — as computed properties they hydrated up to 500 rows each
    /// on every render of the tab bar, the title and the sidebar.
    private(set) var scheduledCount = 0
    private(set) var needReplyCount = 0
    /// Drafts are read, so the unread map has none: the sidebar shows how many there are.
    private(set) var draftsCount = 0
    private(set) var dueCount = 0
    /// Ticks every 30 s while the app runs, so a reminder coming due raises
    /// `dueCount` and the icon badge without waiting for a reload (the
    /// desktop's `now` in App.svelte).
    @ObservationIgnored private var clock: Task<Void, Never>?

    /// Every scheduled thread still in the inbox (done mail has no
    /// reminder), one account or all.
    func scheduledThreads(accountId: String?) -> [ThreadRow] {
        (try? engine.threads(in: .scheduled, accountId: accountId, before: nil, limit: 500)) ?? []
    }

    /// Reminders that have come due (their time is now or past).
    static func due(_ threads: [ThreadRow], now: Date = Date()) -> [ThreadRow] {
        threads.filter { t in t.scheduledAt.map { $0 <= now } ?? false }
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
        /// Settings › Siri & Search › "Let Siri see your inbox".
        static let siriIndex = "siri_index"
        /// Settings › Triage › Siri triage: "Dry run" and the user's own rules.
        static let triageDryRun = "triage.dry_run"
        static let triageRules = "triage.rules"
    }

    /// Group pinned messages at the top of the inbox.
    var pinListEnabled = true {
        didSet {
            savePref(PrefName.pinList, pinListEnabled)
            regroup()
        }
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
    /// Keep the Spotlight index (subject · sender · preview, never a body)
    /// that Siri's personal context and Spotlight read. Off drains it.
    var siriIndexEnabled = true {
        didSet {
            savePref(PrefName.siriIndex, siriIndexEnabled)
            guard !adoptingPrefs, siriIndexEnabled != oldValue else { return }
            Task { [weak self] in
                guard let self else { return }
                if siriIndexEnabled { await SpotlightIndexer.refresh(self) } else { await SpotlightIndexer.clear() }
            }
        }
    }
    /// "Triage my inbox" only reports what it would do; nothing changes.
    var triageDryRun = false {
        didSet { savePref(PrefName.triageDryRun, triageDryRun) }
    }
    /// The user's own triage rules, in their words, put into the agent's
    /// instructions ("newsletters are done; anything from the bank is high").
    var triageRules = "" {
        didSet { savePref(PrefName.triageRules, triageRules) }
    }
    /// The triage run in progress or waiting for confirmation (TriageAgent).
    var triageAgent: TriageAgent?
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
        if let v = prefs[PrefName.siriIndex] as? Bool { siriIndexEnabled = v }
        if let v = prefs[PrefName.triageDryRun] as? Bool { triageDryRun = v }
        if let v = prefs[PrefName.triageRules] as? String { triageRules = v }
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
        // Donations are system state: not from the sample inbox or the tests.
        IntentDonations.enabled = !(engine is MockEngine)
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.tick()
            }
        }
    }

    /// A reminder just came due: recount so the Scheduled tab badge moves,
    /// and the icon badge adds it (the notification carries the same count
    /// for the asleep case).
    private func tick() {
        let before = dueCount
        dueCount = Self.due(scheduledThreads(accountId: selectedAccountId)).count
        if dueCount != before {
            Task {
                await NewMailNotifier.refreshBadge(self)
                // A reminder came due while the app is in front: the Live
                // Activity and the widgets show it now.
                await ReminderLiveActivityController.sync(self)
                WidgetSnapshotWriter.publish(self)
            }
        }
    }

    /// A widget's or the Live Activity's "1 h": the reminder moves ahead,
    /// keeping its follow-up nature.
    func snooze(threadId: String, hours: Int) {
        guard let row = try? engine.threadRow(id: threadId) else { return }
        remind(row, at: Date().addingTimeInterval(Double(max(1, hours)) * 3600), onlyIfNoReply: row.isFollowUp)
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
        let page = (try? engine.threads(in: view, accountId: selectedAccountId, before: nil, limit: Self.pageSize)) ?? []
        rows = Self.unique(page)
        hasMore = view.isPaged && page.count == Self.pageSize
        counts = (try? engine.unreadCounts(accountId: selectedAccountId)) ?? [:]
        refreshCounts()
        hasLoadedOnce = true
        refreshOpenThread()
        if isSearching { runSearch() }
        if autoSummarize && aiConfigured { runAutoSummaries() }
        // Anything that changes the list can change the icon badge: a read,
        // a reminder set for later today, another device's edit.
        Task { await NewMailNotifier.refreshBadge(self) }
        // The widgets follow the store too (a no-op when nothing they show moved).
        WidgetSnapshotWriter.publish(self)
    }

    /// The sidebar / badge totals, from the store. Reminders and Need reply
    /// are bounded lists; drafts are capped like the sidebar's other folders.
    private func refreshCounts() {
        let scheduled = scheduledThreads(accountId: selectedAccountId)
        scheduledCount = scheduled.count
        dueCount = Self.due(scheduled).count
        needReplyCount = (try? engine.threads(in: .needReply, accountId: selectedAccountId, before: nil, limit: 500))?.count ?? 0
        draftsCount = (try? engine.threads(in: .drafts, accountId: selectedAccountId, before: nil, limit: 500))?.count ?? 0
    }

    func loadMoreIfNeeded(current row: ThreadRow) {
        guard hasMore, row.id == rows.last?.id else { return }
        appendNextPage()
    }

    /// The page after the last loaded row. The cursor is a timestamp, so a
    /// thread already on screen is dropped from the page rather than listed
    /// twice (see `rows`).
    private func appendNextPage() {
        guard view.isPaged, let last = rows.last else { hasMore = false; return }
        let page = (try? engine.threads(in: view, accountId: selectedAccountId, before: last.lastMessageAt, limit: Self.pageSize)) ?? []
        hasMore = page.count == Self.pageSize
        let loaded = Set(rows.map(\.id))
        let fresh = Self.unique(page.filter { !loaded.contains($0.id) })
        if !fresh.isEmpty { rows.append(contentsOf: fresh) }
    }

    /// The first occurrence of each thread id, order kept.
    static func unique(_ rows: [ThreadRow]) -> [ThreadRow] {
        var seen = Set<String>()
        return rows.filter { seen.insert($0.id).inserted }
    }

    private func runSearch() {
        guard isSearching else { searchResults = []; return }
        let query = (searchFilters.operators + [searchText]).joined(separator: " ")
        searchResults = Self.unique((try? engine.search(query, limit: 50)) ?? [])
    }

    // MARK: Search — recent searches and the From / To people

    private nonisolated static let recentSearchesKey = "recentSearches"
    private static let recentSearchesLimit = 6

    private nonisolated static func loadRecentSearches() -> [RecentSearch] {
        guard let data = UserDefaults.standard.data(forKey: recentSearchesKey) else { return [] }
        return (try? JSONDecoder().decode([RecentSearch].self, from: data)) ?? []
    }

    private nonisolated static func saveRecentSearches(_ list: [RecentSearch]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: recentSearchesKey)
    }

    /// Keep the current search in "Recent" (on submit, or when a result opens).
    func rememberSearch() {
        let entry = RecentSearch(text: searchText.trimmingCharacters(in: .whitespaces), filters: searchFilters)
        guard !entry.text.isEmpty || !entry.filters.isEmpty else { return }
        var list = recentSearches.filter { $0 != entry }
        list.insert(entry, at: 0)
        recentSearches = Array(list.prefix(Self.recentSearchesLimit))
    }

    func runRecentSearch(_ entry: RecentSearch) {
        searchFilters = entry.filters
        searchText = entry.text
    }

    func forgetSearch(_ entry: RecentSearch) {
        recentSearches.removeAll { $0 == entry }
    }

    func clearRecentSearches() {
        recentSearches = []
    }

    /// People for the From / To pickers: who the mail comes from, across
    /// every account, most frequent first (ties: most recent). The user's
    /// own addresses are left out. `accountId` is where they last wrote.
    func searchPeople() -> [PersonSuggestion] {
        let mine = Set(accounts.map { $0.email.lowercased() })
        let source = (try? engine.threads(in: .all, accountId: nil, before: nil, limit: 500)) ?? rows
        var order: [String] = []
        var seen: [String: (name: String, accountId: String, count: Int)] = [:]
        for row in source {
            let address = row.lastFromAddress.lowercased()
            guard !address.isEmpty, !mine.contains(address) else { continue }
            if var entry = seen[address] {
                entry.count += 1
                seen[address] = entry
            } else {
                // "Ana, Me (4)" → "Ana"; fall back to the address.
                let first = row.fromSummary.components(separatedBy: ",").first?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                let name = first.isEmpty || first == "Me" ? address : first
                seen[address] = (name: name, accountId: row.accountId, count: 1)
                order.append(address)
            }
        }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return order
            .sorted { a, b in
                let ca = seen[a]!.count, cb = seen[b]!.count
                return ca != cb ? ca > cb : rank[a]! < rank[b]!
            }
            .map { address in
                let entry = seen[address]!
                return PersonSuggestion(person: SearchPerson(name: entry.name, address: address), accountId: entry.accountId)
            }
    }

    /// The desktop's groups exactly: Pinned (inbox, when enabled) · Today ·
    /// Last 7 days · Older; the Scheduled tab buckets by due date instead.
    /// Stored, not computed: rebuilt when the rows, the search results, the
    /// label filter or the pin setting change, instead of on every render
    /// of every view that reads it (the list, the empty state, the title).
    private(set) var groupedRows: [RowGroup] = []

    private func regroup() {
        groupedRows = Self.group(
            isSearching ? searchResults : rows,
            view: view, searching: isSearching,
            triageFilterId: tab == .inbox ? triageFilterId : nil,
            pinList: pinListEnabled
        )
    }

    /// Pure grouping; the day boundaries are computed once for the list.
    static func group(_ rows: [ThreadRow], view: MailView, searching: Bool,
                      triageFilterId: String?, pinList: Bool, now: Date = Date()) -> [RowGroup] {
        var source = rows
        if let f = triageFilterId, !searching {
            source = source.filter { $0.triageLabelIds.contains(f) }
        }
        if view == .scheduled && !searching {
            let due = Formatters.dueGrouper(now: now)
            return bucket(source, titles: ["Overdue", "Today", "Tomorrow", "This week", "Later"]) {
                due($0.scheduledAt ?? $0.lastMessageAt)
            }
        }
        var head: [RowGroup] = []
        if pinList && view == .inbox && !searching {
            let pinned = source.filter(\.isPinned)
            if !pinned.isEmpty {
                head = [RowGroup(title: "Pinned", rows: pinned, isPinned: true)]
                source = source.filter { !$0.isPinned }
            }
        }
        let day = Formatters.dayGrouper(now: now)
        return head + bucket(source, titles: ["Today", "Last 7 days", "Older"]) { day($0.lastMessageAt) }
    }

    private static func bucket(_ rows: [ThreadRow], titles: [String], key: (ThreadRow) -> String) -> [RowGroup] {
        var groups: [String: [ThreadRow]] = [:]
        for r in rows { groups[key(r), default: []].append(r) }
        return titles.compactMap { t in groups[t].map { RowGroup(title: t, rows: $0, isPinned: false) } }
    }

    // MARK: Sync

    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        // Which models this device can run follows the network and the
        // Apple Intelligence switch; re-register before the round so the
        // triage at its end picks the right one.
        engine.refreshAIProviders()
        do {
            _ = try await engine.syncAll()
            lastSyncAt = Date()
            reloadAccounts()
            reload()
            await rescheduleReminders()
            // What Siri and Spotlight know follows the store, same cadence
            // as the reminder notifications.
            await SpotlightIndexer.refresh(self)
        } catch {
            show("Sync failed: \(error.localizedDescription)")
        }
        // The app icon badge is the unified unread count plus today's
        // reminders — with or without push. Awaited here so a background
        // refresh finishes it before the task is marked complete.
        await NewMailNotifier.refreshBadge(self)
        if UIApplication.shared.applicationState == .active {
            Task { await backfillOlder() }
        }
    }

    /// Pulls mail older than the sync window into the local store, a page
    /// per account per step, while the app is in front. The engine
    /// checkpoints the walk, so it resumes on the next foreground sync and
    /// is a no-op once the whole archive is local.
    private func backfillOlder() async {
        guard !isBackfillingOlder else { return }
        isBackfillingOlder = true
        defer { isBackfillingOlder = false }
        while UIApplication.shared.applicationState == .active {
            guard let more = try? await engine.backfillOlder() else { break }
            appendOlderRows()
            if !more { break }
            // Breathing room for the delta sync and the UI between pages.
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// Old mail lands below everything loaded, so a list that has not hit
    /// its end picks it up by scrolling; one that has gets the next page
    /// appended here instead of a reload that would jump the scroll.
    private func appendOlderRows() {
        guard !rows.isEmpty else { reload(); return }
        counts = (try? engine.unreadCounts(accountId: selectedAccountId)) ?? counts
        refreshCounts()
        if !view.isPaged {
            // Scheduled and Need reply come back whole, so there is no page
            // to append — appending re-listed every thread on each backfill
            // step, and the duplicate ids took the List down. A thread whose
            // reminder synced in before its mail joins here; the list is
            // replaced, and only when it changed, so the scroll stays put.
            let whole = Self.unique((try? engine.threads(in: view, accountId: selectedAccountId, before: nil, limit: Self.pageSize)) ?? rows)
            if whole != rows { rows = whole }
            return
        }
        guard !hasMore else { return }
        appendNextPage()
    }

    /// Deep link from a notification (reminder or new mail): the inbox tab
    /// pushes the thread when it sees `pendingThreadId`.
    func openThread(id: String) {
        tab = .inbox
        pendingThreadId = id
    }

    /// Siri / a widget asked for a folder or tab: Scheduled and Need reply
    /// are tabs, everything else shows in the Inbox tab. Sheets close so
    /// the list is what the user sees.
    func show(_ view: MailView) {
        showSidebar = false
        showSettings = false
        switch view {
        case .scheduled: tab = .scheduled
        case .needReply: tab = .needReply
        default:
            tab = .inbox
            if folder != view { folder = view }
        }
    }

    /// Open the composer on a draft (Compose intent, share extension).
    func compose(_ draft: SendDraft) {
        showSidebar = false
        showSettings = false
        composeDraft = draft
    }

    /// Open the composer on a reply to the thread's latest message, the
    /// thread view's own draft shape, with `body` as the text. Never sends.
    func openReply(to row: ThreadRow, all: Bool, body: String?) async throws {
        let detail = try await engine.thread(id: row.id)
        guard let detail, let last = detail.mail.last else { throw IntentError.noSuchThread }
        let transcript = detail.mail
            .map { "\($0.isMine ? "Me" : $0.fromName): \($0.bodyText ?? $0.snippet)" }
            .joined(separator: "\n\n")
        var draft = SendDraft.reply(to: last, in: detail.thread, all: all, history: transcript)
        if let body, !body.isEmpty { draft.bodyText = body }
        compose(draft)
    }

    /// Open the composer on a forward of the thread's latest message.
    func openForward(of row: ThreadRow) async throws {
        let detail = try await engine.thread(id: row.id)
        guard let detail, let last = detail.mail.last else { throw IntentError.noSuchThread }
        compose(SendDraft.forward(of: last, in: detail.thread))
    }

    /// Change the open composer's draft from outside it (Siri's "update
    /// draft"). The composer adopts the fields on the revision bump. False
    /// when no composer is open on that draft.
    @discardableResult
    func updateComposeDraft(key: String, _ change: (inout SendDraft) -> Void) -> Bool {
        guard var d = composeDraft, d.draftKey == key else { return false }
        change(&d)
        d.externalRevision += 1
        composeDraft = d
        return true
    }

    /// Siri's "send it" on the open composer: the composer closes and the
    /// draft goes through the same 5-second undo as the Send button.
    func sendComposeDraft(key: String) throws {
        guard let d = composeDraft, d.draftKey == key else { throw IntentError.draftGone }
        guard !(d.to.isEmpty && d.cc.isEmpty && d.bcc.isEmpty) else { throw IntentError.noRecipients }
        guard let from = d.fromAccountId ?? selectedAccountId ?? accounts.first?.id else { throw IntentError.noAccount }
        composeDraft = nil
        send(d, from: from)
    }

    /// Close the composer and delete its Gmail draft, if one was saved.
    func discardComposeDraft(key: String) -> Bool {
        guard let d = composeDraft, d.draftKey == key else { return false }
        if d.draftSaved, let from = d.fromAccountId { deleteDraft(d.draftKey, from: from) }
        composeDraft = nil
        return true
    }

    /// The Drafts folder as composer drafts, each read from Gmail (cached by
    /// the engine after the first time). Capped: this is for Siri picking a
    /// draft, not for listing them all.
    func gmailDrafts(accountId: String? = nil, limit: Int = 20) async -> [(row: ThreadRow, draft: SendDraft)] {
        let rows = (try? engine.threads(in: .drafts, accountId: accountId, before: nil, limit: limit)) ?? []
        var out: [(ThreadRow, SendDraft)] = []
        for row in rows {
            if let d = try? await engine.draft(threadId: row.id) { out.append((row, d)) }
        }
        return out
    }

    /// One Gmail draft by its key (the draft's message id) or its thread id.
    func gmailDraft(key: String) async -> (row: ThreadRow, draft: SendDraft)? {
        if let row = try? engine.threadRow(id: key), let d = try? await engine.draft(threadId: key) { return (row, d) }
        return await gmailDrafts(limit: 50).first { $0.draft.draftKey == key }
    }

    /// The account a row belongs to, for entities and the index.
    func account(for row: ThreadRow) -> MailAccount? {
        accounts.first { $0.id == row.accountId }
    }

    /// Resolve a pending deep link to a row, searching the loaded inbox
    /// first and the store second. Nil clears nothing — the screen decides.
    func row(forThreadId id: String) -> ThreadRow? {
        if let r = rows.first(where: { $0.id == id }) { return r }
        return try? engine.threadRow(id: id)
    }

    func showThread(_ row: ThreadRow) {
        if openThread?.id != row.id { openThread = row }
        refreshOpenThread()
    }

    func hideThread(_ row: ThreadRow) {
        if openThread?.id == row.id { openThread = nil }
    }

    private func refreshOpenThread() {
        guard let id = openThread?.id, let fresh = try? engine.threadRow(id: id) else { return }
        if fresh != openThread { openThread = fresh }
    }

    // MARK: Actions — the desktop's set, same names (optimistic; the
    // engine applies locally before returning)

    /// Desktop `e`: archive is "done".
    /// Done also ends the reminder and Need reply (the engine clears them);
    /// Undo puts them back.
    func markDone(_ row: ThreadRow) {
        Haptics.archive()
        perform(.archive(threadId: row.id), on: row, toast: "Marked done") { [weak self] in
            self?.perform(.unarchive(threadId: row.id), on: row)
            self?.restoreFlags(row)
        }
    }

    private func restoreFlags(_ row: ThreadRow) {
        do {
            if let at = row.scheduledAt {
                try engine.setReminder(threadId: row.id, at: at, onlyIfNoReply: row.isFollowUp)
            }
            if row.needsReply { try engine.setNeedsReply(threadId: row.id, true) }
        } catch { show(error.localizedDescription) }
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
            refreshOpenThread()
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
            // Hand it to iOS now, not at the next sync: a reminder set and
            // left alone until it is due would otherwise never fire.
            Task { await rescheduleReminders() }
        } catch { show(error.localizedDescription) }
    }

    /// The next 7 days of reminders, across accounts, as local notifications
    /// — after a reminder set here and after every sync (another device's).
    func rescheduleReminders() async {
        let unread = (try? engine.unreadCounts(accountId: nil))?["inbox"] ?? 0
        await ReminderScheduler.reschedule(scheduledThreads(accountId: nil), unread: unread)
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
        do {
            try engine.setManualTriageLabels(threadId: row.id, ids: ids)
            refreshOpenThread()
        } catch { show(error.localizedDescription) }
    }

    /// Swipe tiers and the Settings picker dispatch through here.
    func run(_ action: RowAction, on row: ThreadRow) {
        switch action {
        case .done:
            if !row.isDone { IntentDonations.archived(row, in: self) }
            toggleDone(row)
        case .delete:
            IntentDonations.deleted(row, in: self)
            delete(row)
        // A thread that already has a reminder: the swipe removes it.
        case .remind:
            if row.scheduledAt != nil { remind(row, at: nil, onlyIfNoReply: false) } else { pendingRemind = row }
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
            if pending.draft.draftSaved { deleteDraft(pending.draft.draftKey, from: pending.accountId) }
        } catch { show("Couldn't send: \(error.localizedDescription)") }
    }

    // MARK: Drafts — the composer's Gmail draft

    /// Reply drafts saved from the composer that the store has not synced
    /// back yet, by the thread they answer: the thread shows them at once.
    private(set) var unsyncedDrafts: [String: SendDraft] = [:]
    /// Bumped once saved or deleted drafts are in the store, so an open
    /// thread reloads and shows (or drops) them.
    private(set) var draftsRevision = 0

    /// Create or update the composer's Gmail draft (queued like any change),
    /// then sync it back so the thread and the Drafts folder show it.
    func saveDraft(_ draft: SendDraft, from accountId: String) {
        var d = draft
        d.fromAccountId = accountId
        d.draftSaved = true
        if let thread = d.replyToThreadId { unsyncedDrafts[thread] = d }
        Task {
            do { try await engine.perform(.saveDraft(d), accountId: accountId) }
            catch { show("Couldn't save draft: \(error.localizedDescription)") }
            await syncDrafts()
        }
    }

    /// A Drafts row opens in the composer, not the thread view. The draft
    /// is read from Gmail (full recipients, body, attachments).
    func openDraft(_ row: ThreadRow) {
        Task {
            do {
                if let d = try await engine.draft(threadId: row.id) { composeDraft = d }
                else { show("This draft is no longer there") }
            } catch {
                show("Couldn't open draft: \(error.localizedDescription)")
            }
        }
    }

    func deleteDraft(_ key: String, from accountId: String) {
        unsyncedDrafts = unsyncedDrafts.filter { $0.value.draftKey != key }
        Task {
            try? await engine.perform(.deleteDraft(key: key), accountId: accountId)
            await syncDrafts()
        }
    }

    /// Pull a draft change into the store (Gmail's push only covers the
    /// inbox), then let the open thread reload. A draft saved again while
    /// this ran stays shown until its own sync.
    private func syncDrafts() async {
        while isSyncing { try? await Task.sleep(for: .milliseconds(250)) }
        let shown = unsyncedDrafts
        await sync()
        for (thread, d) in shown where unsyncedDrafts[thread] == d { unsyncedDrafts[thread] = nil }
        draftsRevision += 1
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
            // Its threads leave Spotlight with it.
            await SpotlightIndexer.clear()
            await SpotlightIndexer.refresh(self)
        } catch { show(error.localizedDescription) }
    }

    // MARK: Background refresh

    /// iOS decides when this runs (a few times a day in practice). It is the
    /// only "push" the phone has in v1 — DESIGN.md's relay stays optional.
    ///
    /// The launch handler is written in this main-actor context, so Swift 6
    /// checks at run time that it runs on the main queue; with `using: nil`
    /// BGTaskScheduler calls it on its own queue and the check traps
    /// (_dispatch_assert_queue_fail, every background refresh). `.main`
    /// keeps the call where the closure says it is.
    static func registerBackgroundRefresh(_ model: AppModel) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskId, using: .main) { task in
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
