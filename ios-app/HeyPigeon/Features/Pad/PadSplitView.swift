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
// Keys: `PadKeys` are key equivalents on buttons that draw nothing
// (`PadKeyButtons`), so they work wherever the focus is; a text field
// gets a bare letter first, and the map stands down while any sheet is up.

#if os(iOS)
import SwiftUI

struct PadSplitView: View {
    /// RootView's, so the open thread outlives a window resized across
    /// the width where the columns give way to the tabs.
    let state: PadState
    @Environment(AppModel.self) private var model
    /// The list and the thread; the folders slide in from the bar's
    /// button, as the phone's drawer does. Three columns at once squeeze
    /// the thread in portrait.
    @State private var columns = NavigationSplitViewVisibility.doubleColumn

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
        .background { PadKeyButtons(state: state) }
        // Where the open thread sits in the list now, for the advance
        // when the user deals with it.
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
    let state: PadState
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.tab == .search {
                PadSearchList(state: state)
            } else {
                PadMailList(state: state)
            }
        }
        .environment(\.openThreadId, state.openRow?.id)
    }
}

/// The layout's keys (`PadKeys`), each on a button nobody sees.
private struct PadKeyButtons: View {
    let state: PadState
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            ForEach(Array(PadKeys.bindings.enumerated()), id: \.offset) { _, binding in
                Button(binding.command.title) { state.press(binding.command, in: model) }
                    .keyboardShortcut(binding.key, modifiers: binding.modifiers)
                    // Esc with nothing open is not ours: the system has it.
                    .disabled(binding.command == .close && state.openRow == nil)
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
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
    let state: PadState
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.hasLoadedOnce {
                SkeletonList()
            } else if model.groupedRows.isEmpty {
                // With no account: the sign-in, not "All clear" (the
                // phone's list and the Mac's window offer the same).
                EmptyState(view: model.view, searching: false, lastSyncAt: model.lastSyncAt,
                           connect: model.connectFirstAccount)
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
    let state: PadState
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ThreadList(path: state.listPath(in: model))
                .onChange(of: state.scrollTarget) { _, id in
                    guard let id else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
        }
    }
}

/// The phone's SearchScreen without its stack: the field in the bar, the
/// filters, the recent searches or the results, and Gmail's own search.
private struct PadSearchList: View {
    let state: PadState
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
    let state: PadState
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if let row = state.openRow {
                    ThreadView(row: row) { state.closeOpen(in: model) }
                        .id(row.id)
                } else if model.accounts.isEmpty {
                    // No account yet: the list column offers the sign-in,
                    // and "No thread open" beside it was a second empty
                    // state about mail that is not there.
                    Theme.canvas.ignoresSafeArea()
                } else {
                    // No instruction here: beside an empty list there is
                    // nothing to pick, and most iPads have no keyboard.
                    ContentUnavailableView("No thread open", systemImage: "envelope.open")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.canvas)
                }
            }
        }
    }
}

// MARK: - Keys

extension PadState {
    /// A key of the layout was pressed. Nothing while a sheet is up: its
    /// fields and buttons own the keyboard then.
    func press(_ command: PadCommand, in model: AppModel) {
        let sheetUp = model.composeDraft != nil || model.showSettings || model.showSidebar || model.showBundles
            || model.pendingRemind != nil || model.pendingBundlePick != nil || model.askSheet != nil
            || model.summarySheet != nil
        guard !sheetUp else { return }
        run(command, in: model)
    }
}
#endif
