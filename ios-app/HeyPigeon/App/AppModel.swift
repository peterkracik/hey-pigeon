// Observable app state: the one object the views read. Owns the engine,
// the current view/account, the loaded rows, sync state, the synced
// preferences (engine-backed, like the desktop's), and the undo toast. All
// mutations go through here so optimistic UI + undo live in one place.

#if os(iOS)
import BackgroundTasks
#endif
import Foundation
import Observation
import SwiftUI

/// The bottom toast: a line of text and, for reversible actions, Undo.
/// Equal by id, so a new toast with the same text still re-shows.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var undo: (() -> Void)?
    /// How long it stays: five seconds, or a send's undo window.
    var duration: Duration = .seconds(5)
    /// A send's "Sending · Undo": it keeps its place for its whole window,
    /// and what is said meanwhile shows beside it (`AppModel.sideToast`).
    var holds = false
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

/// The model's brief on one bundle, cached against the bundle's mail.
struct BundleBriefState: Equatable {
    var cacheKey: String
    var brief: BundleBrief?
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

/// One section of the list (Pinned, Today, Overdue, …) with its rows.
struct RowGroup: Identifiable {
    let title: String
    let rows: [ThreadRow]
    let isPinned: Bool
    /// Bundles whose quiet mail folds into one row in this group
    /// (`AppModel.fold`), newest first. Their threads are not in `rows`.
    var folds: [BundleFold] = []
    var id: String { title }
    /// Rows worth summarizing: not done.
    var active: [ThreadRow] { rows.filter { !$0.isDone } }
    var summaryKey: String { title + "|" + active.map(\.id).joined(separator: ",") }
}

/// One folded inbox row: a bundle's mail that needs nothing from the user
/// (read, low priority, no flag), shown as "Lisbon trip · 3 updates"
/// (docs/bundles.md "Folded inbox rows"). Anything that asks for action
/// keeps its own row with the bundle chip.
struct BundleFold: Identifiable, Hashable {
    let bundle: BundleItem
    /// Newest first.
    let rows: [ThreadRow]
    var id: String { bundle.id }
    var newest: Date { rows.first?.lastMessageAt ?? .distantPast }
    /// "3 updates · Seat chosen, Your receipt" — the subjects, newest first.
    var summary: String {
        let subjects = rows.prefix(3).map { $0.subject.isEmpty ? "(no subject)" : $0.subject }
        return "\(rows.count) updates · " + subjects.joined(separator: ", ")
    }
}

/// What one reload asks the store for: the view, the account, every
/// account (the widgets' per-account counts) and how many rows: the pages
/// already on screen, one at least, so a reload keeps a scrolled list where
/// it is instead of cutting it back to the first page.
struct ListRequest: Equatable, Sendable {
    let view: MailView
    let accountId: String?
    let accountIds: [String]
    let limit: Int

    /// Whether `other` asks for the same list, however many rows.
    func sameList(as other: ListRequest) -> Bool {
        view == other.view && accountId == other.accountId
    }
}

/// Everything one reload reads from the store, read together off the main
/// actor (`MailEngine.readInBackground`) and landed as one change
/// (`AppModel.apply`): the rows, the folder counts, the bounded lists behind
/// the tab badges, and the counts the app badge and the widgets show.
struct ListSnapshot: Sendable {
    let request: ListRequest
    let bundles: [BundleItem]
    let rows: [ThreadRow]
    /// Unread per folder for the account shown (nil = unified).
    let counts: [String: Int]
    /// Unread per folder across accounts, and per account: the app badge
    /// and the widgets' per-account rows.
    let unifiedCounts: [String: Int]
    let countsByAccount: [String: [String: Int]]
    let scheduledAcrossAccounts: [ThreadRow]
    let needReplyAcrossAccounts: [ThreadRow]
    let draftsCount: Int
}

@MainActor
@Observable
final class AppModel {
    static let refreshTaskId = "app.heypigeon.refresh"
    static let pageSize = 50
    /// How long a change notice from the engine waits for the next one
    /// before the reload (`reloadSoon`).
    static let reloadPause: Duration = .milliseconds(50)
    /// How often the archive walk refreshes the counts while it runs.
    static let backfillRefreshInterval: TimeInterval = 3

    /// The one model of the process, for the UIKit delegate (AppDelegate)
    /// that has no SwiftUI environment to read it from.
    private(set) static var current: AppModel?

    let engine: MailEngine
    let oauth = OAuthCoordinator()
    /// "New mail (push)" — the optional relay (relay/README.md).
    let push: PushController

