// The window's root page, under the window's toolbar (MainToolbar): the
// list, full width up to a readable maximum, in the first desktop
// client's shape — single-line rows with a done circle, like a to-do list
// (MailRow), the day groups between them, a click opening the row's
// latest message in place as a card with "Open full thread ›". ⌘-click
// and ⇧-click gather rows for the batch bar. Search results, the From /
// To / Unread / account filters and the recent searches are the phone's
// Search tab's pieces (Features/Search/SearchScreen.swift); the field is
// the Spotlight panel (SearchSpotlight). The triage labels are the phone's
// glass pill at the bottom (TriageSplitBar).

import AppKit
import SwiftUI

struct InboxPage: View {
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model
    @State private var picking: PersonField?
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.isSearching {
                SearchFilterBar(picking: $picking).padding(.top, 8)
                if model.isSearching { ResultCount(count: model.searchResults.count) }
            }
            content
        }
        .frame(maxWidth: MacLayout.maxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacTheme.listBackground)
        .safeAreaInset(edge: .bottom) {
            if state.selection.count > 1 {
                BatchBar(state: state)
            } else if model.tab == .inbox && !model.isSearching && !model.triageLabels.isEmpty {
                // The triage labels as the phone's Liquid Glass pill: as
                // wide as its tabs, at most the list's readable width.
                ViewThatFits(in: .horizontal) {
                    TriageSplitBar().fixedSize(horizontal: true, vertical: false)
                    TriageSplitBar().frame(maxWidth: 720)
                }
                .padding(.bottom, 8)
            }
        }
        .sheet(item: $picking) { field in PersonPicker(field: field) }
        .onChange(of: state.listFocusRequest) { _, _ in listFocused = true }
    }

    @ViewBuilder private var content: some View {
        if !model.hasLoadedOnce {
            SkeletonList()
        } else if model.groupedRows.isEmpty && model.isSearching && model.isSearchPending {
            Color.clear
        } else if model.groupedRows.isEmpty {
            EmptyState(view: model.view, searching: model.isSearching, lastSyncAt: model.lastSyncAt)
        } else {
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                // No section headers: on the Mac a list's header floats on
                // its own grey band. The group's title is a plain row, and
                // its rows share one white card (MailRow draws its piece).
                ForEach(model.groupedRows) { group in
                    GroupHeader(group: group)
                        .padding(.horizontal, 30).padding(.top, 16).padding(.bottom, 6)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                        MailRow(row: row, state: state,
                                position: .init(first: index == 0, last: index == group.rows.count - 1))
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
            // The order of the rows moved (the model counts it: comparing
            // a fresh array of every id on every render added up).
            .onChange(of: model.rowOrderRevision) { _, _ in
                state.rowsChanged(in: model)
                model.prefetchTopOfInbox()
            }
            .onAppear { model.prefetchTopOfInbox() }
            // A notification, a widget, Spotlight or the menu bar extra
            // asked for a thread.
            .onChange(of: model.pendingThreadId, initial: true) { _, id in
                guard let id, let row = model.row(forThreadId: id) else { return }
                model.pendingThreadId = nil
                state.open(row, in: model)
            }
            // No animation keyed on the rows (ios-app/CLAUDE.md): it laid
            // every row out again on each reload. A row that leaves is
            // animated where the rows change (AppModel.perform).
            .animation(.snappy(duration: 0.22), value: state.expanded)
        }
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
