// The list screens behind the tab bar. The view's name sits between the
// glass circles on top (sidebar · AI), the list starts right under
// them, and the Jev label filter floats above the tab bar as a glass pill.
// Accounts live in the sidebar. One screen type serves Inbox, Scheduled and
// Need reply. Search has no screen of its own on the phone: a short pull
// down on a list (PullDown) opens it, and its field and results take the
// list's place (SearchPane, Features/Search).

import AppIntents
import SwiftUI

struct MailListScreen: View {
    let tab: MainTab
    @Environment(AppModel.self) private var model
    @State private var path: [ThreadRow] = []

    private var isActive: Bool { model.tab == tab }

    /// The search is up over this list: it was opened from here (pulled
    /// down, the sidebar's row, Spotlight), and the tab bar still shows
    /// this tab.
    private var searching: Bool { model.tab == .search && model.searchOrigin == tab }

    /// The model's words, for the field.
    private var searchText: Binding<String> {
        Binding(get: { model.searchText }, set: { model.searchText = $0 })
    }

    /// The field's side of `searching`. The system sets it when the field
    /// is tapped and when Cancel is; the model sets it for every other
    /// way in (`AppModel.tab`).
    private var searchPresented: Binding<Bool> {
        Binding(
            get: { searching },
            set: { on in
                if on {
                    if model.tab == tab { model.navigate(to: .search) }
                } else if searching {
                    model.closeSearch()
                }
            }
        )
    }

    /// What the top bar shows for the AI: nothing, one circle, or the
    /// sparkle menu holding both.
    enum AIBarItem: Equatable {
        case nothing, summarize, ask, menu
    }

    /// One door needs no menu around it.
    static func aiBarItem(summarize: Bool, ask: Bool) -> AIBarItem {
        switch (summarize, ask) {
        case (true, true): .menu
        case (true, false): .summarize
        case (false, true): .ask
        case (false, false): .nothing
        }
    }

    /// The label bar folded to the label in use, while the list is being
    /// read downwards. The list reports it (`ScrollCollapse`); a tap on the
    /// folded bar, a scroll back up or the top of the list opens it again.
    @State private var labelsCollapsed = false

    private var aiItem: AIBarItem {
        Self.aiBarItem(summarize: model.aiConfigured, ask: tab == .inbox && InboxAsk.isAvailable(model))
    }


    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if searching {
                    SearchPane(path: $path)
                        // The field exists only while the search is up:
                        // left on the list, the system showed it at the
                        // top of every list instead of hiding it.
                        .shownSearch(text: searchText, isPresented: searchPresented, prompt: "Search mail")
                        .onSubmit(of: .search) { model.rememberSearch() }
                } else {
                    mailList
                        // Pull to refresh on the list only. Applied after the bottom
                        // inset it reached the label bar's scroll view too: a slightly
                        // vertical swipe on the labels pulled the bar down with a spinner.
                        // Not on the search either: its results are local.
                        .refreshable { await model.sync() }
                }
            }
            // On a wide iPad the rows keep to a readable column.
            .readableColumn()
            // The paper (`listWash` draws flat in this look: the wash went
            // with the cards): behind the list, the skeleton and "All
            // clear" alike, in all three tabs.
            .background(Theme.listWash)
            // ListTitle is the principal item. No .toolbar(removing: .title)
            // here: the principal counts as the title and went with it.
            .navigationTitle(tab == .inbox ? model.folder.title : tab.title)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .barLeading) {
                    Button { model.showSidebar = true } label: { Image(systemName: "line.3.horizontal") }
                        .accessibilityLabel("Folders and accounts")
                }
                // The context the screen was missing: folder, unread count,
                // and which account — tap to switch account (desktop 0/1/2).
                // VoiceOver's way to the search from the list itself: the
                // pull that reveals the field is not a gesture it has.
                ToolbarItem(placement: .principal) {
                    ListTitle(tab: tab)
                        .accessibilityAction(named: "Search") { model.navigate(to: .search) }
                }
                // The AI's two doors — the view's summary and "Ask my
                // inbox" (on-device questions over the Spotlight index) —
                // behind one sparkle when both are there: with a circle
                // each the bar held five controls.
                if aiItem == .menu {
                    ToolbarItem(placement: .barTrailing) {
                        Menu {
                            Button { model.openViewSummary() } label: { Label("Summarize this view", systemImage: "sparkles") }
                            Button { model.askSheet = AskPresentation() } label: { Label("Ask my inbox", systemImage: "questionmark.bubble") }
                        } label: { Image(systemName: "sparkles") }
                        .accessibilityLabel("Summarize or ask")
                    }
                } else if aiItem == .summarize {
                    ToolbarItem(placement: .barTrailing) {
                        Button { model.openViewSummary() } label: { Image(systemName: "sparkles") }
                            .accessibilityLabel("Summarize this view")
                    }
                } else if aiItem == .ask {
                    ToolbarItem(placement: .barTrailing) {
                        Button { model.askSheet = AskPresentation() } label: { Image(systemName: "questionmark.bubble") }
                            .accessibilityLabel("Ask my inbox")
                    }
                }
                // Compose is not here: it is the circle beside the tab bar
                // (RootView.tabs), under the thumb.
            }
            .safeAreaInset(edge: .bottom) {
                // The labels narrow the inbox, not the search.
                if tab == .inbox && !searching {
                    VStack(spacing: 0) {
                        AnalysisProgressBar()
                        if !model.triageLabels.isEmpty {
                            TriageSplitBar(collapsed: labelsCollapsed) {
                                withAnimation(Motion.animation(.snappy)) { labelsCollapsed = false }
                            }
                        }
                    }
                    .animation(.snappy, value: model.analysis.isVisible)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { OfflineBar() }
            .navigationDestination(for: ThreadRow.self) { row in
                ThreadView(row: row) { path.removeLast() }
            }
            // Notification tap: the inbox tab opens the thread it names.
            .onChange(of: model.pendingThreadId, initial: true) { _, id in
                guard tab == .inbox, let id, let row = model.row(forThreadId: id) else { return }
                model.pendingThreadId = nil
                // Read, as a tap on its row makes it: opened from a banner,
                // a widget or Spotlight it used to stay bold and counted.
                model.markRead(row)
                path = [row]
            }
        }
    }
}

