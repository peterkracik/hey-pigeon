// The window's toolbar: a real, unified macOS toolbar, so the traffic
// lights sit where every Mac app has them and behave as they do. At the
// leading end, next to them, the sidebar button, then the view's title
// (the folder and its count, "Search", "Settings" with a way back); at
// the trailing end summarize, ask, new message and search. Settings is
// in the app menu (⌘,), not here. A full thread brings its own items
// (the shared ThreadView's title, sparkle and actions menu) and the
// navigation stack's back button. The triage label tabs are the phone's
// glass pill at the bottom of the list (InboxPage).

import SwiftUI

struct MainToolbar: ToolbarContent {
    @Bindable var state: WindowState
    let model: AppModel

    private var title: String {
        if state.showSettings { return "Settings" }
        if model.isSearching { return "Search" }
        return model.tab == .inbox ? model.folder.title : model.tab.title
    }

    private var count: Int {
        if state.showSettings { return 0 }
        if model.isSearching { return model.searchResults.count }
        switch model.tab {
        case .inbox: return model.counts[model.folder.countKey] ?? 0
        case .scheduled: return model.scheduledCount
        case .needReply: return model.needReplyCount
        case .search: return 0
        }
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { state.run(.toggleSidebar, in: model) } label: {
                Label("Sidebar", systemImage: "sidebar.leading")
            }
            .help(state.sidebarVisible ? "Hide the sidebar (⌃⌘S)" : "Show the sidebar (⌃⌘S)")
        }
        if state.showSettings {
            ToolbarItem(placement: .navigation) {
                Button { state.run(.back, in: model) } label: { Label("Back", systemImage: "chevron.left") }
                    .help("Back (Esc)")
            }
        }
        if !state.isThreadOpen {
            ToolbarItem(placement: .navigation) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    if count > 0 {
                        Text("\(count)").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textTertiary).monospacedDigit()
                    }
                }
                .lineLimit(1)
                .padding(.horizontal, 6)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isSyncing {
                ProgressView().controlSize(.small)
            }
            if !state.isThreadOpen && !state.showSettings {
                if model.aiConfigured {
                    Button { model.openViewSummary() } label: { Label("Summarize", systemImage: "sparkles") }
                        .help("Summarize this view (⌥⌘I)")
                }
                if model.tab == .inbox && InboxAsk.isAvailable(model) {
                    Button { model.askSheet = AskPresentation() } label: { Label("Ask my inbox", systemImage: "questionmark.bubble") }
                        .help("Ask my inbox (⌥⌘A)")
                }
            }
            Button { model.compose(SendDraft()) } label: { Label("New message", systemImage: "square.and.pencil") }
                .help("New message (⌘N)")
            Button { state.run(.search, in: model) } label: { Label("Search", systemImage: "magnifyingglass") }
                .help("Search (/)")
        }
    }
}
