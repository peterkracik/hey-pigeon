// The one bar across the top of the window, the first desktop client's
// (desktop-app's topbar, InboxList's folder title and the Jev label tabs):
// the traffic lights' room (WindowChrome centres them here), the sidebar
// button, then what the content shows —
//   the list: the folder and its count as the first tab, the triage
//     labels from Settings as the next ones (the phone's bottom split bar);
//   a search: the field;
//   a full thread: back, and the people as a title whose chevron opens the
//     thread's actions;
//   Settings: back, and "Settings" —
// and at the right the icon buttons: summarize, ask, new message, search,
// Settings. The bar's empty part drags the window, as a title bar does.

import SwiftUI

struct TopBar: View {
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    private var openRow: ThreadRow? {
        state.path.last.map { model.row(forThreadId: $0.id) ?? $0 }
    }

    var body: some View {
        HStack(spacing: 6) {
            TrafficLightsGap()
            IconButton("sidebar.leading", help: state.sidebarVisible ? "Hide the sidebar (⌃⌘S)" : "Show the sidebar (⌃⌘S)") {
                state.run(.toggleSidebar, in: model)
            }
            leading
            Spacer(minLength: 12)
            trailing
        }
        .padding(.trailing, 14)
        .frame(height: MacLayout.topBar)
        .frame(maxWidth: .infinity)
        .background {
            // The bar's empty part moves the window, as a title bar does.
            MacTheme.content.contentShape(Rectangle()).gesture(WindowDragGesture())
        }
        .onChange(of: state.searchFocusRequest) { _, _ in searchFocused = true }
    }

    // MARK: Leading

    @ViewBuilder private var leading: some View {
        if state.showSettings {
            IconButton("chevron.left", help: "Back (Esc)") { state.run(.back, in: model) }
            TitleText(text: "Settings").padding(.leading, 4)
        } else if let row = openRow {
            IconButton("chevron.left", help: "Back to the list (Esc)") { state.run(.back, in: model) }
            TitleMenu { ThreadMenu(row: row, state: state) } label: {
                TitleText(text: row.fromSummary)
            }
            .help("Thread actions")
        } else if state.searching {
            searchField
        } else {
            FolderTabs(state: state)
        }
    }

    // MARK: Trailing

    @ViewBuilder private var trailing: some View {
        if model.isSyncing {
            ProgressView().controlSize(.small).padding(.trailing, 6)
        }
        if let row = openRow, !state.showSettings {
            if model.aiConfigured {
                IconButton("sparkles", help: "Summarize the thread (I)") { state.run(.summarizeThread, in: model) }
            }
            IconButton("macwindow", help: "Open in New Window (⌘↩)") { state.openInWindow?(row.id) }
        } else if !state.showSettings {
            if model.aiConfigured {
                IconButton("sparkles", help: "Summarize this view (⌥⌘I)") { model.openViewSummary() }
            }
            if model.tab == .inbox && InboxAsk.isAvailable(model) {
                IconButton("questionmark.bubble", help: "Ask my inbox (⌥⌘A)") { model.askSheet = AskPresentation() }
            }
        }
        IconButton("square.and.pencil", help: "New message (⌘N)") { model.compose(SendDraft()) }
        IconButton("magnifyingglass", help: "Search (/)") { state.run(.search, in: model) }
        IconButton(state.showSettings ? "gearshape.fill" : "gearshape", help: "Settings (⌘,)") {
            state.showSettings.toggle()
            if !state.showSettings { state.listFocusRequest += 1 }
        }
    }

    // MARK: Search

    private var searchField: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            TextField("Search mail", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .help("Leave the search (Esc)")
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .frame(maxWidth: 520)
        .macPanel(cornerRadius: 9)
    }
}

/// The folder as the first tab, its count beside it, then the triage
/// labels (Settings › Triage) as tabs that filter it — the desktop's label
/// tabs under the folder title. In a view without the labels the folder is
/// the only tab.
private struct FolderTabs: View {
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model

    private var title: String { model.tab == .inbox ? model.folder.title : model.tab.title }
    private var count: Int {
        switch model.tab {
        case .inbox: model.counts[model.folder.countKey] ?? 0
        case .scheduled: model.scheduledCount
        case .needReply: model.needReplyCount
        case .search: 0
        }
    }
    private var showsLabels: Bool { model.tab == .inbox && !model.isSearching && !model.triageLabels.isEmpty }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                FolderTab(title: title, count: count, on: !showsLabels || model.triageFilterId == nil) {
                    model.triageFilterId = nil
                }
                if showsLabels {
                    ForEach(model.triageLabels) { l in
                        FolderTab(title: l.name, count: 0, on: model.triageFilterId == l.id) {
                            model.triageFilterId = l.id
                        }
                    }
                }
            }
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// One tab: the title in the bar's size, its count small beside it; the
/// shown one in the primary colour, the others quieter.
private struct FolderTab: View {
    let title: String
    let count: Int
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(title).font(.system(size: 17, weight: on ? .semibold : .regular))
                if count > 0 {
                    Text("\(count)").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textTertiary).monospacedDigit()
                }
            }
            .foregroundStyle(on ? Theme.textPrimary : (hovering ? Theme.textPrimary : Theme.textSecondary))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityLabel(count > 0 ? "\(title), \(count)" : title)
    }
}