    private(set) var accounts: [MailAccount] = [] {
        didSet {
            let byId = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            if byId != accountsById { accountsById = byId }
        }
    }
    private(set) var accountStates: [String: AccountState] = [:]
    private(set) var labels: [MailLabelItem] = []
    private(set) var triageLabels: [TriageLabelItem] = [] {
        didSet {
            let names = Dictionary(triageLabels.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            if names != triageLabelNames { triageLabelNames = names }
        }
    }
    private(set) var counts: [String: Int] = [:]
    /// Changes still waiting to reach Gmail, as of the last reload.
    private(set) var queuedChanges = 0
    private(set) var aiConfigured = false
    /// Accounts, bundles and triage label names by id. Every row looks
    /// these up on each render, and each changes only when its source does
    /// (a fresh but equal array still fires its observers), so a reload that
    /// moved nothing redraws no row.
    private(set) var accountsById: [String: MailAccount] = [:]
    private(set) var bundlesById: [String: BundleItem] = [:]
    private(set) var triageLabelNames: [String: String] = [:]

    /// nil = unified across accounts (desktop's `0`).
    var selectedAccountId: String? { didSet { reloadUnlessHeld() } }
    /// Bottom bar selection.
    var tab: MainTab = .inbox {
        didSet {
            Keyboard.dismiss()
            // Into or out of the Search tab the list changes its source
            // (results or rows) without either having moved.
            if tab != oldValue { regroup() }
            reloadUnlessHeld()
        }
    }
    /// Folder/label the Inbox tab shows; the other tabs have fixed views.
    var folder: MailView = .inbox {
        didSet {
            triageFilterId = nil
            reloadUnlessHeld()
        }
    }
    /// Set while `navigate` changes the tab and the folder together, so the
    /// two didSets above do not reload twice.
    @ObservationIgnored private var holdReload = false

    private func reloadUnlessHeld() {
        if !holdReload { reloadForNavigation() }
    }

    /// Switch tab (and, for the Inbox tab, the folder) with one reload;
    /// assigning them one after the other reloaded the store twice.
    func navigate(to tab: MainTab, folder: MailView? = nil) {
        holdReload = true
        self.tab = tab
        if let folder, self.folder != folder { self.folder = folder }
        holdReload = false
        reloadForNavigation()
    }
    /// Jev label the list is narrowed to (the bottom pill). nil = all.
    var triageFilterId: String? {
        didSet {
            regroup()
            // The filter only sees the rows loaded: with few matches among
            // them it read "All clear" over mail that was a page away.
            if triageFilterId != nil, tab == .inbox, hasMore, flatRowIds.count < Self.filterFill { appendNextPage() }
        }
    }

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
    private(set) var rows: [ThreadRow] = [] {
        didSet {
            listGeneration &+= 1
            regroup()
        }
    }
    private(set) var hasMore = true
    /// Bumped by every change to `rows`. A snapshot read off the main actor
    /// before the change (a row slid out, a page was appended, another view
    /// was loaded) is dropped instead of applied over it, and read again.
    @ObservationIgnored private(set) var listGeneration = 0
    /// The list the rows were read for (`listRequest` keeps its page count
    /// only while the view stays the same).
    @ObservationIgnored private var loadedRequest: ListRequest?
    @ObservationIgnored private var reloadRequested = false
    @ObservationIgnored private var reloadLoop: Task<Void, Never>?
    @ObservationIgnored private var lastBackfillRefresh = Date.distantPast
    private(set) var isSyncing = false
    /// The sync is worth showing: the user asked for it, or it has been
    /// running for longer than `syncActivityDelay`. The Mac syncs every 30
    /// seconds, and a spinner for each round made the toolbar twitch.
    private(set) var showsSyncActivity = false
    static let syncActivityDelay: Duration = .milliseconds(1200)
    /// A list nothing touched is still re-read this often (its "Today"
    /// group moves with the clock).
    static let idleReloadInterval: TimeInterval = 600
    /// When the last snapshot landed, and the reload count the reminders
    /// and the Spotlight index were last brought up to date at.
    @ObservationIgnored private var lastAppliedAt = Date.distantPast
    @ObservationIgnored private var postSyncReloadCount = -1
    private var isBackfillingOlder = false
    /// The background analysis pass (auto-triage): the inbox's progress bar,
    /// Settings › Triage and the Live Activity read it.
    private(set) var analysis = AnalysisProgress.idle
    private var isAnalyzing = false
    private(set) var lastSyncAt: Date?
    private(set) var hasLoadedOnce = false

    /// The core caps a search at this many threads (Search shows "50+").
    static let searchLimit = 50

    var searchText = "" {
        didSet { if searchText != oldValue { runSearch(after: Self.typingPause) } }
    }
    /// The Search tab's filter buttons, added to the typed words as operators.
    var searchFilters = SearchFilters() { didSet { runSearch() } }
    private(set) var searchResults: [ThreadRow] = [] { didSet { regroup() } }
    /// A typed search is on its way: the list keeps the previous results
    /// (or nothing) instead of flashing "No results".
    private(set) var isSearchPending = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// Keystrokes closer together than this make one query, not one each.
    static let typingPause: Duration = .milliseconds(150)
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty || !searchFilters.isEmpty }
    /// Whether the list shows the search results instead of the view. On
    /// iOS search is its own tab: the query stays there for when the user
    /// comes back, and Inbox, Scheduled and Need reply show their whole
    /// list (they used to show the search results). The Mac searches in
    /// the list it is on, so there any search replaces the list.
    var showsSearchResults: Bool {
        isSearching && (tab == .search || !Self.searchHasOwnTab)
    }
    #if os(iOS)
    nonisolated static let searchHasOwnTab = true
    #else
    nonisolated static let searchHasOwnTab = false
    #endif
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
    /// A toast shown beside a send's while that one holds its place
    /// (`Toast.holds`, `show`).
    var sideToast: Toast?
    var pendingRemind: ThreadRow?
    var composeDraft: SendDraft? {
        // A new draft starts where its platform puts it (the Mac: under
        // its thread), whatever the last one was pulled out to.
        didSet { if composeDraft?.draftKey != oldValue?.draftKey { composeDetached = false } }
    }
    /// The Mac writes a reply under its thread; true moves the open draft
    /// to the composer's sheet instead (the inline composer's window
    /// button). Reset with every new draft; the phone never sets it.
    var composeDetached = false
    var showSidebar = false
    var showSettings = false
    /// The Bundles list (a sheet on both platforms).
    var showBundles = false
    /// The bundle the sheet opens on (a folded inbox row was tapped).
    var bundlesStartId: String?
    /// "Add to bundle…" for this thread (AddToBundleSheet).
    var pendingBundlePick: ThreadRow?
    /// Every bundle, active first; re-read on each reload (counts move with
    /// the mail).
    private(set) var bundles: [BundleItem] = [] {
        didSet {
            let byId = Dictionary(bundles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            if byId != bundlesById { bundlesById = byId }
        }
    }
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
    /// Every scheduled thread across accounts as of the last reload. The
    /// 30-second tick, the icon badge and the widget snapshot read it
    /// instead of asking the store again: reminders come due with time,
    /// and every change to the list itself goes through `reload`.
    private(set) var scheduledAcrossAccounts: [ThreadRow] = []
    /// Every Need reply thread across accounts as of the last reload: the
    /// widgets' list; `needReplyCount` narrows it to the account shown.
    private(set) var needReplyAcrossAccounts: [ThreadRow] = []
    /// Unread per folder across accounts and per account, as of the last
    /// reload: the app badge, the reminder notifications and the widgets
    /// read these instead of asking the store again (they used to, on the
    /// main thread, after every reload). Observed, and assigned only when
    /// they moved: the Mac's toolbar tabs, its sidebar's account menu and
    /// the menu bar extra draw their unread numbers from them (they used
    /// to query the store inside a view body, which no reload redrew).
    private(set) var unifiedCounts: [String: Int] = [:]
    private(set) var countsByAccount: [String: [String: Int]] = [:]
    /// Unread in the unified inbox: the app badge's first half.
    var inboxUnreadAllAccounts: Int { unifiedCounts["inbox"] ?? 0 }
    /// Unread in one account's inbox, for the widgets' account rows.
    func inboxUnread(accountId: String) -> Int { countsByAccount[accountId]?["inbox"] ?? 0 }
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
    nonisolated static func due(_ threads: [ThreadRow], now: Date = Date()) -> [ThreadRow] {
        threads.filter { t in t.scheduledAt.map { $0 <= now } ?? false }
    }

    /// The rows of one account, or all of them for the unified view.
    nonisolated static func scoped(_ rows: [ThreadRow], to accountId: String?) -> [ThreadRow] {
        guard let accountId else { return rows }
        return rows.filter { $0.accountId == accountId }
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
        /// Settings › AI › "Suggest for new mail" (the core reads it too:
        /// crates/ffi/src/suggest.rs, unset = on).
        static let suggest = "ai.suggest"
        /// The labels pinned in the sidebar (both apps), by label id.
        static let pinnedLabels = "sidebar.pinned_labels"
        /// The bundles hidden from the sidebar (both apps), by bundle id.
        static let hiddenBundles = "sidebar.hidden_bundles"
        /// Settings › Inbox › "Load remote images" (off: ask per sender).
        static let remoteImages = "mail.remote_images"
        /// "Always load from this sender": lowercased addresses.
        static let imageSenders = "mail.image_senders"
        /// The triage labels in the user's order (ids), Settings › Triage.
        static let triageLabelOrder = "triage.label_order"
        /// Settings › Inbox › "Fold bundle updates" (unset = on).
        static let foldBundles = "bundles.fold_inbox"
        /// Settings › AI › "Make bundles" (the core reads it too:
        /// crates/ffi/src/bundles.rs, unset = on).
        static let autoBundles = "bundles.auto"
        /// The snippets, one JSON string (SnippetStore).
        static let snippets = "compose.snippets"
        /// How long a send waits for Undo, in seconds, as a string.
        static let sendUndo = "send.undo_seconds"
    }

    /// The user's order of the triage labels, by id. The core lists them
    /// alphabetically; this is laid over that list (`orderedTriageLabels`).
    /// Synced, so the bar shows the same order on every device.
    var triageLabelOrder: [String] = [] {
        didSet {
            savePref(PrefName.triageLabelOrder, triageLabelOrder)
            triageLabels = Self.orderedTriageLabels(triageLabels, by: triageLabelOrder)
        }
    }

    /// Settings › Triage's drag: the new order becomes the synced one.
    func moveTriageLabels(from source: IndexSet, to destination: Int) {
        var ids = triageLabels.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        triageLabelOrder = ids
    }

    /// Labels in `order` first, in that order; the rest (new ones, or ones
    /// another device added) after them in the core's order. Ids in the
    /// order that no longer exist are skipped.
    static func orderedTriageLabels(_ labels: [TriageLabelItem], by order: [String]) -> [TriageLabelItem] {
        guard !order.isEmpty else { return labels }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return labels.enumerated().sorted { a, b in
            switch (rank[a.element.id], rank[b.element.id]) {
            case let (x?, y?): x < y
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Senders whose web pictures always load. Synced, so the Mac and the
    /// phone trust the same senders; it used to be a per-device list.
    var imageSenders: Set<String> = [] {
        didSet { savePref(PrefName.imageSenders, imageSenders.sorted()) }
    }

    func alwaysLoadImages(from address: String) {
        imageSenders.insert(address.lowercased())
        Haptics.light()
    }

    /// Whether a message from this address shows its web pictures at once.
    func loadsImages(from address: String) -> Bool {
        loadRemoteImages || imageSenders.contains(address.lowercased())
    }

    /// The composer opens full screen instead of as a dialog (the phone: a
    /// full-screen cover; the Mac: the sheet fills the window). Its button
    /// switches it while writing; remembered per device, not synced: what
    /// fits a phone is not what fits a Mac.
    var composeFullScreen = UserDefaults.standard.bool(forKey: "composeFullScreen") {
        didSet { UserDefaults.standard.set(composeFullScreen, forKey: "composeFullScreen") }
    }

    /// Load every message's web pictures without the per-sender "Load".
    /// Off by default: a remote picture tells the sender the mail was opened.
    var loadRemoteImages = false {
        didSet { savePref(PrefName.remoteImages, loadRemoteImages) }
    }

    /// Labels pinned in the sidebar. With any pinned, the sidebar shows
    /// only those (and the open one) until ••• expands the whole list.
    /// Synced, like the other prefs: the Mac and the phone pin the same.
    var pinnedLabelIds: Set<String> = [] {
        didSet { savePref(PrefName.pinnedLabels, pinnedLabelIds.sorted()) }
    }

    /// Bundles the user hid from the sidebar's Bundles section. Synced, so
    /// the sidebar is the same on every device.
    var hiddenBundleIds: Set<String> = [] {
        didSet { savePref(PrefName.hiddenBundles, hiddenBundleIds.sorted()) }
    }

    func toggleHidden(_ bundle: BundleItem) {
        if hiddenBundleIds.contains(bundle.id) { hiddenBundleIds.remove(bundle.id) } else { hiddenBundleIds.insert(bundle.id) }
    }

    /// How many bundles the sidebar section shows before "N more".
    static let sidebarBundleLimit = 5

    /// The sidebar's Bundles section: active bundles, most recently active
    /// first. Folded, it leaves out the hidden ones and stops at `limit`;
    /// `more` is how many "N more" opens. Expanded, it lists every active
    /// bundle, hidden ones too, so they can be shown again.
    static func sidebarBundles(_ active: [BundleItem], hidden: Set<String>, expanded: Bool,
                               limit: Int = sidebarBundleLimit) -> (shown: [BundleItem], more: Int) {
        let recent = active.sorted { ($0.lastActivityAt ?? $0.createdAt) > ($1.lastActivityAt ?? $1.createdAt) }
        if expanded { return (recent, 0) }
        let shown = Array(recent.filter { !hidden.contains($0.id) }.prefix(limit))
        return (shown, recent.count - shown.count)
    }

    func togglePinned(_ label: MailLabelItem) {
        if pinnedLabelIds.contains(label.id) { pinnedLabelIds.remove(label.id) } else { pinnedLabelIds.insert(label.id) }
        Haptics.light()
    }

    /// The sidebar's label rows: everything when nothing is pinned or the
    /// list is expanded; otherwise the pinned ones and the label the list
    /// shows now (so the open one never disappears), in the given order.
    /// `hidden` is how many rows ••• would add.
    static func sidebarLabels(_ all: [MailLabelItem], pinned: Set<String>, expanded: Bool,
                              current: String?) -> (shown: [MailLabelItem], hidden: Int) {
        guard !expanded, all.contains(where: { pinned.contains($0.id) }) else { return (all, 0) }
        let shown = all.filter { pinned.contains($0.id) || $0.id == current }
        return (shown, all.count - shown.count)
    }

    /// The id of the label the list shows, if it shows one.
    var currentLabelId: String? {
        if case .label(let id, _) = view { return id }
        return nil
    }

    /// Group pinned messages at the top of the inbox.
    var pinListEnabled = true {
        didSet {
            savePref(PrefName.pinList, pinListEnabled)
            regroup()
        }
    }
    /// Fold a bundle's quiet mail (read, low priority, no flag) into one
    /// inbox row. iPhone and iPad; the Mac lists the rows with their chips.
    var foldBundlesEnabled = true {
        didSet {
            savePref(PrefName.foldBundles, foldBundlesEnabled)
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
    /// New unread mail gets an AI proposal: "Need reply" or "Remind me" on
    /// the date it names. The core runs it after each sync; off stops it.
    var suggestEnabled = true {
        didSet { savePref(PrefName.suggest, suggestEnabled) }
    }
    /// The model groups new mail into trip, shopping and project bundles.
    var autoBundlesEnabled = true {
        didSet { savePref(PrefName.autoBundles, autoBundlesEnabled) }
    }
    /// "Triage my inbox" only reports what it would do; nothing changes.
    var triageDryRun = false {
        didSet { savePref(PrefName.triageDryRun, triageDryRun) }
    }
    /// The user's own triage rules, in their words, put into the agent's
    /// instructions ("newsletters are done; anything from the bank is high").
    /// Typed into a text editor, so saved a moment after the last
    /// keystroke rather than on each one (every save is a synced write).
    var triageRules = "" {
        didSet { savePrefSoon(PrefName.triageRules, triageRules) }
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

    /// Free-text prefs waiting for `savePrefSoon`'s pause, by name.
    @ObservationIgnored private var pendingPrefs: [String: String] = [:]
    @ObservationIgnored private var pendingPrefsTask: Task<Void, Never>?
    static let prefSaveDelay: Duration = .milliseconds(700)

    /// Save once typing pauses; `flushPendingPrefs` saves at once.
    private func savePrefSoon(_ name: String, _ value: String) {
        guard !adoptingPrefs else { return }
        pendingPrefs[name] = value
        pendingPrefsTask?.cancel()
        pendingPrefsTask = Task { [weak self] in
            try? await Task.sleep(for: Self.prefSaveDelay)
            guard !Task.isCancelled else { return }
            self?.flushPendingPrefs()
        }
    }

    /// Write whatever is still waiting — before prefs are re-read (so a
    /// remote change cannot roll back what is being typed) and when the
    /// app goes to the background.
    func flushPendingPrefs() {
        pendingPrefsTask?.cancel()
        pendingPrefsTask = nil
        let pending = pendingPrefs
        pendingPrefs = [:]
        for (name, value) in pending { savePref(name, value) }
    }

    /// Read the synced prefs; a name the engine has never seen but
    /// UserDefaults has (a pre-sync install) is migrated in, once.
    private func loadPrefs() {
        flushPendingPrefs()
        var prefs = (try? engine.prefs()) ?? [:]
        let defaults = UserDefaults.standard
        let legacy: [(name: String, key: String, value: Any?)] = [
            (PrefName.pinList, "pinListEnabled", defaults.object(forKey: "pinListEnabled") as? Bool),
            (PrefName.autoSummarize, "autoSummarize", defaults.object(forKey: "autoSummarize") as? Bool),
            (PrefName.swipeActions, "swipeActions", defaults.stringArray(forKey: "swipeActions")),
            // The old per-device "Load" list, newline-separated.
            (PrefName.imageSenders, "allowedImageSenders",
             defaults.string(forKey: "allowedImageSenders")
                .map { $0.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
                .flatMap { $0.isEmpty ? nil : Array(Set($0)).sorted() }),
        ]
        for item in legacy where prefs[item.name] == nil {
            guard let value = item.value else { continue }
            guard (try? engine.setPref(item.name, value)) != nil else { continue }
            prefs[item.name] = value
            defaults.removeObject(forKey: item.key)
        }
        adoptingPrefs = true
        if let v = prefs[PrefName.pinList] as? Bool { pinListEnabled = v }
        if let v = prefs[PrefName.foldBundles] as? Bool { foldBundlesEnabled = v }
        if let v = prefs[PrefName.autoSummarize] as? Bool { autoSummarize = v }
        if let raw = prefs[PrefName.swipeActions] as? [String] {
            let actions = raw.compactMap(RowAction.init(rawValue:))
            if actions.count == 4 { swipeActions = actions }
        }
        if let v = prefs[PrefName.siriIndex] as? Bool { siriIndexEnabled = v }
        if let v = prefs[PrefName.triageDryRun] as? Bool { triageDryRun = v }
        if let v = prefs[PrefName.triageRules] as? String { triageRules = v }
        if let v = prefs[PrefName.suggest] as? Bool { suggestEnabled = v }
        if let v = prefs[PrefName.autoBundles] as? Bool { autoBundlesEnabled = v }
        if let v = prefs[PrefName.pinnedLabels] as? [String] { pinnedLabelIds = Set(v) }
        if let v = prefs[PrefName.hiddenBundles] as? [String] { hiddenBundleIds = Set(v) }
        if let v = prefs[PrefName.remoteImages] as? Bool { loadRemoteImages = v }
        if let v = prefs[PrefName.imageSenders] as? [String] { imageSenders = Set(v) }
        if let v = prefs[PrefName.triageLabelOrder] as? [String] { triageLabelOrder = v }
        if let v = prefs[PrefName.snippets] as? String { snippets = SnippetStore.decode(v) }
        if let v = (prefs[PrefName.sendUndo] as? String).flatMap(Int.init), Self.sendUndoChoices.contains(v) { sendUndoSeconds = v }
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
        engine.onThreadsUpdated = { [weak self] in self?.reloadSoon() }
        engine.onAccountDisconnected = { [weak self] id in
            self?.disconnectedAccountId = id
            self?.reloadAccounts()
        }
        engine.onPrefsUpdated = { [weak self] in self?.adoptRemoteSettings() }
        engine.onAnalysisProgress = { [weak self] p in self?.adoptAnalysis(p) }
        analysis = engine.analysisProgress()
        loadPrefs()
        reloadAccounts()
        reload()
        push.notify = { [weak self] text in self?.show(text) }
        AppModel.current = self
        // Donations are system state: not from the sample inbox or the tests.
        IntentDonations.enabled = !(engine is MockEngine)
        // What was scheduled to send before the last quit; the first tick
        // sends whatever came due meanwhile.
        if persistsScheduledSends { scheduledSends = ScheduledSendStore.load() }
        // The aliases as Gmail last gave them, until it answers again: a
        // reply started offline or right at launch knows them too.
        if persistsScheduledSends { sendAliases = Self.storedAliases() }
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
        sendDueScheduled()
        let before = dueCount
        dueCount = Self.due(Self.scoped(scheduledAcrossAccounts, to: selectedAccountId)).count
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

    /// The accounts, labels, triage labels and AI status: small reads, on
    /// the main actor, each assigned only when it moved (every row reads
    /// the accounts and the triage labels through `accountsById` and
    /// `triageLabelNames`).
    func reloadAccounts() {
        let fresh = (try? engine.accounts()) ?? []
        if fresh != accounts { accounts = fresh }
        accountStates = Dictionary(uniqueKeysWithValues: ((try? engine.accountStates()) ?? []).map { ($0.id, $0) })
        let labels = (try? engine.labels()) ?? []
        if labels != self.labels { self.labels = labels }
        let triage = Self.orderedTriageLabels((try? engine.triageLabels()) ?? [], by: triageLabelOrder)
        if triage != triageLabels { triageLabels = triage }
        let configured = (try? engine.aiStatus())?.configured ?? false
        if configured != aiConfigured { aiConfigured = configured }
        if let selected = selectedAccountId, !accounts.contains(where: { $0.id == selected }) {
            selectedAccountId = nil
        }
        if let f = triageFilterId, !triageLabels.contains(where: { $0.id == f }) {
            triageFilterId = nil
        }
        // Once per account and launch: a reply built before Gmail had
        // answered (the Mac's R, a banner's Reply, Siri) copied the user
        // on their own alias.
        loadSendAliases()
    }

    /// Re-read the current view, the counts and the bounded lists from the
    /// store now, on the main actor: for navigation and the user's own
    /// actions, whose result should be on screen when the call returns.
    /// The engine's change notices go through `reloadSoon` instead.
    func reload() {
        apply(Self.readList(MainActorStoreReader(engine: engine), listRequest))
    }

    /// A tab, folder or account switch: the new list's rows now, on the
    /// main actor, and the rest as the model last read it — the counts,
    /// the bundles and the cross-account lists do not change because the
    /// user looked elsewhere, and reading them cost a dozen store queries
    /// under the tap. A reload off the main actor follows for what did
    /// move meanwhile (and the drafts count of another account).
    private func reloadForNavigation() {
        guard hasLoadedOnce else { return reload() }
        let request = listRequest
        let rows = Self.unique((try? engine.threads(in: request.view, accountId: request.accountId, before: nil, limit: request.limit)) ?? [])
        let counts = request.accountId.map { id in countsByAccount[id] ?? ((try? engine.unreadCounts(accountId: id)) ?? [:]) } ?? unifiedCounts
        apply(ListSnapshot(request: request, bundles: bundles, rows: rows, counts: counts, unifiedCounts: unifiedCounts,
                           countsByAccount: countsByAccount, scheduledAcrossAccounts: scheduledAcrossAccounts,
                           needReplyAcrossAccounts: needReplyAcrossAccounts, draftsCount: draftsCount))
        reloadSoon()
    }

    /// A change notice from the engine: one reload a moment later, read off
    /// the main actor. A sync round notifies several times in a row (the
    /// delta, the bundle links, the triage, the proposals, the cross-device
    /// push), and each reload used to run a dozen store queries on the main
    /// thread, under the user's finger. Notices inside the pause share one
    /// reload, and at most one read is in flight.
    func reloadSoon() {
        reloadRequested = true
        guard reloadLoop == nil else { return }
        reloadLoop = Task { [weak self] in
            while let model = self, model.reloadRequested {
                try? await Task.sleep(for: Self.reloadPause)
                guard let live = self else { return }
                live.reloadRequested = false
                await live.reloadInBackground()
            }
            self?.reloadLoop = nil
        }
    }

    /// Wait until no reload is pending: the end of a sync (the list is
    /// current when the spinner goes), and the tests.
    func settleReloads() async {
        while let loop = reloadLoop { await loop.value }
    }

    private func reloadInBackground() async {
        let request = listRequest
        let generation = listGeneration
        guard let snapshot = try? await engine.readInBackground({ Self.readList($0, request) }) else { return }
        // The rows moved under the read (a swipe, a page, another view):
        // the snapshot predates them, so read again rather than apply it.
        guard generation == listGeneration else {
            reloadRequested = true
            return
        }
        apply(snapshot)
    }

    /// What a reload asks the store for now. The pages on screen, whole:
    /// 120 rows loaded asks for 150, and a full answer means there may be
    /// more, as with a page. Another view (or account) starts over at one.
    private var listRequest: ListRequest {
        let one = ListRequest(view: view, accountId: selectedAccountId, accountIds: accounts.map(\.id), limit: Self.pageSize)
        guard let loaded = loadedRequest, loaded.sameList(as: one) else { return one }
        let pages = max(1, (rows.count + Self.pageSize - 1) / Self.pageSize)
        return ListRequest(view: one.view, accountId: one.accountId, accountIds: one.accountIds, limit: pages * Self.pageSize)
    }

    /// The store's side of a reload, in one pass, from any thread. A read
    /// that fails leaves its part empty, as the separate reads used to.
    nonisolated static func readList(_ store: any StoreReader, _ request: ListRequest) -> ListSnapshot {
        let rows = unique((try? store.threads(in: request.view, accountId: request.accountId, before: nil, limit: request.limit)) ?? [])
        let unified = (try? store.unreadCounts(accountId: nil)) ?? [:]
        var byAccount: [String: [String: Int]] = [:]
        for id in request.accountIds { byAccount[id] = (try? store.unreadCounts(accountId: id)) ?? [:] }
        let counts: [String: Int]
        if let id = request.accountId {
            counts = byAccount[id] ?? ((try? store.unreadCounts(accountId: id)) ?? [:])
        } else {
            counts = unified
        }
        // Reminders and Need reply are bounded lists; drafts are capped like
        // the sidebar's other folders.
        return ListSnapshot(
            request: request,
            bundles: (try? store.bundles()) ?? [],
            rows: rows,
            counts: counts,
            unifiedCounts: unified,
            countsByAccount: byAccount,
            scheduledAcrossAccounts: (try? store.threads(in: .scheduled, accountId: nil, before: nil, limit: 500)) ?? [],
            needReplyAcrossAccounts: (try? store.threads(in: .needReply, accountId: nil, before: nil, limit: 500)) ?? [],
            draftsCount: (try? store.threads(in: .drafts, accountId: request.accountId, before: nil, limit: 500))?.count ?? 0
        )
    }

    /// Land one snapshot. Each property is assigned only when it moved: a
    /// fresh but equal array fires its observers all the same, and every
    /// row reads the bundles, so a reload that changed nothing used to
    /// redraw the whole list.
    private func apply(_ snapshot: ListSnapshot) {
        reloadCount &+= 1
        lastAppliedAt = Date()
        // The list moved on while this was read (a tab or folder switch
        // reloaded the new one on the main actor): nothing of this applies.
        guard snapshot.request.view == view, snapshot.request.accountId == selectedAccountId else { return }
        loadedRequest = snapshot.request
        // Before the rows: their regroup folds by bundle.
        let bundlesMoved = snapshot.bundles != bundles
        if bundlesMoved { bundles = snapshot.bundles }
        let more = snapshot.request.view.isPaged && snapshot.rows.count >= snapshot.request.limit
        if more != hasMore { hasMore = more }
        if snapshot.rows != rows { rows = snapshot.rows } else if bundlesMoved { regroup() }
        if snapshot.counts != counts { counts = snapshot.counts }
        if snapshot.unifiedCounts != unifiedCounts { unifiedCounts = snapshot.unifiedCounts }
        if snapshot.countsByAccount != countsByAccount { countsByAccount = snapshot.countsByAccount }
        if snapshot.scheduledAcrossAccounts != scheduledAcrossAccounts { scheduledAcrossAccounts = snapshot.scheduledAcrossAccounts }
        if snapshot.needReplyAcrossAccounts != needReplyAcrossAccounts { needReplyAcrossAccounts = snapshot.needReplyAcrossAccounts }
        let scheduled = Self.scoped(snapshot.scheduledAcrossAccounts, to: selectedAccountId)
        if scheduled.count != scheduledCount { scheduledCount = scheduled.count }
        let due = Self.due(scheduled).count
        if due != dueCount { dueCount = due }
        let needReply = Self.scoped(snapshot.needReplyAcrossAccounts, to: selectedAccountId).count
        if needReply != needReplyCount { needReplyCount = needReply }
        if snapshot.draftsCount != draftsCount { draftsCount = snapshot.draftsCount }
        if !hasLoadedOnce { hasLoadedOnce = true }
        let queued = engine.pendingChanges()
        if queued != queuedChanges { queuedChanges = queued }
        refreshOpenThread()
        // Only while the results are on screen: on the phone the query
        // stays in the Search tab, and every reload used to search again
        // and regroup the inbox for it. Coming back to the tab reloads.
        if showsSearchResults { runSearch() }
        if autoSummarize && aiConfigured { runAutoSummaries() }
        refreshStoreSurfaces()
    }

    @ObservationIgnored private var storeSurfacesPending = false

    /// Anything that changes the list can change the icon badge (a read, a
    /// reminder set for later today, another device's edit) and what the
    /// widgets show. Done once per main-actor turn, from the counts and
    /// lists the reload just read: nothing is asked of the store again.
    private func refreshStoreSurfaces() {
        guard !storeSurfacesPending else { return }
        storeSurfacesPending = true
        Task { [weak self] in
            guard let self else { return }
            storeSurfacesPending = false
            await NewMailNotifier.refreshBadge(self)
            // A no-op when nothing the widgets show moved.
            WidgetSnapshotWriter.publish(self)
        }
    }

    /// A row came on screen: load the next page when it is the last one.
    /// The last one shown counts as well as the last one loaded: that one
    /// may be folded into a bundle or hidden by the label filter, its cell
    /// never appears, and the list used to end there.
    func loadMoreIfNeeded(current row: ThreadRow) {
        guard hasMore, !showsSearchResults, row.id == rows.last?.id || row.id == flatRowIds.last else { return }
        appendNextPage()
    }

    /// Pages one pull may read while none of them adds a row to the list
    /// on screen (all folded, or none with the label).
    static let pagesPerPull = 10
    /// Rows a label filter shows before it stops reading further back by
    /// itself.
    static let filterFill = 15

    /// The next page — and the ones after it while a page puts nothing new
    /// on screen: without a new row there is nothing whose appearing would
    /// ask for more.
    private func appendNextPage() {
        var pulls = 0
        repeat {
            let shown = flatRowIds.count
            appendOnePage()
            pulls += 1
            if flatRowIds.count > shown { return }
        } while hasMore && pulls < Self.pagesPerPull
    }

    /// The page after the last loaded row. The cursor is a timestamp, so a
    /// thread already on screen is dropped from the page rather than listed
    /// twice (see `rows`).
    private func appendOnePage() {
        guard view.isPaged, let last = rows.last else { hasMore = false; return }
        let page = (try? engine.threads(in: view, accountId: selectedAccountId, before: last.lastMessageAt, limit: Self.pageSize)) ?? []
        hasMore = page.count == Self.pageSize
        let loaded = Set(rows.map(\.id))
        let fresh = Self.unique(page.filter { !loaded.contains($0.id) })
        if !fresh.isEmpty { rows.append(contentsOf: fresh) }
    }

    /// The first occurrence of each thread id, order kept.
    nonisolated static func unique(_ rows: [ThreadRow]) -> [ThreadRow] {
        var seen = Set<String>()
        return rows.filter { seen.insert($0.id).inserted }
    }

    /// Filters alone are a plain filtered scan, newest first: answered at
    /// once. Typed words go through the ranked full-text search, which runs
    /// off the main thread (the first letter matched nearly every message
    /// and the keyboard stalled), after `pause`; the newest query wins.
    private func runSearch(after pause: Duration = .zero) {
        searchTask?.cancel()
        searchTask = nil
        guard isSearching else {
            if !searchResults.isEmpty { searchResults = [] }
            isSearchPending = false
            return
        }
        let query = (searchFilters.operators + [searchText]).joined(separator: " ")
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            landSearch(Self.unique((try? engine.search(query, limit: Self.searchLimit)) ?? []))
            isSearchPending = false
            return
        }
        isSearchPending = true
        searchTask = Task { [weak self] in
            if pause > .zero { try? await Task.sleep(for: pause) }
            guard !Task.isCancelled, let engine = self?.engine else { return }
            let rows = await engine.searchInBackground(query, limit: Self.searchLimit)
            guard !Task.isCancelled, let self else { return }
            landSearch(Self.unique(rows))
            isSearchPending = false
        }
    }

    /// Results are assigned only when they moved: equal ones still regroup
    /// the list and rebuild every row's highlight.
    private func landSearch(_ found: [ThreadRow]) {
        if found != searchResults { searchResults = found }
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
    /// Read off the main actor: 500 rows used to be read on it while the
    /// composer's sheet slid in.
    func searchPeople() async -> [PersonSuggestion] {
        let mine = Set(accounts.map { $0.email.lowercased() })
        let stored = try? await engine.readInBackground { try $0.threads(in: .all, accountId: nil, before: nil, limit: 500) }
        return Self.people(from: stored ?? rows, excluding: mine)
    }

    /// `searchPeople` without the store: senders of `rows` (newest first)
    /// minus `mine`, by how often they wrote, the most recent first on a tie.
    static func people(from rows: [ThreadRow], excluding mine: Set<String>) -> [PersonSuggestion] {
        struct Tally {
            let name: String
            let accountId: String
            /// Position of the newest row from this person: the tie-break.
            let firstSeen: Int
            var count = 1
        }
        var tallies: [String: Tally] = [:]
        for row in rows {
            let address = row.lastFromAddress.lowercased()
            guard !address.isEmpty, !mine.contains(address) else { continue }
            if tallies[address] != nil {
                tallies[address]?.count += 1
            } else {
                tallies[address] = Tally(name: row.leadSenderName ?? address, accountId: row.accountId, firstSeen: tallies.count)
            }
        }
        return tallies
            .sorted { a, b in a.value.count != b.value.count ? a.value.count > b.value.count : a.value.firstSeen < b.value.firstSeen }
            .map { PersonSuggestion(person: SearchPerson(name: $0.value.name, address: $0.key), accountId: $0.value.accountId) }
    }

    /// The desktop's groups exactly: Pinned (inbox, when enabled) · Today ·
    /// Last 7 days · Older; the Scheduled tab buckets by due date instead.
    /// Stored, not computed: rebuilt when the rows, the search results, the
    /// label filter or the pin setting change, instead of on every render
    /// of every view that reads it (the list, the empty state, the title).
    private(set) var groupedRows: [RowGroup] = []
    /// The list's thread ids in display order, and a counter bumped when
    /// that order changes. The Mac's cursor (j / k, auto-advance, ⇧-click)
    /// walks them: it used to flatten the groups again on every key press,
    /// and the list compared a fresh array of every id on every render.
    @ObservationIgnored private(set) var flatRowIds: [String] = []
    @ObservationIgnored private var flatRowIndex: [String: Int] = [:]
    private(set) var rowOrderRevision = 0

    /// Where a thread sits in the list on screen, nil when it is not in it.
    func listIndex(of id: String) -> Int? { flatRowIndex[id] }

    private func regroup() {
        groupedRows = Self.group(
            showsSearchResults ? searchResults : rows,
            view: view, searching: showsSearchResults,
            triageFilterId: tab == .inbox ? triageFilterId : nil,
            pinList: pinListEnabled,
            bundles: Self.foldsOnThisPlatform && foldBundlesEnabled ? bundles : []
        )
        let ids = groupedRows.flatMap { $0.rows.map(\.id) }
        guard ids != flatRowIds else { return }
        flatRowIds = ids
        flatRowIndex = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        rowOrderRevision &+= 1
    }

    /// The phone and the iPad fold; the Mac's list keeps one row per thread
    /// (its keyboard selection walks threads).
    static var foldsOnThisPlatform: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    /// Split the inbox's rows into bundle folds and the rest. A thread
    /// folds when it needs nothing from the user: read, not high or medium
    /// priority, no Need reply, no reminder, no open AI suggestion, not
    /// pinned, not a draft. A bundle folds only with two or more such
    /// threads — one alone keeps its row and chip.
    static func fold(_ rows: [ThreadRow], bundles: [BundleItem]) -> (folds: [BundleFold], rest: [ThreadRow]) {
        let known = Dictionary(uniqueKeysWithValues: bundles.map { ($0.id, $0) })
        func quiet(_ r: ThreadRow) -> Bool {
            guard let b = r.bundleId, known[b] != nil else { return false }
            return r.isRead && !r.needsReply && r.scheduledAt == nil && r.openSuggestion == nil
                && !r.isPinned && r.priority != .high && r.priority != .medium
                && !r.labels.contains("DRAFT")
        }
        var byBundle: [String: [ThreadRow]] = [:]
        for r in rows where quiet(r) { byBundle[r.bundleId ?? "", default: []].append(r) }
        let folded = byBundle.filter { $0.value.count >= 2 }
        let foldedIds = Set(folded.values.flatMap { $0.map(\.id) })
        let folds = folded.compactMap { entry -> BundleFold? in
            guard let b = known[entry.key] else { return nil }
            return BundleFold(bundle: b, rows: entry.value.sorted { $0.lastMessageAt > $1.lastMessageAt })
        }
        .sorted { $0.newest > $1.newest }
        return (folds, rows.filter { !foldedIds.contains($0.id) })
    }

    /// Pure grouping; the day boundaries are computed once for the list.
    static func group(_ rows: [ThreadRow], view: MailView, searching: Bool,
                      triageFilterId: String?, pinList: Bool, bundles: [BundleItem] = [],
                      now: Date = Date()) -> [RowGroup] {
        var source = rows
        if let f = triageFilterId, !searching {
            source = source.filter { $0.triageLabelIds.contains(f) }
        }
        // Folding only in the plain inbox: a search, a label filter or a
        // folder shows every thread it matches.
        var folds: [BundleFold] = []
        if view == .inbox && !searching && triageFilterId == nil && !bundles.isEmpty {
            let split = fold(source, bundles: bundles)
            folds = split.folds
            source = split.rest
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
        let groups = bucket(source, titles: ["Today", "Last 7 days", "Older"]) { day($0.lastMessageAt) }
        guard !folds.isEmpty else { return head + groups }
        // A fold sits at the top of the day group of its newest email.
        var foldsByTitle: [String: [BundleFold]] = [:]
        for f in folds { foldsByTitle[day(f.newest), default: []].append(f) }
        let rowsByTitle = Dictionary(uniqueKeysWithValues: groups.map { ($0.title, $0.rows) })
        return head + ["Today", "Last 7 days", "Older"].compactMap { t in
            let rows = rowsByTitle[t] ?? []
            let f = foldsByTitle[t] ?? []
            return rows.isEmpty && f.isEmpty ? nil : RowGroup(title: t, rows: rows, isPinned: false, folds: f)
        }
    }

    private static func bucket(_ rows: [ThreadRow], titles: [String], key: (ThreadRow) -> String) -> [RowGroup] {
        var groups: [String: [ThreadRow]] = [:]
        for r in rows { groups[key(r), default: []].append(r) }
        return titles.compactMap { t in groups[t].map { RowGroup(title: t, rows: $0, isPinned: false) } }
    }

    // MARK: Sync

    /// `manual`: the user asked (Check for Mail, the palette, the Dock):
    /// the spinner shows at once. A round the timer started shows it only
    /// once it has run for a moment (`showsSyncActivity`). `quiet`: the
    /// Mac's 30-second round, which leaves the list, the reminders and the
    /// index alone when the round brought nothing.
    func sync(manual: Bool = false, quiet: Bool = false) async {
        guard !isSyncing else {
            if manual { showsSyncActivity = true }
            return
        }
        isSyncing = true
        if manual { showsSyncActivity = true }
        let slow = Task { [weak self] in
            try? await Task.sleep(for: Self.syncActivityDelay)
            guard !Task.isCancelled, let self, self.isSyncing else { return }
            self.showsSyncActivity = true
        }
        defer {
            slow.cancel()
            isSyncing = false
            if showsSyncActivity { showsSyncActivity = false }
        }
        // Which models this device can run follows the network and the
        // Apple Intelligence switch; re-register before the round so the
        // triage at its end picks the right one.
        engine.refreshAIProviders()
        do {
            let changed = try await engine.syncAll()
            lastSyncAt = Date()
            reloadAccounts()
            // The round's change notices are already waiting (reloadSoon);
            // this joins them, so the list is current when the pull-to-
            // refresh spinner goes, and before the reminders and the index
            // read the counts. A quiet round that brought nothing (most of
            // the Mac's, every 30 seconds) asks for no reload of its own:
            // the engine's notices still reload when another device moved
            // something, and the list is re-read anyway once it is old
            // enough for its day groups to have moved.
            if !quiet || changed || Date().timeIntervalSince(lastAppliedAt) > Self.idleReloadInterval { reloadSoon() }
            await settleReloads()
            // The reminders and the index follow the store: a quiet round
            // has nothing to do when no reload landed since they were last
            // brought up to date (and the index has no backlog left).
            if !quiet || reloadCount != postSyncReloadCount || SpotlightIndexer.needsRefresh {
                await rescheduleReminders()
                // What Siri and Spotlight know follows the store, same
                // cadence as the reminder notifications.
                await SpotlightIndexer.refresh(self)
                postSyncReloadCount = reloadCount
            }
        } catch {
            show("Sync failed: \(error.localizedDescription)")
        }
        // The app icon badge is the unified unread count plus today's
        // reminders — with or without push. Awaited here so a background
        // refresh finishes it before the task is marked complete.
        await NewMailNotifier.refreshBadge(self)
        if AppLifecycle.isActive {
            Task { await backfillOlder() }
            // The sync's own round classified a batch; the rest of a large
            // pass goes on now instead of ten emails per sync. Read, not
            // `analysis`: the listener's hop may not have landed yet.
            if engine.analysisProgress().remaining > 0 { Task { await analyzePending() } }
        }
    }

    // MARK: Analysis

    /// Settings › Triage "Reanalyze all emails": every thread is classified
    /// again, starting now, with the progress on screen.
    func reanalyzeAllEmails() throws {
        try engine.reanalyzeTriage()
        Task { await analyzePending() }
    }

    /// Analysis rounds back to back while the app is in front, and for the
    /// short while iOS allows after the user leaves (`BackgroundGrace`) — so
    /// the Live Activity keeps moving in the Dynamic Island. Stops when the
    /// pass is done or a round makes no progress (it failed, triage is off,
    /// or the sync's own round holds the guard); the next sync resumes it.
    func analyzePending() async {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        let grace = BackgroundGrace("Analyze emails")
        defer {
            grace.end()
            isAnalyzing = false
        }
        var done = analysis.isActive ? analysis.done : -1
        while !grace.isExpired {
            let p = await engine.analyzePending()
            adoptAnalysis(p)
            if p.remaining == 0 || p.done == done { break }
            done = p.done
            // Breathing room for the UI and the sync between rounds.
            try? await Task.sleep(for: .milliseconds(400))
        }
        // Left in the background mid-pass: the Live Activity says it paused.
        if !AppLifecycle.isActive { AnalysisLiveActivityController.submit(engine.analysisProgress()) }
    }

    private func adoptAnalysis(_ p: AnalysisProgress) {
        if analysis != p { analysis = p }
        AnalysisLiveActivityController.submit(p)
    }

    /// Pulls mail older than the sync window into the local store, a page
    /// per account per step, while the app is in front. The engine
    /// checkpoints the walk, so it resumes on the next foreground sync and
    /// is a no-op once the whole archive is local.
    private func backfillOlder() async {
        guard !isBackfillingOlder else { return }
        isBackfillingOlder = true
        defer { isBackfillingOlder = false }
        while AppLifecycle.isActive {
            guard let more = try? await engine.backfillOlder() else { break }
            appendOlderRows()
            if !more { break }
            // Breathing room for the delta sync and the UI between pages.
            try? await Task.sleep(for: .milliseconds(300))
        }
        // Whatever the walk brought (old unread mail moves the counts), once
        // it is over or paused.
        reloadSoon()
    }

    /// Old mail lands below everything loaded, so a list that has not hit
    /// its end picks it up by scrolling; one that has gets the next page
    /// appended here instead of a reload that would jump the scroll. The
    /// counts and the bounded lists follow through a coalesced reload, a
    /// few seconds apart while the walk runs: each step used to recount
    /// every folder and hydrate three lists on the main thread. Scheduled
    /// and Need reply come back whole, so for them that reload is also
    /// what replaces the list (only when it changed, so the scroll stays
    /// put): a thread whose reminder synced in before its mail joins there.
    private func appendOlderRows() {
        if view.isPaged, !rows.isEmpty, !hasMore { appendNextPage() }
        let now = Date()
        guard now.timeIntervalSince(lastBackfillRefresh) >= Self.backfillRefreshInterval else { return }
        lastBackfillRefresh = now
        reloadSoon()
    }

    // MARK: Prefetch

    /// How many rows from the top of the inbox have their bodies brought
    /// in ahead of a click.
    static let prefetchDepth = 8
    /// Threads whose bodies were already asked for, with the message count
    /// they had then: a new message asks again.
    @ObservationIgnored private var prefetched: [String: Int] = [:]
    @ObservationIgnored private var prefetchQueue: [String] = []
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?

    /// Bring these threads' bodies into the store, one at a time, so that
    /// opening one shows the message at once instead of a spinner while
    /// Gmail answers. The engine fetches only what the store lacks; a
    /// thread already whole costs one local read. Not in Low Power Mode,
    /// and not on a metered path or in Low Data Mode (the phone on
    /// cellular fetches a thread when it is opened, as before).
    func prefetchBodies(_ rows: [ThreadRow]) {
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled, Connectivity.shared.allowsPrefetch else { return }
        for row in rows where prefetched[row.id] != row.messageCount {
            prefetched[row.id] = row.messageCount
            if !prefetchQueue.contains(row.id) { prefetchQueue.append(row.id) }
        }
        guard prefetchTask == nil, !prefetchQueue.isEmpty else { return }
        prefetchTask = Task { [weak self] in
            while let model = self, let id = model.prefetchQueue.first {
                model.prefetchQueue.removeFirst()
                _ = try? await model.engine.thread(id: id)
            }
            self?.prefetchTask = nil
        }
    }

    /// The top of the inbox, when that is the list on screen.
    func prefetchTopOfInbox() {
        guard view == .inbox, !isSearching else { return }
        prefetchBodies(Array(rows.prefix(Self.prefetchDepth)))
    }

    // MARK: Focus filter (Intents/FocusFilter.swift)

    private static let focusAccountKey = "focus.account"
    private static let focusPreviousKey = "focus.previousAccount"

    /// The account the Focus that is on narrows the app to; nil without
    /// one. Kept across launches: the system only says when it changes.
    private(set) var focusAccountId: String? = UserDefaults.standard.string(forKey: AppModel.focusAccountKey)

    /// A Focus with the filter turned on (an account) or off (nil): the
    /// list shows that account, and goes back to what it showed before
    /// when the Focus ends. An account that is gone is no filter.
    func applyFocus(accountId: String?) {
        let defaults = UserDefaults.standard
        let id = accountId.flatMap { id in accounts.contains { $0.id == id } ? id : nil }
        guard id != focusAccountId else { return }
        if let id {
            // Only the first Focus remembers: a second one on top of it
            // would remember the first one's account.
            if focusAccountId == nil { defaults.set(selectedAccountId ?? "", forKey: Self.focusPreviousKey) }
            focusAccountId = id
            defaults.set(id, forKey: Self.focusAccountKey)
            if selectedAccountId != id { selectedAccountId = id }
        } else {
            let previous = defaults.string(forKey: Self.focusPreviousKey).flatMap { $0.isEmpty ? nil : $0 }
            focusAccountId = nil
            defaults.removeObject(forKey: Self.focusAccountKey)
            defaults.removeObject(forKey: Self.focusPreviousKey)
            let back = previous.flatMap { p in accounts.contains { $0.id == p } ? p : nil }
            if selectedAccountId != back { selectedAccountId = back }
        }
    }

    /// Whether a new-mail banner for this thread fits the Focus that is on.
    func focusAllows(_ row: ThreadRow) -> Bool {
        focusAccountId == nil || row.accountId == focusAccountId
    }

    /// Deep link from a notification (reminder or new mail): the inbox tab
    /// pushes the thread when it sees `pendingThreadId`.
    func openThread(id: String) {
        // Sheets close, as for `show(_:)`: the thread used to open under them.
        showSidebar = false
        showSettings = false
        navigate(to: .inbox)
        pendingThreadId = id
    }

    /// Siri / a widget asked for a folder or tab: Scheduled and Need reply
    /// are tabs, everything else shows in the Inbox tab. Sheets close so
    /// the list is what the user sees.
    func show(_ view: MailView) {
        showSidebar = false
        showSettings = false
        switch view {
        case .scheduled: navigate(to: .scheduled)
        case .needReply: navigate(to: .needReply)
        default: navigate(to: .inbox, folder: view)
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
        var draft = SendDraft.reply(to: last, in: detail.thread, all: all, history: detail.transcript,
                                    mine: ownAddresses(of: detail.thread.accountId))
        if let body, !body.isEmpty { draft.bodyText = body }
        compose(draft)
    }

    /// Open the composer on a forward of the thread's latest message.
    func openForward(of row: ThreadRow) async throws {
        let detail = try await engine.thread(id: row.id)
        guard let detail, let last = detail.mail.last else { throw IntentError.noSuchThread }
        compose(await forwardDraft(of: last, in: detail.thread))
    }

    /// A forward of `m` with what the message carried: the account's
    /// signature over the quoted text and the message's files. A forward
    /// used to go out as bare text — the PDF it was forwarded for stayed
    /// behind. The files are fetched from Gmail first (a toast says so),
    /// up to the size one message may carry; pictures the body shows
    /// inline are part of the HTML, which a forward does not keep.
    func forwardDraft(of m: MessageItem, in thread: ThreadRow) async -> SendDraft {
        var draft = SendDraft.forward(of: m, in: thread, signature: account(for: thread)?.signature ?? "")
        #if os(macOS)
        // The Mac's editor holds html: the forwarded message keeps its
        // formatting under the signature and the header. The phone's
        // editor cannot, and forwards the text.
        if let html = m.bodyHTML, !html.isEmpty {
            let lead = String(draft.bodyText.dropLast((m.bodyText ?? m.snippet).count))
                .trimmingCharacters(in: .newlines)
            draft.bodyHTML = MacComposeEditor.html(fromText: "\n\n" + lead) + ComposerHTML.clean(html)
        }
        #endif
        guard thread.hasAttachment, let all = try? await engine.attachments(threadId: thread.id) else { return draft }
        let files = all.filter { $0.messageId == m.id && !InlineImages.isShownInline($0, in: m.bodyHTML) }
        guard !files.isEmpty else { return draft }
        let notice = show("Fetching \(files.count == 1 ? "the attachment" : "\(files.count) attachments")…", duration: .seconds(30))
        var total = 0
        var left = 0
        for file in files {
            guard let url = try? await engine.attachmentFile(file),
                  let data = await Task.detached(operation: { try? Data(contentsOf: url) }).value,
                  total + data.count <= MailLimits.maxAttachmentBytes else { left += 1; continue }
            total += data.count
            draft.attachments.append(DraftAttachment(filename: file.filename, mimeType: file.mimeType, size: data.count,
                                                     dataBase64: data.base64EncodedString()))
        }
        dismissToast(notice)
        if left > 0 { show(left == 1 ? "One attachment could not be added" : "\(left) attachments could not be added") }
        return draft
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

    /// The account a row belongs to, for the rows, the entities and the index.
    func account(for row: ThreadRow) -> MailAccount? {
        accountsById[row.accountId]
    }

    /// A Jev label's name, for the row chips; nil once the label is gone.
    func triageLabelName(_ id: String) -> String? {
        triageLabelNames[id]
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
        // Undo, like Mark done: a slip of the swipe used to mean a trip
        // to Trash.
        perform(.trash(threadId: row.id), on: row, toast: "Deleted") { [weak self] in
            self?.perform(.untrash(threadId: row.id), on: row)
            self?.restoreFlags(row)
        }
    }

    func toggleNeedsReply(_ row: ThreadRow) {
        Haptics.light()
        do {
            try engine.setNeedsReply(threadId: row.id, !row.needsReply)
            // Now, not on the engine's notice: the row leaves (or joins)
            // the list as the finger lifts.
            reload()
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
        await ReminderScheduler.reschedule(scheduledAcrossAccounts, unread: inboxUnreadAllAccounts)
    }

    /// Take the AI's proposal: the same flag or reminder the swipe sets,
    /// which also drops the proposal in the core.
    func acceptSuggestion(_ row: ThreadRow) {
        switch row.openSuggestion {
        case .needsReply:
            guard !row.needsReply else { return }
            toggleNeedsReply(row)
        case .remind(let at):
            // A proposal can outlive its date (the app was closed, the
            // email sat unread): ask for a time instead of setting a past one.
            if at > Date() { remind(row, at: at, onlyIfNoReply: false) } else { pendingRemind = row }
        case nil:
            return
        }
    }

    /// Drop the AI's proposal; the thread stays where it is.
    func dismissSuggestion(_ row: ThreadRow) {
        Haptics.light()
        do {
            try engine.dismissSuggestion(threadId: row.id)
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

    /// Report spam: the thread goes to Gmail's Spam (and trains its
    /// filter); Undo brings it back.
    func markSpam(_ row: ThreadRow) {
        Haptics.archive()
        perform(.markSpam(threadId: row.id, spam: true), on: row, toast: "Moved to Spam") { [weak self] in
            self?.perform(.markSpam(threadId: row.id, spam: false), on: row)
            self?.reloadSoon()
        }
    }

    /// "Not spam": out of Spam, back into the inbox.
    func markNotSpam(_ row: ThreadRow) {
        perform(.markSpam(threadId: row.id, spam: false), on: row, toast: "Moved to the inbox")
    }

    /// Out of Trash, back into the inbox.
    func untrash(_ row: ThreadRow) {
        perform(.untrash(threadId: row.id), on: row, toast: "Moved to the inbox")
    }

    // MARK: Gmail labels

    /// A new label in the account, then the list of labels again.
    @discardableResult
    func createLabel(named name: String, accountId: String) async -> MailLabelItem? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        do {
            let label = try await engine.createLabel(accountId: accountId, name: name)
            reloadAccounts()
            show("Label added · \(label.name)")
            return label
        } catch {
            show("Couldn't add the label: \(error.localizedDescription)")
            return nil
        }
    }

    func renameLabel(_ label: MailLabelItem, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != label.name else { return }
        do {
            try await engine.renameLabel(label, to: name)
            reloadAccounts()
            // The list on screen may be the label's own: it carries the name.
            if case .label(let id, _) = folder, id == label.id { folder = .label(id: id, name: name) }
        } catch { show("Couldn't rename the label: \(error.localizedDescription)") }
    }

    /// Delete the label in Gmail. Its mail stays where it is, without it.
    func deleteLabel(_ label: MailLabelItem) async {
        do {
            try await engine.deleteLabel(label)
            if pinnedLabelIds.contains(label.id) { pinnedLabelIds.remove(label.id) }
            if case .label(let id, _) = folder, id == label.id { navigate(to: .inbox, folder: .inbox) }
            reloadAccounts()
            reload()
            show("Label deleted · \(label.name)")
        } catch { show("Couldn't delete the label: \(error.localizedDescription)") }
    }

    // MARK: Gmail's own search

    /// Gmail is being asked for the search on screen.
    private(set) var isSearchingGmail = false

    /// The search on screen, asked of Gmail itself: mail older than what
    /// this device has downloaded is found too. What comes back joins the
    /// results (and the store), newest first.
    func searchGmail() async {
        guard isSearching, !isSearchingGmail else { return }
        let text = searchText.trimmingCharacters(in: .whitespaces)
        var parts: [String] = []
        if let from = searchFilters.from { parts.append("from:\(from.address)") }
        if let to = searchFilters.to { parts.append("to:\(to.address)") }
        if searchFilters.unreadOnly { parts.append("is:unread") }
        if !text.isEmpty { parts.append(text) }
        let query = parts.joined(separator: " ")
        guard !query.isEmpty else { return }
        isSearchingGmail = true
        defer { isSearchingGmail = false }
        do {
            let rows = try await engine.searchRemote(query, accountId: searchFilters.accountId, limit: Self.searchLimit)
            // The search moved on while Gmail answered: not these results.
            guard isSearching, searchText.trimmingCharacters(in: .whitespaces) == text else { return }
            let merged = Self.unique(searchResults + rows).sorted { $0.lastMessageAt > $1.lastMessageAt }
            if merged != searchResults { searchResults = merged }
            if rows.isEmpty { show("Gmail found nothing more") }
        } catch {
            show("Couldn't search Gmail: \(error.localizedDescription)")
        }
    }

    // MARK: Send-as addresses

    /// Each account's addresses to send from (its own first), once asked
    /// for: the composer's From menu lists them.
    private(set) var sendAliases: [String: [SendAlias]] = [:]
    @ObservationIgnored private var aliasesAsked: Set<String> = []

    /// An account's "Send mail as" addresses, lowercased: the user's own
    /// for a reply's recipients (SendDraft.reply). Empty until Gmail
    /// answered `loadSendAliases`.
    func ownAddresses(of accountId: String) -> Set<String> {
        Set((sendAliases[accountId] ?? []).map { $0.email.lowercased() })
    }

    private nonisolated static let aliasesKey = "sendAliases"

    private nonisolated static func storedAliases() -> [String: [SendAlias]] {
        guard let data = UserDefaults.standard.data(forKey: aliasesKey) else { return [:] }
        return (try? JSONDecoder().decode([String: [SendAlias]].self, from: data)) ?? [:]
    }

    private nonisolated static func store(_ aliases: [String: [SendAlias]]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(aliases), forKey: aliasesKey)
    }

    /// Ask Gmail for every account's aliases, once per launch.
    func loadSendAliases() {
        for account in accounts where !aliasesAsked.contains(account.id) {
            aliasesAsked.insert(account.id)
            Task {
                guard let list = try? await engine.sendAliases(accountId: account.id) else {
                    aliasesAsked.remove(account.id)
                    return
                }
                sendAliases[account.id] = list
                if persistsScheduledSends { Self.store(sendAliases) }
            }
        }
    }

    /// Manual Jev label edit — sticky until "Reanalyze all emails".
    func setTriageLabels(_ row: ThreadRow, _ ids: [String]) {
        do {
            try engine.setManualTriageLabels(threadId: row.id, ids: ids)
            reload()
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

    /// How long a send waits in the toast before it commits (Settings ›
    /// Compose; synced). The toast stays for the same time, so Undo is
    /// available exactly while it shows.
    var sendUndoSeconds = 5 {
        didSet { if sendUndoSeconds != oldValue { savePref(PrefName.sendUndo, String(sendUndoSeconds)) } }
    }
    static let sendUndoChoices = [5, 10, 20, 30]
    var sendUndoWindow: Duration { .seconds(sendUndoSeconds) }

    /// The user's snippets (Shared/Snippets.swift), synced as one pref.
    var snippets: [Snippet] = [] {
        didSet { if snippets != oldValue { savePref(PrefName.snippets, SnippetStore.encode(snippets)) } }
    }

    // MARK: Send later (Shared/ScheduledSends.swift)

    /// Messages waiting for their time on this device, soonest first.
    private(set) var scheduledSends: [ScheduledSend] = []
    /// The sample inbox and the tests keep nothing on disk.
    private var persistsScheduledSends: Bool { !(engine is MockEngine) }

    private func storeScheduledSends() {
        if persistsScheduledSends { ScheduledSendStore.save(scheduledSends) }
    }

    /// Send `draft` at `date` instead of now. It leaves the composer, is
    /// kept as a Gmail draft meanwhile, and the toast's Undo brings it
    /// back to the composer.
    func sendLater(_ draft: SendDraft, from accountId: String, at date: Date) {
        var d = draft
        d.fromAccountId = accountId
        d.draftSaved = true
        let item = ScheduledSend(id: d.draftKey, draft: d, accountId: accountId, at: date)
        scheduledSends.removeAll { $0.id == item.id }
        scheduledSends.append(item)
        scheduledSends.sort { $0.at < $1.at }
        storeScheduledSends()
        saveDraft(d, from: accountId)
        show("Will send \(Formatters.reminder(date))") { [weak self] in
            self?.cancelScheduledSend(item.id, reopen: true)
        }
    }

    /// Take a message off the list; `reopen` puts it back in the composer
    /// (its Gmail draft stays, as for any open draft).
    func cancelScheduledSend(_ id: String, reopen: Bool) {
        guard let index = scheduledSends.firstIndex(where: { $0.id == id }) else { return }
        let item = scheduledSends.remove(at: index)
        storeScheduledSends()
        if reopen {
            Keyboard.dismiss()
            composeDraft = item.draft
        }
    }

    /// Send what has come due: every half minute while the app runs, and
    /// once at launch for what came due while it did not. Off the list
    /// before the send starts, so a slow send is never started twice.
    func sendDueScheduled(now: Date = Date()) {
        let due = scheduledSends.filter { $0.at <= now }
        guard !due.isEmpty else { return }
        scheduledSends.removeAll { $0.at <= now }
        storeScheduledSends()
        for item in due {
            Task {
                do {
                    try await engine.perform(.send(item.draft), accountId: item.accountId)
                    show("Sent · \(item.draft.subject.isEmpty ? "(no subject)" : item.draft.subject)")
                    deleteDraft(item.draft.draftKey, from: item.accountId)
                } catch {
                    // Not queued again here: the engine's outbox keeps a
                    // send Gmail did not take and retries it, and a second
                    // copy could go out twice. The Gmail draft is still there.
                    show("Scheduled message not sent yet: \(error.localizedDescription)")
                }
            }
        }
    }

    private struct PendingSend {
        let draft: SendDraft
        let accountId: String
        var task: Task<Void, Never>?
        /// Its "Sending · Undo" toast, taken off when the send commits.
        var toastId: UUID?
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
            try? await Task.sleep(for: self?.sendUndoWindow ?? .seconds(5))
            guard !Task.isCancelled else { return }
            await self?.commitSend(id)
        }
        let n = d.to.count + d.cc.count + d.bcc.count
        let first = d.to.first ?? d.cc.first ?? d.bcc.first ?? ""
        pendingSends[id]?.toastId = show("Sending · \(n == 1 ? "to \(first)" : "to \(n) recipients")", duration: sendUndoWindow, holds: true) { [weak self] in
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
        if let shown = pending.toastId { dismissToast(shown) }
        do {
            try await engine.perform(.send(pending.draft), accountId: pending.accountId)
            Haptics.success()
            show("Sent")
            if pending.draft.draftSaved { deleteDraft(pending.draft.draftKey, from: pending.accountId) }
        } catch {
            // The engine keeps a send Gmail did not take in its outbox and
            // tries again on the next sync: say so, or the user sends it a
            // second time by hand.
            show("Not sent yet: \(error.localizedDescription)")
        }
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
            await syncDrafts(accountId)
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
            await syncDrafts(accountId)
        }
    }

    /// The composer's trash: the message is gone at once — its Gmail draft
    /// too, when one was saved (`savedFrom`) — and the toast's Undo opens
    /// the composer on it again, as an undone send does. It comes back
    /// unsaved, so closing the composer saves it anew. The trash sits
    /// beside Send and used to delete without a word.
    func discardDraft(_ draft: SendDraft, savedFrom accountId: String?) {
        if let accountId { deleteDraft(draft.draftKey, from: accountId) }
        let kept = Self.unsaved(draft)
        show("Draft discarded") { [weak self] in
            Keyboard.dismiss()
            self?.composeDraft = kept
        }
    }

    /// A draft deleted from under its thread: gone at once, and Undo saves
    /// it back as a Gmail draft (a save under a key Gmail no longer has
    /// creates the draft again: adapter-gmail `save_draft`). `draft` is
    /// the whole draft — recipients, body, attachments — which is why the
    /// thread reads it before it deletes.
    func discardSavedDraft(_ draft: SendDraft, from accountId: String) {
        deleteDraft(draft.draftKey, from: accountId)
        show("Draft deleted") { [weak self] in
            self?.saveDraft(draft, from: accountId)
        }
    }

    /// The draft as one no Gmail draft stands behind.
    static func unsaved(_ draft: SendDraft) -> SendDraft {
        var d = draft
        d.draftSaved = false
        return d
    }

    /// Pull a draft change into the store (Gmail's push only covers the
    /// inbox), then let the open thread reload. A draft saved again while
    /// this ran stays shown until its own sync.
    @ObservationIgnored private var isSyncingDrafts = false

    /// Only the draft's account is synced: closing a composer used to
    /// run a whole round over every account, reminders and index included.
    private func syncDrafts(_ accountId: String) async {
        // Its own flag, not `isSyncing`: with that one set, a Check for
        // Mail pressed meanwhile was dropped and left the Mac's spinner
        // on, and a pull to refresh did nothing. The engine itself keeps
        // two rounds for one account apart.
        while isSyncing || isSyncingDrafts { try? await Task.sleep(for: .milliseconds(250)) }
        let shown = unsyncedDrafts
        isSyncingDrafts = true
        _ = try? await engine.syncNow(accountId: accountId)
        isSyncingDrafts = false
        reloadSoon()
        await settleReloads()
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
        // Animated here, where the rows change: the list used to carry an
        // animation keyed on every row id, which re-laid every row out on
        // each reload.
        var leaves = false
        if view.archivesOut, case .archive = action { leaves = true }
        if case .trash = action { leaves = true }
        // To Spam from anywhere; out of Spam or Trash from that folder.
        if case .markSpam(_, let spam) = action, spam || view == .spam { leaves = true }
        if case .untrash = action, view == .trash { leaves = true }
        if leaves {
            // The one animation of note; with Reduce Motion the row just goes.
            withAnimation(Motion.animation(.easeOut(duration: 0.15))) { rows.removeAll { $0.id == row.id } }
        }
        Task {
            do {
                try await engine.perform(action, accountId: row.accountId)
            } catch {
                show("Couldn't apply: \(error.localizedDescription)")
                reload()
            }
        }
        // Dealt with here: its banner has nothing left to say.
        switch action {
        case .archive, .trash, .markRead(_, true), .markSpam(_, true): NewMailNotifier.clearDelivered(row.id)
        default: break
        }
        if let text { show(text, undo: undo) }
    }

    /// Show a toast; its id comes back for the caller that ends it early.
    /// While a send waits in its undo window the new toast goes beside
    /// it: "Marked done" used to replace "Sending · Undo", and the mail
    /// then went out with nothing left to stop it.
    @discardableResult
    func show(_ text: String, duration: Duration = .seconds(5), holds: Bool = false, undo: (() -> Void)? = nil) -> UUID {
        let next = Toast(text: text, undo: undo, duration: Self.toastDuration(duration, holds: holds, voiceOver: VoiceOver.isRunning),
                         holds: holds)
        if !holds, toast?.holds == true { sideToast = next } else { toast = next }
        if let undo { lastUndo = (undo, Date()) }
        // The toast appears far from VoiceOver's cursor and was never
        // spoken: an action's only confirmation, and its Undo, went by
        // unheard.
        VoiceOver.announce(undo == nil ? text : "\(text). Undo available.")
        return next.id
    }

    /// How long a toast stays with VoiceOver on: five seconds is gone
    /// before the cursor can reach its Undo.
    static let voiceOverToastDuration: Duration = .seconds(20)

    /// A toast's time on screen. A send's toast (`holds`) keeps its own:
    /// it shows exactly as long as the send can still be undone.
    static func toastDuration(_ asked: Duration, holds: Bool, voiceOver: Bool) -> Duration {
        voiceOver && !holds ? max(asked, voiceOverToastDuration) : asked
    }

    /// The toasts on screen, top to bottom.
    var toasts: [Toast] { [sideToast, toast].compactMap { $0 } }

    /// Take a toast off (its time is up, or its Undo ran), if it still shows.
    func dismissToast(_ id: UUID) {
        if toast?.id == id { toast = nil }
        if sideToast?.id == id { sideToast = nil }
    }

    /// The last action's Undo, kept after its toast has gone: the Mac's
    /// `z` and Edit › Undo run it for a while longer than the five seconds
    /// the toast shows.
    @ObservationIgnored private var lastUndo: (run: () -> Void, at: Date)?
    static let undoLifetime: TimeInterval = 120

    /// Whether `undoLast` has something to take back.
    var canUndoLast: Bool {
        guard let last = lastUndo else { return false }
        return Date().timeIntervalSince(last.at) < Self.undoLifetime
    }

    /// Take back the last action that offered an Undo. False when there
    /// is none (or it is too old to be what the user means).
    @discardableResult
    func undoLast() -> Bool {
        guard canUndoLast, let last = lastUndo else { return false }
        lastUndo = nil
        if toast?.undo != nil { toast = nil }
        last.run()
        return true
    }

    // MARK: Bundles (docs/bundles.md)

    /// Bumped by every reload that landed (`apply`): the bundle view re-reads
    /// its mail on it (a read flag or a star changes no bundle count).
    private(set) var reloadCount = 0

    /// The root presents the shared sheets (Remind me, Add to bundle, the
    /// composer, a summary) while the Bundles sheet is closed; the Bundles
    /// sheet presents them while it is open, so an action on an email in a
    /// bundle has somewhere to show. One SwiftUI view cannot present a sheet
    /// over another view's sheet.
    func modal<T>(_ keyPath: ReferenceWritableKeyPath<AppModel, T?>, inBundles: Bool) -> Binding<T?> {
        Binding(
            get: { self.showBundles == inBundles ? self[keyPath: keyPath] : nil },
            set: { self[keyPath: keyPath] = $0 }
        )
    }

    private(set) var bundleBriefs: [String: BundleBriefState] = [:]

    /// What the brief was made from: the bundle's threads, their message
    /// counts and whether each is done.
    static func briefKey(_ c: BundleContents) -> String {
        c.threads.map { "\($0.id):\($0.messageCount):\($0.isDone ? 1 : 0)" }.joined(separator: ",")
    }

    func brief(for c: BundleContents) -> BundleBriefState? {
        guard let s = bundleBriefs[c.bundle.id], s.cacheKey == Self.briefKey(c) else { return nil }
        return s
    }

    /// Whether opening a bundle asks for its brief by itself: only when the
    /// model is on this device, or the user turned on auto-summarize —
    /// the rule Settings › AI states for every summary.
    var briefsOnOpen: Bool {
        autoSummarize || ((try? engine.aiStatus())?.answersOnDevice ?? false)
    }

    func summarizeBundle(_ c: BundleContents) {
        guard aiConfigured, !c.threads.isEmpty else { return }
        let key = Self.briefKey(c)
        let id = c.bundle.id
        if bundleBriefs[id]?.generating == true { return }
        bundleBriefs[id] = BundleBriefState(cacheKey: key, generating: true)
        Task {
            do {
                let brief = try await engine.aiSummarizeBundle(id: id)
                bundleBriefs[id] = BundleBriefState(cacheKey: key, brief: brief)
            } catch {
                bundleBriefs[id] = BundleBriefState(cacheKey: key, error: error.localizedDescription)
            }
        }
    }

    /// The Bundles sheet, on the list or on one bundle.
    func openBundles(at id: String? = nil) {
        bundlesStartId = id
        showSidebar = false
        showBundles = true
    }

    func bundle(id: String?) -> BundleItem? {
        guard let id else { return nil }
        return bundlesById[id]
    }

    var activeBundles: [BundleItem] { bundles.filter { !$0.isArchived } }
    var archivedBundles: [BundleItem] { bundles.filter(\.isArchived) }

    func bundleContents(id: String) -> BundleContents? {
        try? engine.bundleContents(id: id)
    }

    /// The bundle the picker offers first: the one this thread shares a
    /// booking, order or tracking number with.
    func suggestedBundle(for row: ThreadRow) -> BundleItem? {
        bundle(id: try? engine.suggestedBundle(threadId: row.id))
    }

    /// "New bundle…" (from the picker: with that thread in it).
    @discardableResult
    func createBundle(name: String, category: BundleCategory, description: String, threadIds: [String] = []) -> BundleItem? {
        do {
            let b = try engine.createBundle(name: name, category: category, description: description, threadIds: threadIds)
            Haptics.light()
            reload()
            show(threadIds.isEmpty ? "Bundle created" : "Added to \(b.name)")
            return b
        } catch {
            show(error.localizedDescription)
            return nil
        }
    }

    func updateBundle(_ b: BundleItem, name: String, category: BundleCategory, description: String) {
        do {
            try engine.updateBundle(id: b.id, name: name, category: category, description: description)
            reload()
        } catch { show(error.localizedDescription) }
    }

    func setBundleArchived(_ b: BundleItem, _ archived: Bool) {
        do {
            try engine.setBundleArchived(id: b.id, archived)
            reload()
            show(archived ? "Bundle archived" : "Bundle reopened")
        } catch { show(error.localizedDescription) }
    }

    /// The mail stays where it is; only the grouping goes.
    func deleteBundle(_ b: BundleItem) {
        do {
            try engine.deleteBundle(id: b.id)
            reload()
            show("Bundle deleted")
        } catch { show(error.localizedDescription) }
    }

    func addToBundle(_ row: ThreadRow, bundleId: String) {
        do {
            let more = try engine.addToBundle(threadId: row.id, bundleId: bundleId)
            Haptics.light()
            reload()
            let name = bundle(id: bundleId)?.name ?? "bundle"
            show(more > 0 ? "Added to \(name) with \(more) related" : "Added to \(name)") { [weak self] in
                self?.removeFromBundle(row, quietly: true)
            }
        } catch { show(error.localizedDescription) }
    }

    /// The thread leaves its bundle for good: nothing automatic puts it back.
    func removeFromBundle(_ row: ThreadRow, quietly: Bool = false) {
        let from = bundle(id: row.bundleId)
        do {
            try engine.removeFromBundle(threadId: row.id)
            reload()
            guard !quietly, let from else { return }
            show("Removed from \(from.name)") { [weak self] in
                self?.addToBundle(row, bundleId: from.id)
            }
        } catch { show(error.localizedDescription) }
    }

    /// The folded row's swipe: every email in it done at once, one Undo.
    func markDone(_ fold: BundleFold) {
        Haptics.archive()
        let rows = fold.rows
        for row in rows { perform(.archive(threadId: row.id), on: row) }
        regroup()
        show(rows.count == 1 ? "Marked done" : "Marked \(rows.count) done") { [weak self] in
            for row in rows { self?.perform(.unarchive(threadId: row.id), on: row) }
        }
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

    /// How much of each message's text a thread summary sends (the sheet's
    /// footnote says so).
    static let threadSummaryCharsPerMessage = 1_500

    /// Summary-cache keys of open threads start with this; the sheet tells
    /// a thread summary (message text) from a list one (subject + preview).
    static let threadSummaryPrefix = "thread:"

    private func threadKey(_ row: ThreadRow) -> String { Self.threadSummaryPrefix + row.id }

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
        let items = messages.map { (from: $0.isMine ? "Me" : $0.fromName, snippet: String(($0.bodyText ?? $0.snippet).prefix(Self.threadSummaryCharsPerMessage))) }
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
            // Its addresses are not kept past it.
            sendAliases[account.id] = nil
            aliasesAsked.remove(account.id)
            if persistsScheduledSends { Self.store(sendAliases) }
            reloadAccounts()
            reload()
            push.refreshStatus()
            // Its threads leave Spotlight with it.
            await SpotlightIndexer.clear()
            await SpotlightIndexer.refresh(self)
        } catch { show(error.localizedDescription) }
    }

    // MARK: Background refresh (iOS; the Mac never suspends the app and
    // syncs on a timer while it runs — HeyPigeonMacApp)

    #if os(iOS)
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
    #endif
}
