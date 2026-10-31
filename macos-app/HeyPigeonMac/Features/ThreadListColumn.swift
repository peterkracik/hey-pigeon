// The middle column: the folder's name and the account in the title bar,
// the search field in the toolbar, the day groups and rows of the phone's
// list (ThreadRowView, GroupHeader), the Jev label pill at the bottom. A
// row's actions come three ways, all through WindowState: the keyboard
// map, the bar that appears when the pointer rests on a row (Done plus the
// four actions Settings puts on the swipes), and a two-finger trackpad
// swipe (the same four, two per side). Search results, the From / To /
// Unread / account filters and the recent searches are the Search tab's
// own pieces (Features/Search/SearchScreen.swift).

import SwiftUI

struct ThreadListColumn: View {
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model
    @State private var picking: PersonField?
    @FocusState private var searchFocused: Bool

    private var title: String { model.tab == .inbox ? model.folder.title : model.tab.title }

    private var subtitle: String {
        var parts: [String] = []
        let count: Int
        switch model.tab {
        case .inbox, .search: count = model.counts[model.folder.countKey] ?? 0
        case .scheduled: count = model.scheduledCount
        case .needReply: count = model.needReplyCount
        }
        if count > 0 { parts.append(model.tab == .inbox ? "\(count) unread" : "\(count)") }
        if model.accounts.count > 1 { parts.append(model.currentAccount?.displayName ?? "All accounts") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        @Bindable var model = model
        ListBody(state: state, picking: $picking)
            .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search mail")
            .searchFocused($searchFocused)
            .searchSuggestions {
                if model.searchText.isEmpty {
                    ForEach(model.recentSearches) { entry in
                        Button { model.runRecentSearch(entry) } label: {
                            Label(entry.text.isEmpty ? "Filtered search" : entry.text, systemImage: "clock")
                        }
                    }
                }
            }
            .onSubmit(of: .search) { model.rememberSearch() }
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .toolbar {
                if model.accounts.count > 1 {
                    ToolbarItem(placement: .navigation) { accountMenu }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { Task { await model.sync() } } label: { Image(systemName: "arrow.clockwise") }
                            .help("Check for mail (⇧⌘N)")
                    }
                    if model.aiConfigured {
                        Button { model.openViewSummary() } label: { Image(systemName: "sparkles") }
                            .help("Summarize this view (⌥⌘I)")
                    }
                    if model.tab == .inbox && InboxAsk.isAvailable(model) {
                        Button { model.askSheet = AskPresentation() } label: { Image(systemName: "questionmark.bubble") }
                            .help("Ask my inbox (⌥⌘A)")
                    }
                    Button { model.composeDraft = SendDraft() } label: { Image(systemName: "square.and.pencil") }
                        .help("New message (⌘N)")
                }
            }
            .sheet(item: $picking) { field in PersonPicker(field: field) }
            .onChange(of: state.searchFocusRequest) { _, _ in searchFocused = true }
    }