extension MailListScreen {
    /// The list of this tab: skeleton rows until the first load, the
    /// empty state, the rows — and nothing while another tab is shown.
    @ViewBuilder private var mailList: some View {
        if !model.hasLoadedOnce {
            SkeletonList()
        } else if isActive && model.listIsEmpty {
            EmptyState(view: model.view, searching: false, lastSyncAt: model.lastSyncAt, connect: model.connectFirstAccount)
        } else if isActive {
            ThreadList(path: $path, onCollapse: { collapsed in
                guard collapsed != labelsCollapsed else { return }
                withAnimation(Motion.animation(.snappy)) { labelsCollapsed = collapsed }
            }, onPull: {
                // A short pull down, let go: the search opens over this
                // list. Carried further it is the system's refresh.
                model.navigate(to: .search)
            })
        } else {
            Color.clear
        }
    }
}

/// A line over the list while there is no network: what is done meanwhile
/// is kept and sent when it is back, and the line says how much is waiting.
/// It is the one grey band in the list (`sunken`): a notice, not a row.
struct OfflineBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !Connectivity.shared.isOnline {
            Label {
                if model.queuedChanges > 0 {
                    Text("Offline · \(number(model.queuedChanges)) to send when it is back")
                } else {
                    Text("Offline")
                }
            } icon: {
                Image(systemName: "wifi.slash").font(Theme.glyph(.secondary, .medium))
            }
            .font(Theme.sans(.footnote, .medium))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Theme.sunken)
            .accessibilityLabel(model.queuedChanges > 0 ? "Offline. \(model.queuedChanges) changes to send." : "Offline")
        } else if model.failedChanges > 0 {
            // Something could not be sent for good: say so, and open the
            // Outbox. Silence left this device and Gmail disagreeing with
            // nobody the wiser. In the warning's colour as writing: an
            // error is said, not filled.
            Button { model.openOutbox() } label: {
                Label {
                    Text("\(number(model.failedChanges)) \(model.failedChanges == 1 ? "change was" : "changes were") not sent · Review")
                } icon: {
                    Image(systemName: "exclamationmark.triangle").font(Theme.glyph(.secondary, .medium))
                }
                .font(Theme.sans(.footnote, .medium))
                .foregroundStyle(Theme.warning)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Theme.sunken)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(model.failedChanges) \(model.failedChanges == 1 ? "change was" : "changes were") not sent")
            .accessibilityHint("Opens the Outbox")
        }
    }

    /// A number of changes to stand in the line's sentence: in the mono,
    /// as every count is.
    private func number(_ n: Int) -> Text {
        Text("\(n)").font(Theme.meta)
    }
}

/// Folder title + unread count in the top bar, with the account next to it
/// when there is more than one; then tapping opens the account switcher.
struct ListTitle: View {
    let tab: MainTab
    @Environment(AppModel.self) private var model

    private var title: String { tab == .inbox ? model.folder.title : tab.title }
    private var count: Int {
        switch tab {
        case .inbox: model.counts[model.folder.countKey] ?? 0
        case .scheduled: model.scheduledCount
        case .needReply: model.needReplyCount
        case .search: 0
        }
    }

