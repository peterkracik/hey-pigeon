// The window's root page, under the top bar (TopBar in MainWindow): the
// list, full width up to a readable maximum, in the first desktop
// client's shape — single-line rows with a done circle, like a to-do list
// (MailRow), the day groups between them, a click opening the row's
// latest message in place as a card with "Open full thread ›". ⌘-click
// and ⇧-click gather rows for the batch bar. Search results, the From /
// To / Unread / account filters and the recent searches are the phone's
// Search tab's pieces (Features/Search/SearchScreen.swift); the field
// itself is in the top bar.

import AppKit
import SwiftUI

struct InboxPage: View {
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model
    @State private var picking: PersonField?
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if state.searching || model.isSearching {
                SearchFilterBar(picking: $picking).padding(.top, 8)
                if model.isSearching { ResultCount(count: model.searchResults.count) }
            }
            content
        }
        .frame(maxWidth: MacLayout.maxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacTheme.content)
        .safeAreaInset(edge: .bottom) {
            if state.selection.count > 1 { BatchBar(state: state) }
        }
        .sheet(item: $picking) { field in PersonPicker(field: field) }
        .onChange(of: state.listFocusRequest) { _, _ in listFocused = true }
    }

    @ViewBuilder private var content: some View {
        if state.searching && !model.isSearching {
            RecentSearches()
        } else if !model.hasLoadedOnce {
            SkeletonList()
        } else if model.groupedRows.isEmpty {
            EmptyState(view: model.view, searching: model.isSearching, lastSyncAt: model.lastSyncAt)
        } else {
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(model.groupedRows) { group in
                    Section {
                        ForEach(group.rows) { row in
                            MailRow(row: row, state: state)
                        }
                    } header: {
                        GroupHeader(group: group)
                            .padding(.horizontal, 26).padding(.top, 14).padding(.bottom, 2)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .contentMargins(.top, 6, for: .scrollContent)
            .contentMargins(.bottom, 40, for: .scrollContent)
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .defaultFocus($listFocused, true)
            .onKeyPress(phases: .down) { press in state.handle(press, model: model) }
            .onDeleteCommand { state.run(.delete, in: model) }
            .onChange(of: state.scrollTarget) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
            .onChange(of: model.groupedRows.map { $0.rows.map(\.id) }) { _, _ in state.rowsChanged(in: model) }
            // A notification, a widget, Spotlight or the menu bar extra
            // asked for a thread.
            .onChange(of: model.pendingThreadId, initial: true) { _, id in
                guard let id, let row = model.row(forThreadId: id) else { return }
                model.pendingThreadId = nil
                state.open(row, in: model)
            }
            .animation(.easeOut(duration: 0.18), value: model.rows.map(\.id))
            .animation(.snappy(duration: 0.22), value: state.expanded)
        }
    }
}

/// With the sidebar away, the traffic lights sit at the top bar's left
/// end: keep it clear of them. (They are always in the top bar now; the
/// gap is always kept.)
struct TrafficLightsGap: View {
    var body: some View {
        Color.clear.frame(width: MacLayout.trafficLights, height: 1)
    }
}

/// Several rows highlighted: how many, and the actions that make sense for
/// all of them at once, on a bordered panel at the bottom edge.
private struct BatchBar: View {
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            Text("\(state.selection.count) selected")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.leading, 10).padding(.trailing, 6)
            Divider().frame(height: 18)
            IconButton("checkmark.circle", help: "Mark done") { state.run(.markDone, in: model) }
            IconButton("envelope.open", help: "Read / unread") { state.run(.toggleRead, in: model) }
            IconButton("pin", help: "Pin") { state.run(.pin, in: model) }
            IconButton("arrowshape.turn.up.left", help: "Need reply") { state.run(.needReply, in: model) }
            IconButton("trash", help: "Delete") { state.run(.delete, in: model) }
            Divider().frame(height: 18)
            Button("Clear") { state.selection = [] }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .help("Clear the selection (Esc)")
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .macPanel(cornerRadius: 12)
        .padding(.bottom, 14)
    }
}