    /// The account switcher (desktop 0/1/2): the dot and the name.
    private var accountMenu: some View {
        Menu {
            Button {
                state.run(.account(nil), in: model)
            } label: {
                Label("All accounts", systemImage: model.selectedAccountId == nil ? "checkmark" : "circle.grid.2x2")
            }
            ForEach(Array(model.accounts.enumerated()), id: \.element.id) { index, a in
                Button {
                    state.run(.account(index), in: model)
                } label: {
                    Label(a.displayName, systemImage: a.id == model.selectedAccountId ? "checkmark" : "circle.fill")
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let a = model.currentAccount {
                    Circle().fill(Theme.tagForeground(a.color)).frame(width: 8, height: 8)
                    Text(a.displayName)
                } else {
                    HStack(spacing: -2) {
                        ForEach(model.accounts.prefix(3)) { a in
                            Circle().fill(Theme.tagForeground(a.color)).frame(width: 8, height: 8)
                        }
                    }
                    Text("All")
                }
            }
        }
        .help("Switch account (⌃0 · ⌃1 · ⌃2)")
    }
}

/// Inside the searchable scope, so it can tell when the field is active and
/// show the filters above the rows.
private struct ListBody: View {
    @Bindable var state: WindowState
    @Binding var picking: PersonField?
    @Environment(AppModel.self) private var model
    @Environment(\.isSearching) private var isSearching
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if isSearching || model.isSearching {
                SearchFilterBar(picking: $picking)
                if model.isSearching {
                    ResultCount(count: model.searchResults.count)
                }
            }
            content
        }
        .background(Theme.canvas)
        .safeAreaInset(edge: .bottom) {
            if model.tab == .inbox && !model.isSearching && !model.triageLabels.isEmpty { TriageSplitBar() }
        }
        .onChange(of: state.listFocusRequest) { _, _ in listFocused = true }
    }

    @ViewBuilder private var content: some View {
        if !model.hasLoadedOnce {
            SkeletonList()
        } else if model.groupedRows.isEmpty {
            EmptyState(view: model.view, searching: model.isSearching, lastSyncAt: model.lastSyncAt)
        } else {
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List(selection: $state.selection) {
                ForEach(model.groupedRows) { group in
                    Section {
                        ForEach(group.rows) { row in
                            MacThreadRow(row: row, state: state)
                        }
                    } header: {
                        GroupHeader(group: group).padding(.horizontal, 12)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .focused($listFocused)
            .defaultFocus($listFocused, true)
            .onKeyPress(phases: .down) { press in state.handle(press, model: model) }
            .onDeleteCommand { state.run(.delete, in: model) }
            .onChange(of: state.scrollTarget) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
            .onChange(of: state.selection) { _, _ in state.selectionChanged(in: model) }
            .onChange(of: model.groupedRows.map { $0.rows.map(\.id) }) { _, _ in state.rowsChanged(in: model) }
            // A notification, a widget or Spotlight asked for a thread.
            .onChange(of: model.pendingThreadId, initial: true) { _, id in
                guard let id else { return }
                model.pendingThreadId = nil
                state.select(id, in: model)
            }
            .animation(.easeOut(duration: 0.15), value: model.rows.map(\.id))
        }
    }
}

/// One row: the phone's three lines, the unread bar on the left edge, the
/// hover bar on the right, the context menu and the trackpad swipes.
private struct MacThreadRow: View {
    let row: ThreadRow
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        ThreadRowView(row: row, showAccountDot: model.selectedAccountId == nil,
                      highlight: model.isSearching ? model.searchTerms : [])
            .padding(.horizontal, 16).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                if !row.isRead { Rectangle().fill(Theme.unreadBar).frame(width: 3) }
            }
            .overlay(alignment: .trailing) {
                if hovering { HoverActions(row: row, state: state).padding(.trailing, 10) }
            }
            .onHover { hovering = $0 }
            .tag(row.id)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .contextMenu {
                RowMenu(row: row)
                Divider()
                Button { state.openInWindow?(row.id) } label: { Label("Open in New Window", systemImage: "macwindow") }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                swipe(model.swipeActions[0])
                swipe(model.swipeActions[1])
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                swipe(model.swipeActions[2])
                swipe(model.swipeActions[3])
            }
            .onAppear { model.loadMoreIfNeeded(current: row) }
    }

    private func swipe(_ action: RowAction) -> some View {
        Button { state.run(action.command, in: model, rows: [row]) } label: {
            Label(action.label(for: row), systemImage: action.glyph(for: row))
        }
        .tint(action.tint)
    }
}

/// The desktop's hover actions as a glass pill: Done, then the four swipe
/// actions from Settings (each once).
private struct HoverActions: View {
    let row: ThreadRow
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model

    private var actions: [RowAction] {
        var list: [RowAction] = [.done]
        for a in model.swipeActions where !list.contains(a) { list.append(a) }
        return list
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(actions) { action in
                Button { state.run(action.command, in: model, rows: [row]) } label: {
                    Image(systemName: action.glyph(for: row))
                        .font(.footnote.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textPrimary)
                .help("\(action.label(for: row)) (\(action.key))")
                .accessibilityLabel(action.label(for: row))
            }
        }
        .padding(.horizontal, 4)
        .glassEffect(.regular, in: .capsule)
    }
}