    var body: some View {
        let spoken = Self.spoken(title: title, count: count, tab: tab)
        if model.accounts.count > 1 {
            Menu { accountMenu } label: { label }
                .accessibilityLabel("\(spoken). Switch account")
        } else {
            label.accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// The title for VoiceOver. The number beside it is unread mail in the
    /// inbox's folders, but reminders in Remind me and threads in Need
    /// reply: all three used to be read as "unread".
    static func spoken(title: String, count: Int, tab: MainTab) -> String {
        guard count > 0 else { return title }
        switch tab {
        case .scheduled: return "\(title), \(count) \(count == 1 ? "reminder" : "reminders")"
        case .needReply: return "\(title), \(count) waiting for a reply"
        case .inbox, .search: return "\(title), \(count) unread"
        }
    }

    @ViewBuilder private var accountMenu: some View {
        Button {
            model.selectedAccountId = nil
        } label: {
            Label("All accounts", systemImage: model.selectedAccountId == nil ? "checkmark" : "circle.grid.2x2")
        }
        ForEach(model.accounts) { a in
            Button {
                model.selectedAccountId = a.id
                Haptics.light()
            } label: {
                Label(a.displayName, systemImage: a.id == model.selectedAccountId ? "checkmark" : "circle.fill")
            }
        }
    }

    /// The name in the bold interface face, its count in the mono a step
    /// back, then the account: its dot (every account's, overlapping,
    /// for All) and its name. The dots are the state colours, which have
    /// a lighter pair for dark.
    private var label: some View {
        HStack(spacing: 7) {
            Text(title).font(Theme.display(18, relativeTo: .headline)).tracking(-0.18)
                .foregroundStyle(Theme.textPrimary)
            if count > 0 {
                Text("\(count)").font(Theme.mono(size: 13, weight: .medium, relativeTo: .footnote))
                    .foregroundStyle(Theme.textTertiary)
            }
            if model.accounts.count > 1 {
                if let a = model.currentAccount {
                    Circle().fill(Theme.state(a.color)).frame(width: 7, height: 7)
                    Text(a.displayName).font(Theme.sans(.subheadline, .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                } else {
                    HStack(spacing: -2) {
                        ForEach(model.accounts.prefix(3)) { a in
                            Circle().fill(Theme.state(a.color)).frame(width: 7, height: 7)
                        }
                    }
                    Text("All").font(Theme.sans(.subheadline, .medium)).foregroundStyle(Theme.textSecondary)
                }
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

/// Floating filter above the tab bar: the folder title (no filter), then
/// the Jev triage labels from Settings — the desktop's label tabs under the
/// folder title. Accounts switch in the sidebar.
///
/// On the phone it folds while the list scrolls down (`collapsed`): only
/// the label in use stays, as a pill at the leading edge, and a tap on it
/// opens the bar again (`expand`). The tab bar under it does not move.
struct TriageSplitBar: View {
    @Environment(AppModel.self) private var model
    /// Folded to the label in use. The iPad's columns and the Mac never fold.
    var collapsed = false
    /// Opens the folded bar.
    var expand: () -> Void = {}
    /// The open bar and the folded pill are one piece of glass
    /// (`glassEffectID`): it shrinks to the pill and grows back, as the
    /// tab bar did when it was the one that minimized. Two glass views
    /// swapped in an `if` only faded into each other.
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer {
            if collapsed { current } else { labels }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    /// Every label, scrolling sideways.
    private var labels: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                segment(nil, title: model.folder.title, count: model.counts[model.folder.countKey] ?? 0)
                ForEach(model.triageLabels) { l in
                    segment(l.id, title: l.name, count: 0)
                }
            }
            .padding(4)
        }
        // Sideways only. The bar sits in the list's bottom inset, over the
        // tab bar, and the scroll view took that safe area as content inset:
        // the labels slid down, were cut off and the bar scrolled up and down.
        .ignoresSafeArea(.container, edges: .vertical)
        .fixedSize(horizontal: false, vertical: true)
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .glassEffect(.regular, in: .capsule)
        .glassEffectID("bar", in: glass)
    }

    /// The label in use alone. As tall as the open bar, so the list's
    /// bottom inset does not change under a scroll in progress.
    private var current: some View {
        let id = model.triageFilterId
        let label = model.triageLabels.first { $0.id == id }
        let title = label?.name ?? model.folder.title
        let count = label == nil ? model.counts[model.folder.countKey] ?? 0 : 0
        return Button {
            expand()
            Haptics.light()
        } label: {
            segmentLabel(title: title, count: count, on: true).padding(4)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID("bar", in: glass)
        .accessibilityHint("Shows all labels")
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func segment(_ id: String?, title: String, count: Int) -> some View {
        let on = model.triageFilterId == id
        return Button {
            model.triageFilterId = id
            Haptics.light()
        } label: {
            segmentLabel(title: title, count: count, on: on)
        }
        .buttonStyle(.plain)
    }

    /// One label as it is drawn: its name, the count behind the folder's.
    /// The one in use is an ink capsule with the paper's colour for its
    /// words (selection is ink) and its count a step lighter; the others
    /// are plain words on the glass.
    private func segmentLabel(title: String, count: Int, on: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(Theme.text(.preview, on ? .semibold : .medium))
            if count > 0 {
                Text("\(count)").font(Theme.text(.meta, .medium))
                    .foregroundStyle(on ? Theme.onPrimary.opacity(0.75) : Theme.textTertiary)
            }
        }
        .foregroundStyle(on ? Theme.onPrimary : Theme.textSecondary)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(on ? Theme.textPrimary : Color.clear, in: Capsule())
    }
}

/// Whether a bar over a list is folded, from how the list scrolls: folded
/// after a scroll down, open again after a scroll up or at the top. Pure,
/// so the rule is tested without a view.
struct ScrollCollapse: Equatable {
    /// How far the list must move one way before the bar follows: a
    /// finger resting on the list, or a reload under it, moves less.
    static let threshold: CGFloat = 24

    private(set) var collapsed = false
    /// Where the current direction started: the highest offset while
    /// open, the lowest while folded.
    private var anchor: CGFloat = 0

    /// Takes the list's offset from its top, clamped to what it can
    /// scroll (`clamped`), and returns whether the bar is folded now.
    mutating func update(offset: CGFloat) -> Bool {
        if offset <= 0 {
            collapsed = false
            anchor = 0
        } else if collapsed {
            if offset > anchor { anchor = offset }
            else if anchor - offset > Self.threshold { collapsed = false; anchor = offset }
        } else {
            if offset < anchor { anchor = offset }
            else if offset - anchor > Self.threshold { collapsed = true; anchor = offset }
        }
        return collapsed
    }

    /// The offset without the rubber band at either end: the bounce back
    /// from the bottom is not a scroll up.
    static func clamped(offset: CGFloat, content: CGFloat, container: CGFloat) -> CGFloat {
        min(max(0, offset), max(0, content - container))
    }
}

/// Reports `ScrollCollapse` for the scroll view it is on. The body never
/// reads the tracker, so its change on every frame redraws nothing.
private struct ScrollCollapseReporter: ViewModifier {
    let action: ((Bool) -> Void)?
    @State private var tracker = ScrollCollapse()

    func body(content: Content) -> some View {
        if let action {
            content
                .onScrollGeometryChange(for: CGFloat.self) { g in
                    ScrollCollapse.clamped(
                        offset: g.contentOffset.y + g.contentInsets.top,
                        content: g.contentSize.height + g.contentInsets.top + g.contentInsets.bottom,
                        container: g.containerSize.height)
                } action: { _, offset in
                    let was = tracker.collapsed
                    if tracker.update(offset: offset) != was { action(!was) }
                }
                // The list went away folded (an empty label, another tab,
                // a thread pushed over it): with nothing to scroll back
                // up, the bar would have stayed folded.
                .onDisappear {
                    guard tracker.collapsed else { return }
                    tracker = ScrollCollapse()
                    action(false)
                }
        } else {
            content
        }
    }
}

/// A pull down on a list at its top, measured while the finger is on it:
/// a short one, let go, opens the search; a long one is the system's
/// pull to refresh and opens nothing. Pure, so the rule is tested
/// without a view.
struct PullDown: Equatable {
    /// Less than this is a finger resting on the list.
    static let shortest: CGFloat = 44
    /// From here on the pull is a refresh.
    static let longest: CGFloat = 110

    /// The furthest the list was pulled past its top in this drag.
    private(set) var peak: CGFloat = 0

    /// Takes how far the list is past its top (0 when it is not).
    mutating func update(overscroll: CGFloat) {
        if overscroll > peak { peak = overscroll }
    }

    /// The finger left the list: whether that pull opens the search.
    /// The next drag starts from nothing.
    mutating func released() -> Bool {
        defer { peak = 0 }
        return peak >= Self.shortest && peak < Self.longest
    }
}

/// Reports a `PullDown` on the scroll view it is on. As with
/// `ScrollCollapseReporter`, the body never reads the tracker.
private struct PullDownReporter: ViewModifier {
    let action: (() -> Void)?
    @State private var pull = PullDown()

    func body(content: Content) -> some View {
        if let action {
            content
                .onScrollGeometryChange(for: CGFloat.self) { g in
                    max(0, -(g.contentOffset.y + g.contentInsets.top))
                } action: { _, overscroll in
                    pull.update(overscroll: overscroll)
                }
                .onScrollPhaseChange { old, new in
                    // A drag begins: what the rubber band did before it
                    // (a bounce at the top) is not this pull.
                    if new == .interacting { pull = PullDown() }
                    if old == .interacting, new != .interacting, pull.released() { action() }
                }
        } else {
            content
        }
    }
}

/// The flat list with the gesture map and the desktop's day groups
/// (Pinned · Today · Last 7 days · Older; due buckets in Scheduled). Its
/// rows stand on the list's own paper, parted by a hairline; the last row
/// of a group has none, the next group's title follows it
/// (docs/specs/marker-look.md, R1, R2).
struct ThreadList: View {
    @Binding var path: [ThreadRow]
    @Environment(AppModel.self) private var model
    /// The thread open beside the list (the iPad's split layout): its row
    /// is tinted. Nil on the phone.
    @Environment(\.openThreadId) private var openThreadId
    /// Told when a bar over the list should fold or open (`ScrollCollapse`).
    /// Nil where nothing folds: search, the iPad's columns.
    var onCollapse: ((Bool) -> Void)?
    /// Told when the list was pulled down a little and let go
    /// (`PullDown`): the phone opens the search. Nil where the search has
    /// a place of its own.
    var onPull: (() -> Void)?

    var body: some View {
        List {
            // Parcels on their way, over everything else in the plain
            // inbox (docs/specs/parcel-card.md); empty anywhere else.
            if !model.inboxParcels.isEmpty {
                Section {
                    ParcelCardView()
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            ForEach(model.groupedRows) { group in
                Section {
                    ForEach(group.folds) { fold in foldCell(fold, ruled: !group.isLast(fold)) }
                    ForEach(group.rows) { row in cell(row, ruled: !group.isLast(row)) }
                } header: {
                    // As far in as the rows' own text, with air above:
                    // the title opens its group.
                    GroupHeader(group: group)
                        .listRowInsets(EdgeInsets(top: 18, leading: 16, bottom: 6, trailing: 16))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0, for: .scrollContent)
        .modifier(ScrollCollapseReporter(action: onCollapse))
        .modifier(PullDownReporter(action: onPull))
        .dismissKeyboardOnScroll()
        // The top of the inbox has its bodies fetched ahead, on Wi-Fi: a
        // tap then shows the message, not a spinner (AppModel.prefetchBodies).
        .onAppear { model.prefetchTopOfInbox() }
        .onChange(of: model.rowOrderRevision) { _, _ in model.prefetchTopOfInbox() }
        // No animation keyed on the rows here: the slide-out of a swiped
        // row is animated where the rows change (AppModel.perform). Keyed
        // on every row id, the animation re-laid the whole list out on
        // each reload, mid-scroll.
    }

    /// One row with its gestures, annotation and menu. Its own builder so
    /// the list body type-checks in reasonable time. `ruled`: the hairline
    /// under it, which every row but the last of its group has.
    private func cell(_ row: ThreadRow, ruled: Bool) -> some View {
        // The thread open beside the list (the iPad's columns) is tinted.
        RowSwipes.row(row, model: model, background: row.id == openThreadId ? Theme.rowOpen : Theme.card) {
            ThreadRowView(row: row, showAccountDot: model.selectedAccountId == nil,
                          highlight: model.tab == .search ? model.searchTerms : [])
                // 16 pt in from each edge and 12 above and below (the
                // row's own 2 included).
                .padding(.horizontal, 16).padding(.vertical, 10)
                // The rule is the row's: it slides with it under a swipe,
                // and the panel shows through where it was.
                .ruledBelow(ruled)
                .contentShape(Rectangle())
                .onTapGesture {
                    Keyboard.dismiss()
                    if model.view == .drafts { model.openDraft(row); return }
                    model.markRead(row)
                    path.append(row)
                }
        }
        // View Annotations (iOS 27): Siri sees this row as the
        // thread entity, so "mark these done", "remind me about
        // the second one" and "archive everything from Lufthansa
        // here" resolve against what is on screen.
        .siriEntity(MailThreadEntity.identifier(row.id))
        // No gap between rows and no separator of the list's: the rule
        // above is drawn 16 pt in at both ends, 1 pt, in the app's grey.
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .contextMenu { RowMenu(row: row) }
        .onAppear { model.loadMoreIfNeeded(current: row) }
    }

    /// A bundle's quiet mail as one row (AppModel.fold): tap opens the
    /// bundle, any swipe marks every email in it done — the done moment,
    /// so its panel is ink.
    private func foldCell(_ fold: BundleFold, ruled: Bool) -> some View {
        let done = SwipeAction(title: "Mark all done", systemImage: "checkmark", tint: Theme.textPrimary,
                               ink: Theme.onPrimary, marksDone: true) {
            model.markDone(fold)
        }
        return SwipeableRow(leading: [done, done], trailing: [done, done], background: Theme.card) {
            BundleFoldRow(fold: fold)
                // As a mail row: 12 above and below with the row's own 2.
                .padding(.horizontal, 16).padding(.vertical, 10)
                .ruledBelow(ruled)
                .contentShape(Rectangle())
                .onTapGesture {
                    Keyboard.dismiss()
                    model.openBundles(at: fold.bundle.id)
                }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .contextMenu {
            Button { model.openBundles(at: fold.bundle.id) } label: { Label("Open bundle", systemImage: "square.stack") }
            Button { model.markDone(fold) } label: { Label("Mark all done", systemImage: "checkmark") }
        }
    }
}

private extension RowGroup {
    /// The group's last row on screen is the one with no rule under it.
    /// Its folded bundles stand over its threads, so a fold is the last
    /// only in a group that has no thread of its own.
    func isLast(_ row: ThreadRow) -> Bool {
        row.id == rows.last?.id
    }

    func isLast(_ fold: BundleFold) -> Bool {
        rows.isEmpty && fold.id == folds.last?.id
    }
}

/// The swipe tiers from Settings as actions on one row: the inbox list and
/// the bundle view use the same ones. The words and the glyph are the
/// action's own (Shared/RowActionPresentation.swift), as on the Mac; the
/// panel's fill is too, but for the two this look draws in ink and grey
/// (`fill`).
enum RowSwipes {
    @MainActor
    static func action(_ action: RowAction, _ row: ThreadRow, model: AppModel) -> SwipeAction {
        SwipeAction(title: action.shortLabel(for: row), systemImage: action.glyph(for: row),
                    tint: fill(action), ink: ink(action),
                    // Not on a thread that is done already: there the
                    // same tier undoes it ("Not done").
                    marksDone: action == .done && !row.isDone) {
            model.run(action, on: row)
        }
    }

    /// The fill of an action's swipe panel. Mark done is ink: done is
    /// ink and a strike in this look, never pink
    /// (docs/specs/marker-look.md, R4, R10). Read / unread is the quiet
    /// grey. The others keep the action's own fill (`RowAction.tint`: a
    /// tag's colour, the same in both appearances).
    static func fill(_ action: RowAction) -> Color {
        switch action {
        case .done: Theme.textPrimary
        case .read: Theme.textTertiary
        default: action.tint
        }
    }

    /// The glyph and the word on that panel. Ink and the grey follow the
    /// appearance (they turn light on dark), so what is written on them
    /// is `onPrimary`; a tag's fill does not, and carries white.
    static func ink(_ action: RowAction) -> Color {
        switch action {
        case .done, .read: Theme.onPrimary
        default: Color.white
        }
    }

    /// A row behind the four swipe tiers from Settings, on the paper: the
    /// inbox's cell and the bundle's (they each spelled the tiers out).
    @MainActor
    static func row<Content: View>(_ row: ThreadRow, model: AppModel, background: Color = Theme.card,
                                   @ViewBuilder content: @escaping () -> Content) -> SwipeableRow<Content> {
        let tiers = model.swipeActions.map { action($0, row, model: model) }
        return SwipeableRow(leading: Array(tiers.prefix(2)), trailing: Array(tiers.dropFirst(2).prefix(2)),
                            background: background, content: content)
    }
}

extension View {
    /// The hairline under a row of a list (docs/specs/marker-look.md,
    /// R2), as far in as the row's own text. It is part of the row: it
    /// takes the row's background and moves with it under a swipe. The
    /// last row of a group has none (`ruled` false).
    func ruledBelow(_ ruled: Bool = true, inset: CGFloat = 16) -> some View {
        VStack(spacing: 0) {
            self
            if ruled { RowRule().padding(.horizontal, inset) }
        }
    }
}

/// A day group's title: its name in the small mono capitals of every
/// title, a rule filling the line and how many rows stand under it, all in
/// the light grey of structure (`SectionTitle`). Pinned is titled as any
/// other group. The AI summary of the whole view is the sparkle in the
/// top bar.
struct GroupHeader: View {
    let group: RowGroup

    var body: some View {
        // A folded bundle is one row, as it is on screen.
        SectionTitle(group.title, count: group.folds.count + group.rows.count)
            // One stop for VoiceOver ("Today, 3"), as the title alone was.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The full action set — the desktop command palette's row actions, on a
/// long press, in the desktop's words.
struct RowMenu: View {
    let row: ThreadRow
    @Environment(AppModel.self) private var model

    var body: some View {
        // The AI's proposal first: it is what the row is asking about.
        if let s = row.openSuggestion {
            Section("Suggested") {
                Button { model.acceptSuggestion(row) } label: { Label(s.title, systemImage: s.systemImage) }
                Button { model.dismissSuggestion(row) } label: { Label("Dismiss suggestion", systemImage: "xmark") }
            }
        }
        Button {
            if !row.isDone { IntentDonations.archived(row, in: model) }
            model.toggleDone(row)
        } label: {
            Label(RowAction.done.label(for: row), systemImage: RowAction.done.glyph(for: row))
        }
        Button { model.pendingRemind = row } label: {
            Label(RowAction.remindSheetLabel(for: row), systemImage: "clock")
        }
        Button { model.pendingBundlePick = row } label: {
            Label(row.bundleId == nil ? "Add to bundle…" : "Move to bundle…", systemImage: "square.stack")
        }
        if let b = model.bundle(id: row.bundleId) {
            // Teaches the model too: it never puts this email back, and sees
            // it as a "not this" example for the bundle.
            Button(role: .destructive) { model.removeFromBundle(row) } label: {
                Label("Not part of \(b.name)", systemImage: "minus.circle")
            }
        }
        Button { model.togglePin(row) } label: {
            Label(RowAction.pin.label(for: row), systemImage: RowAction.pin.glyph(for: row))
        }
        Button { model.toggleNeedsReply(row) } label: {
            Label(RowAction.needReply.label(for: row), systemImage: RowAction.needReply.glyph(for: row))
        }
        Button { model.toggleRead(row) } label: {
            Label(RowAction.read.label(for: row), systemImage: RowAction.read.glyph(for: row))
        }
        LabelMenuItems(row: row)
        if !model.triageLabels.isEmpty {
            Menu { TriageLabelToggles(row: row) } label: { Label("Jev labels", systemImage: "sparkles") }
        }
        Divider()
        FolderMoveItem(row: row)
        Button(role: .destructive) { IntentDonations.deleted(row, in: model); model.delete(row) } label: {
            Label(RowAction.delete.label(for: row), systemImage: RowAction.delete.glyph(for: row))
        }
    }
}

/// "Move to folder" and "Add label": the thread's account's own Gmail
/// labels, as two submenus (none when the account has no labels). The
/// long-press menu and the thread's More menu both show them; `afterMove`
/// runs once a move is asked for (the thread view closes).
struct LabelMenuItems: View {
    let row: ThreadRow
    var afterMove: () -> Void = {}
    @Environment(AppModel.self) private var model

    private var accountLabels: [MailLabelItem] {
        model.labels.filter { $0.accountId == row.accountId && !$0.id.hasPrefix("CATEGORY_") }
    }

    var body: some View {
        if !accountLabels.isEmpty {
            Menu {
                ForEach(accountLabels) { label in
                    Button {
                        IntentDonations.labeled(row, label, on: true, in: model)
                        model.move(row, to: label)
                        afterMove()
                    } label: { Label(label.name, systemImage: "tray") }
                }
            } label: { Label("Move to folder", systemImage: "folder") }
            Menu {
                ForEach(accountLabels) { label in
                    let on = row.labels.contains(label.id)
                    Button { IntentDonations.labeled(row, label, on: !on, in: model); model.setLabel(row, label, on: !on) } label: {
                        Label(on ? "Remove \(label.name)" : label.name, systemImage: on ? "checkmark" : "tag")
                    }
                }
            } label: { Label("Add label", systemImage: "tag") }
        }
    }
}

/// The triage (Jev) labels as a menu's items: a tap puts one on the
/// thread or takes it off (kept by hand until "Reanalyze all emails").
/// `offImage` is the symbol of a label that is not on.
struct TriageLabelToggles: View {
    let row: ThreadRow
    var offImage = "sparkles"
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(model.triageLabels) { label in
            let on = row.triageLabelIds.contains(label.id)
            Button {
                var ids = row.triageLabelIds
                if on { ids.removeAll { $0 == label.id } } else { ids.append(label.id) }
                model.setTriageLabels(row, ids)
            } label: { Label(label.name, systemImage: on ? "checkmark" : offImage) }
        }
    }
}

/// Report spam — or, in Spam and Trash, the way back to the inbox. One
/// menu item, by the folder on screen; `then` runs after it (the thread
/// view closes).
struct FolderMoveItem: View {
    let row: ThreadRow
    var then: () -> Void = {}
    @Environment(AppModel.self) private var model

    var body: some View {
        // The app's own rules (AppModel.mute, .block): Gmail's API has no
        // mute, and blocking there needs a permission the app does not ask.
        if model.isMuted(row) {
            Button { model.unmute(threadId: row.id) } label: { Label("Unmute", systemImage: "bell") }
        } else {
            Button { model.mute(row); then() } label: { Label("Mute", systemImage: "bell.slash") }
        }
        if let sender = model.blockableSender(of: row) {
            Button { model.block(sender: sender, row: row); then() } label: {
                Label("Block \(sender)", systemImage: "hand.raised.slash")
            }
        }
        switch model.view {
        case .spam:
            Button { model.markNotSpam(row); then() } label: { Label("Not spam", systemImage: "tray.and.arrow.down") }
        case .trash:
            Button { model.untrash(row); then() } label: { Label("Move to inbox", systemImage: "tray.and.arrow.down") }
        default:
            Button { model.markSpam(row); then() } label: { Label("Report spam", systemImage: "xmark.bin") }
        }
    }
}

/// The list before its first load: rows of placeholder bars, ruled as the
/// rows that will take their place are. Never a spinner in a list.
struct SkeletonList: View {
    /// How many placeholder rows: a phone's screenful.
    private static let rows = 8

    var body: some View {
        List {
            ForEach(0..<Self.rows, id: \.self) { index in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.separator).frame(width: 140, height: 12)
                    RoundedRectangle(cornerRadius: 4).fill(Theme.separator).frame(height: 10)
                    RoundedRectangle(cornerRadius: 4).fill(Theme.separator).frame(width: 220, height: 10)
                }
                // A mail row's measures: 16 pt in, 12 above and below,
                // the hairline under every row but the last.
                .padding(.horizontal, 16).padding(.vertical, 12)
                .ruledBelow(index < Self.rows - 1)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                // Clear, so the skeleton stands on what the list will (the
                // phone's paper, the Mac window's own), not on a fill of
                // its own over it.
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .redacted(reason: .placeholder)
    }
}

extension AppModel {
    /// With no account there is no mail to be clear of: an empty list
    /// offers the sign-in instead (`EmptyState`'s `connect`; later
    /// accounts are added in Settings). Nil once an account is connected.
    /// One closure for the phone's list, the iPad's list column and the
    /// Mac's window, which each had — or lacked — their own.
    var connectFirstAccount: (() -> Void)? {
        guard accounts.isEmpty else { return nil }
        return { [weak self] in
            Task { await self?.addAccount() }
        }
    }
}

/// The empty inbox is a designed moment, not a shrug. With no account
/// connected it is the way in instead: "All clear" over an inbox that is
/// not there was the first thing a new install said, and the sign-in was
/// two taps away in the sidebar.
struct EmptyState: View {
    let view: MailView
    let searching: Bool
    let lastSyncAt: Date?
    /// Starts the Google sign-in; set only while no account is connected.
    var connect: (() -> Void)? = nil

    var body: some View {
        if let connect, !searching {
            ContentUnavailableView {
                Title(title: "Connect your Gmail", systemImage: "bird")
            } description: {
                Self.sentence(Text("Sign in with Google to bring your mail to this \(Device.name)."))
            } actions: {
                // The screen's one ink action: an ink capsule with the
                // paper's colour for its words.
                Button(action: connect) {
                    Text("Add Google account")
                        .font(Theme.text(.bodySmall, .semibold))
                        .foregroundStyle(Theme.onPrimary)
                        .padding(.horizontal, 6)
                }
                .pillButton(prominent: true)
                .tint(Theme.textPrimary)
            }
        } else {
            ContentUnavailableView {
                Title(title: searching ? "No matches" : (view == .inbox ? "All clear" : "Nothing here"),
                      systemImage: searching ? "magnifyingglass" : "bird")
            } description: {
                if searching {
                    Self.sentence(Text("Try other words or remove a filter."))
                } else if let lastSyncAt {
                    // The time in the mono, as every time is.
                    Self.sentence(Text("Up to date as of \(Self.syncTime(lastSyncAt))."))
                } else {
                    Self.sentence(Text("Pull down to sync."))
                }
            }
        }
    }

    /// The sentence under the title: the interface face and the grey of
    /// what is read second, set on the text itself (the system would
    /// dress it in its own font and grey).
    private static func sentence(_ text: Text) -> some View {
        text.font(Theme.text(.bodySmall)).foregroundStyle(Theme.textSecondary)
    }

    /// The last sync's time, to stand in that sentence.
    private static func syncTime(_ date: Date) -> Text {
        Text(Formatters.rowTime(date)).font(Theme.mono(size: 14, relativeTo: .subheadline))
    }

    /// An empty state's title and symbol, as `ContentUnavailableView`
    /// takes them: the title in the display face, drawn a little tight,
    /// as a sheet's is; the symbol in ink at the size the system gives
    /// it (the one drawing on an otherwise empty page). Both are set on
    /// the text and the image themselves, where the system's own style
    /// cannot replace them.
    struct Title: View {
        let title: String
        let systemImage: String

        var body: some View {
            Label {
                Text(title).font(Theme.display(24, relativeTo: .title2)).tracking(-0.4)
                    .foregroundStyle(Theme.textPrimary)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(Theme.textPrimary)
            }
        }
    }
}
