// The main window, the phone's shape made bigger: one column, the list full
// width up to a readable maximum, a thread opening in its place
// (NavigationStack, as in MailListScreen), the folders in a drawer on the
// left that ⌃⌘S or the header's button puts away. No title bar and no
// toolbar — the header rows are views (InboxPage, ThreadPage), glass circles
// like the phone's. The sheets the phone presents from its root (Remind me,
// compose, the summary, Ask my inbox) are presented here, the toast floats
// over the bottom edge, and the keyboard map works wherever the focus is as
// long as it is not a text field.

import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var state = WindowState()

    var body: some View {
        @Bindable var model = model
        @Bindable var state = state
        HStack(spacing: 0) {
            if state.sidebarVisible {
                SidebarColumn(state: state)
                    .frame(width: 232)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Rectangle().fill(Theme.separator).frame(width: 1)
            }
            NavigationStack(path: $state.path) {
                InboxPage(state: state)
                    .navigationDestination(for: ThreadRow.self) { row in
                        ThreadPage(row: row, state: state)
                    }
            }
        }
        .animation(.snappy(duration: 0.25), value: state.sidebarVisible)
        .background(Theme.canvas)
        .frame(minWidth: 720, minHeight: 480)
        // The window has no toolbar: the header rows are the pages' own.
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .focusedSceneValue(\.windowState, state)
        // Keys that reach the window itself (nothing else has focus): the
        // same map the list and the thread handle.
        .onKeyPress(phases: .down) { press in state.handle(press, model: model) }
        .overlay(alignment: .bottom) { MacToast() }
        .sheet(item: $model.pendingRemind) { row in RemindSheet(row: row) }
        .sheet(item: $model.composeDraft) { draft in
            ComposeView(draft: draft)
                .frame(minWidth: 720, idealWidth: 800, minHeight: 600, idealHeight: 720)
        }
        .sheet(item: $model.summarySheet) { p in SummarySheet(presentation: p) }
        .sheet(item: $model.askSheet) { p in AskSheet(question: p.question) }
        .sheet(isPresented: $state.showPalette, onDismiss: { state.listFocusRequest += 1 }) {
            CommandPalette(state: state, stage: state.paletteStage)
        }
        .sheet(isPresented: $state.showShortcuts) { ShortcutsSheet() }
        .sheet(isPresented: $state.showTriage) {
            NavigationStack { TriageJournalView() }
                .frame(minWidth: 560, idealWidth: 620, minHeight: 560, idealHeight: 680)
                .background(Theme.canvas)
        }
        .alert(
            "Account disconnected",
            isPresented: Binding(get: { model.disconnectedAccountId != nil },
                                 set: { if !$0 { model.disconnectedAccountId = nil } })
        ) {
            Button("Reconnect") {
                let id = model.disconnectedAccountId
                Task { await model.addAccount(loginHint: id) }
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("\(model.disconnectedAccountId ?? "") needs to sign in again. Mail for it is stale until then.")
        }
        // The model's sheet flags are the phone's; here Settings is a window
        // and the sidebar the drawer.
        .onChange(of: model.showSettings) { _, show in
            guard show else { return }
            model.showSettings = false
            openSettings()
        }
        .onChange(of: model.showSidebar) { _, show in
            guard show else { return }
            model.showSidebar = false
            state.sidebarVisible = true
        }
        .onAppear {
            state.openInWindow = { id in openWindow(id: MacWindows.thread, value: id) }
        }
    }
}

/// Bottom toast with an optional Undo — the archive action's safety net.
/// The phone's, without the room it leaves for a tab bar.
struct MacToast: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            HStack(spacing: 12) {
                Text(toast.text).font(.subheadline.weight(.medium)).lineLimit(2)
                if let undo = toast.undo {
                    Button("Undo") { undo(); model.toast = nil }
                        .buttonStyle(.plain)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .glassEffect(.regular.interactive(), in: .capsule)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: toast.id) {
                try? await Task.sleep(for: .seconds(5))
                if model.toast?.id == toast.id { withAnimation { model.toast = nil } }
            }
        }
    }
}
