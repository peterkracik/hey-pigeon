// The iPad at regular width: three columns instead of the phone's tab bar
// and stack — the sidebar's list (folders, accounts, labels, bundles; the
// sheet's own `SidebarList`), the thread list, and the open thread beside
// it (docs/porting-macos-ipados.md). The pieces are the phone's: the same
// ThreadList with its swipes and menus, the same title, pill, search and
// ThreadView. What is new is what a split needs — one open thread that is
// also the highlighted row (PadState), auto-advance when it leaves the
// list, and the hardware keyboard's letters (PadKeys).
//
// Search is a row of the sidebar here: the phone keeps it in the tab bar,
// and a split layout has none. Remind me and Need reply were sidebar rows
// already.
//
// Keys: the list column and the detail column are each focusable and hand
// their key presses to PadState. Neither holds a text field — the search
// field lives in the navigation bar, the composer in a sheet — so a letter
// typed into one never reaches the map; and the map stands down while any
// sheet is up.

#if os(iOS)
import SwiftUI

struct PadSplitView: View {
    @Environment(AppModel.self) private var model
    @State private var state = PadState()
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarList(isColumn: true)
                .navigationTitle("Hey Pigeon")
                .toolbarTitleDisplayMode(.inline)
        } content: {
            PadListColumn(state: state)
        } detail: {
            PadDetailColumn(state: state)
        }
        .navigationSplitViewStyle(.balanced)
        // The open thread's row left the list (done, a reminder, another
        // device): the next one opens. Another list closes it.
        .onChange(of: model.rowOrderRevision) { _, _ in state.rowsChanged(in: model) }
        // A notification, a widget or Spotlight asked for a thread.
        .onChange(of: model.pendingThreadId, initial: true) { _, id in
            guard let id, let row = model.row(forThreadId: id) else { return }
            model.pendingThreadId = nil
            model.markRead(row)
            state.open(row, in: model)
        }
    }
}

// MARK: - The list column

/// The thread list of the place shown (a folder, Remind me, Need reply) or
/// the search, with the keyboard.
private struct PadListColumn: View {
    @Bindable var state: PadState
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if model.tab == .search {
                PadSearchList(state: state)
            } else {
                PadMailList(state: state)
            }
        }
        .environment(\.openThreadId, state.openRow?.id)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in state.handle(press, in: model) }
        .onAppear { focused = true }
        .onChange(of: state.listFocusRequest) { _, _ in focused = true }
    }
}

private extension PadState {
    /// What ThreadList appends to when a row is tapped: at most one deep
    /// here, the open thread. A tap already marked the row read.
    func listPath(in model: AppModel) -> Binding<[ThreadRow]> {
        Binding(
            get: { self.openRow.map { [$0] } ?? [] },
            set: { rows in
                if let row = rows.last { self.open(row, in: model) } else { self.close() }
            }
        )
    }
}

/// The phone's MailListScreen without its stack: the list, the title, the
/// actions, the offline line and the triage pill.
private struct PadMailList: View {
    @Bindable var state: PadState
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.hasLoadedOnce {
                SkeletonList()
            } else if model.groupedRows.isEmpty {
                EmptyState(view: model.view, searching: false, lastSyncAt: model.lastSyncAt)
            } else {
                PadThreadList(state: state)
            }
        }
        .refreshable { await model.sync() }
        .background(Theme.canvas)
        .navigationTitle(model.tab == .inbox ? model.folder.title : model.tab.title)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { ListTitle(tab: model.tab) }
            if model.aiConfigured {
                ToolbarItem(placement: .barTrailing) {
                    Button { model.openViewSummary() } label: { Image(systemName: "sparkles") }
                        .accessibilityLabel("Summarize this view")
                }
            }
            if model.tab == .inbox && InboxAsk.isAvailable(model) {
                ToolbarItem(placement: .barTrailing) {
                    Button { model.askSheet = AskPresentation() } label: { Image(systemName: "questionmark.bubble") }
                        .accessibilityLabel("Ask my inbox")
                }
            }
            ToolbarItem(placement: .barTrailing) {
                Button { model.compose(SendDraft()) } label: { Image(systemName: "square.and.pencil") }
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityLabel("Compose")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.tab == .inbox {
                VStack(spacing: 0) {
                    AnalysisProgressBar()
                    if !model.triageLabels.isEmpty { TriageSplitBar() }
                }
                .animation(.snappy, value: model.analysis.isVisible)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { OfflineBar() }
    }
}

