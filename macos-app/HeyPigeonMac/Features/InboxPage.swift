// The window's root page: a header row — the folders button, the folder's
// name with its count and the account (the phone's ListTitle), the glass
// circles for AI, search and compose, or the search field — then the
// phone's list (ThreadRowView, GroupHeader) full width up to a readable
// maximum, the Jev label pill at the bottom. A row's actions come three
// ways, all through WindowState: the keyboard map, the bar that appears
// when the pointer rests on a row (Done plus the four actions Settings puts
// on the swipes), and a two-finger trackpad swipe (the same four, two per
// side). A click opens the thread in place (ThreadPage); ⌘-click and
// ⇧-click gather rows for the batch bar. Search results, the From / To /
// Unread / account filters and the recent searches are the phone's Search
// tab's pieces (Features/Search/SearchScreen.swift).

import AppKit
import SwiftUI

/// The readable column the list, the header and the thread share, and the
/// room the traffic lights take at the top left when the drawer is away
/// (the window has no title bar).
enum MacLayout {
    static let maxWidth: CGFloat = 1040
    static let trafficLights: CGFloat = 62
    static let headerTop: CGFloat = 10
}

struct InboxPage: View {
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model
    @State private var picking: PersonField?
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            InboxHeader(state: state, searchFocused: $searchFocused)
            if state.searching || model.isSearching {
                SearchFilterBar(picking: $picking)
                if model.isSearching { ResultCount(count: model.searchResults.count) }
            }
            content
        }
        .frame(maxWidth: MacLayout.maxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .safeAreaInset(edge: .bottom) {
            if state.selection.count > 1 {
                BatchBar(state: state)
            } else if model.tab == .inbox && !model.isSearching && !model.triageLabels.isEmpty {
                TriageSplitBar().frame(maxWidth: 600)
            }
        }
        .sheet(item: $picking) { field in PersonPicker(field: field) }
        .onChange(of: state.searchFocusRequest) { _, _ in searchFocused = true }
        .onChange(of: state.listFocusRequest) { _, _ in
            searchFocused = false
            listFocused = true
        }
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
                            MacThreadRow(row: row, state: state)
                        }
                    } header: {
                        GroupHeader(group: group).padding(.horizontal, 16).padding(.top, 8)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
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
            .animation(.easeOut(duration: 0.15), value: model.rows.map(\.id))
        }
    }
}

/// The top row, in the title bar's place: the drawer button, the phone's
/// title (folder · count · account), the glass circles — or, while
/// searching, the field with its Done.
private struct InboxHeader: View {
    @Bindable var state: WindowState
    var searchFocused: FocusState<Bool>.Binding
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            TrafficLightsGap(state: state)
            GlassCircle("sidebar.leading", help: "Folders and accounts (⌃⌘S)") { state.run(.toggleSidebar, in: model) }
            if state.searching {
                searchField
            } else {
                ListTitle(tab: model.tab)
                Spacer(minLength: 8)
                if model.isSyncing {
                    ProgressView().controlSize(.small).padding(.trailing, 4)
                }
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        if model.aiConfigured {
                            GlassCircle("sparkles", help: "Summarize this view (⌥⌘I)") { model.openViewSummary() }
                        }
                        if model.tab == .inbox && InboxAsk.isAvailable(model) {
                            GlassCircle("questionmark.bubble", help: "Ask my inbox (⌥⌘A)") { model.askSheet = AskPresentation() }
                        }
                        GlassCircle("magnifyingglass", help: "Search (/)") { state.run(.search, in: model) }
                        GlassCircle("square.and.pencil", help: "New message (⌘N)") { model.compose(SendDraft()) }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, MacLayout.headerTop)
        .padding(.bottom, 6)
    }

    private var searchField: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
            TextField("Search mail", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused(searchFocused)
                .onSubmit { model.rememberSearch() }
                .onExitCommand { state.run(.escape, in: model) }
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityLabel("Clear")
            }
            Button("Done") { state.run(.escape, in: model) }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .help("Leave the search (Esc)")
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .glassEffect(.regular, in: .capsule)
    }
}

/// With the drawer away, the traffic lights sit over the header's left
/// end: keep it clear of them.
struct TrafficLightsGap: View {
    let state: WindowState

    var body: some View {
        if !state.sidebarVisible {
            Color.clear.frame(width: MacLayout.trafficLights, height: 1)
        }
    }
}

/// The phone's glass circle: one icon on Liquid Glass.
struct GlassCircle: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    init(_ systemImage: String, help: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One row: the phone's three lines on the phone's surfaces (unread on the
/// card, read sunk into the canvas), the highlight when it is the cursor
/// or part of the selection, the unread bar on the left edge, the hover bar
/// on the right, the context menu and the trackpad swipes.
private struct MacThreadRow: View {
    let row: ThreadRow
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private var selected: Bool { state.selection.contains(row.id) }

    var body: some View {
        ThreadRowView(row: row, showAccountDot: model.selectedAccountId == nil,
                      highlight: model.isSearching ? model.searchTerms : [])
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .leading) {
                if !row.isRead {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.unreadBar).frame(width: 3).padding(.vertical, 10)
                }
            }
            .overlay(alignment: .trailing) {
                if hovering { HoverActions(row: row, state: state).padding(.trailing, 10) }
            }
            .contentShape(Rectangle())
            // A click opens; ⌘ and ⇧ gather rows for the batch bar.
            .onTapGesture {
                let modifiers = NSEvent.modifierFlags
                if modifiers.contains(.command) {
                    state.toggle(row.id, in: model)
                } else if modifiers.contains(.shift) {
                    state.extend(to: row.id, in: model)
                } else {
                    state.open(row, in: model)
                }
            }
            .onHover { hovering = $0 }
            .padding(.horizontal, 8)
            .padding(.bottom, 1)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
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

    private var background: Color {
        if selected { return Theme.sunken }
        if hovering { return Theme.card }
        return row.isRead ? Theme.rowRead : Theme.rowUnread
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

/// Several rows highlighted: how many, and the actions that make sense for
/// all of them at once, on a glass pill at the bottom edge.
private struct BatchBar: View {
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            Text("\(state.selection.count) selected")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.leading, 10).padding(.trailing, 6)
            Divider().frame(height: 18)
            action("Mark done", "checkmark", .markDone)
            action("Read / unread", "envelope.open", .toggleRead)
            action("Pin", "pin", .pin)
            action("Need reply", "arrowshape.turn.up.left", .needReply)
            action("Delete", "trash", .delete)
            Divider().frame(height: 18)
            Button("Clear") { state.selection = [] }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .help("Clear the selection (Esc)")
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 12)
    }

    private func action(_ title: String, _ systemImage: String, _ command: MailCommand) -> some View {
        Button { state.run(command, in: model) } label: {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textPrimary)
        .help(title)
        .accessibilityLabel(title)
    }
}