/// ThreadList, scrolled to the row a key or an auto-advance opened.
private struct PadThreadList: View {
    @Bindable var state: PadState
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ThreadList(path: state.listPath(in: model))
                .onChange(of: state.scrollTarget) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
        }
    }
}

/// The phone's SearchScreen without its stack: the field in the bar, the
/// filters, the recent searches or the results, and Gmail's own search.
private struct PadSearchList: View {
    @Bindable var state: PadState
    @Environment(AppModel.self) private var model
    @State private var picking: PersonField?
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isSearching && model.groupedRows.isEmpty && model.isSearchPending {
                Color.clear
            } else if model.isSearching && model.groupedRows.isEmpty {
                VStack(spacing: 0) {
                    EmptyState(view: model.view, searching: true, lastSyncAt: model.lastSyncAt)
                    GmailSearchRow()
                }
            } else if model.isSearching {
                VStack(spacing: 0) {
                    ResultCount(count: model.searchResults.count)
                    PadThreadList(state: state)
                    GmailSearchRow()
                }
            } else {
                RecentSearches()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .safeAreaInset(edge: .top, spacing: 0) { SearchFilterBar(picking: $picking) }
        .navigationTitle("Search")
        .inlineNavigationTitle()
        .alwaysShownSearch(text: $model.searchText, prompt: "Search mail")
        .searchFocused($searchFocused)
        .onSubmit(of: .search) { model.rememberSearch() }
        // A result opened beside the list: the search is one to remember,
        // as it is when a result is pushed on the phone.
        .onChange(of: state.openRow?.id) { _, id in
            guard id != nil else { return }
            Keyboard.dismiss()
            model.rememberSearch()
        }
        .sheet(item: $picking) { field in PersonPicker(field: field) }
        // `/` from another place: the field takes the caret once it is here.
        .onAppear { takeSearchFocus() }
        .onChange(of: state.wantsSearchFocus) { _, _ in takeSearchFocus() }
    }

    private func takeSearchFocus() {
        guard state.wantsSearchFocus else { return }
        state.wantsSearchFocus = false
        // A turn later: the field is not in the bar yet as the column appears.
        Task { @MainActor in searchFocused = true }
    }
}

// MARK: - The detail column

/// The open thread, or a word that none is. Its own stack, so the shared
/// ThreadView's title and toolbar items have a bar to sit in.
private struct PadDetailColumn: View {
    @Bindable var state: PadState
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let row = state.openRow {
                    ThreadView(row: row) { state.closeOpen(in: model) }
                        .id(row.id)
                } else {
                    ContentUnavailableView("No thread open", systemImage: "envelope.open",
                                           description: Text("Pick one in the list, or press J on a keyboard."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.canvas)
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(phases: .down) { press in state.handle(press, in: model) }
        }
        // The keys follow the thread a key opened; Esc hands them back
        // to the list (PadState.listFocusRequest).
        .onChange(of: state.openRow?.id) { _, id in
            if id != nil { focused = true }
        }
    }
}

// MARK: - Keys

extension PadState {
    /// A key press from the list or the detail column. Nothing while a
    /// sheet is up: its fields and buttons own the keyboard then.
    func handle(_ press: KeyPress, in model: AppModel) -> KeyPress.Result {
        let sheetUp = model.composeDraft != nil || model.showSettings || model.showSidebar || model.showBundles
            || model.pendingRemind != nil || model.pendingBundlePick != nil || model.askSheet != nil
            || model.summarySheet != nil
        guard !sheetUp else { return .ignored }
        let key: PadKey
        switch press.key {
        case .upArrow: key = .up
        case .downArrow: key = .down
        case .escape: key = .escape
        default: key = .character(press.characters)
        }
        guard let command = PadKeys.resolve(key, modifiers: press.modifiers) else { return .ignored }
        // Esc with nothing open is not ours: let the system have it.
        if command == .close && openRow == nil { return .ignored }
        run(command, in: model)
        return .handled
    }
}
#endif
