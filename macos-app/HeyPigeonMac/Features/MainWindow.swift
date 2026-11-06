// The main window, in the first desktop client's shape under a standard
// Mac toolbar (MainToolbar: the traffic lights where they always are, the
// sidebar button and the view's title beside them, the actions at the
// right): the grey sidebar (SidebarColumn, ⌃⌘S puts it away) beside the
// content — the list full width up to a readable maximum with rows that
// open in place, a full thread in its place (NavigationStack, as in
// MailListScreen), or Settings. The search and the command palette float
// over the blurred window as Spotlight panels (SearchSpotlight,
// CommandPalette); the sidebar button is a glass circle in the bottom
// corner. The look is in MacStyle. The sheets the phone presents from its root (Remind
// me, compose, the summary, Ask my inbox) are presented here, the toast floats
// over the bottom edge, and the keyboard map works wherever the focus is as
// long as it is not a text field.

import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var state = WindowState()
    /// The window's size, for the composer's full-screen sheet.
    @State private var windowSize = CGSize(width: 1000, height: 760)

    /// A Spotlight panel (the search, the palette) floats over the window.
    private var overlaid: Bool { state.searching || state.showPalette }

    /// The composer's sheet: a new message, a forward, a reply pulled out
    /// into a window, or a reply to a thread no window shows. A reply to
    /// the open thread (or to one in a thread window) is written under it
    /// instead (ThreadView's inline composer, `ComposePlacement`).
    private var composeSheet: Binding<SendDraft?> {
        let modal = model.modal(\.composeDraft, inBundles: false)
        return Binding(
            get: {
                guard let d = modal.wrappedValue else { return nil }
                let inline = ComposePlacement.isInline(d, openThread: state.path.last?.id,
                                                       threadWindows: ThreadWindows.open, detached: model.composeDetached)
                return inline ? nil : d
            },
            set: { modal.wrappedValue = $0 }
        )
    }

    var body: some View {
        @Bindable var model = model
        @Bindable var state = state
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if state.sidebarVisible {
                    SidebarColumn(state: state)
                        .frame(width: MacLayout.sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Rectangle().fill(MacTheme.hairline).frame(width: 1)
                }
                if state.showSettings {
                    SettingsView()
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else {
                    NavigationStack(path: $state.path) {
                        InboxPage(state: state)
                            .navigationDestination(for: ThreadRow.self) { row in
                                ThreadPage(row: row, state: state)
                            }
                    }
                }
            }
        }
        // The sidebar button, in the window's bottom corner: the drawer
        // starts hidden and comes out from there.
        .overlay(alignment: .bottomLeading) {
            Button { state.run(.toggleSidebar, in: model) } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(state.sidebarVisible ? "Hide the sidebar (⌃⌘S)" : "Show the sidebar (⌃⌘S)")
            .accessibilityLabel(state.sidebarVisible ? "Hide the sidebar" : "Show the sidebar")
            .padding(12)
        }
        .blur(radius: overlaid ? 12 : 0)
        .overlay {
            if state.searching {
                SearchSpotlight(state: state)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            } else if state.showPalette {
                // A new stage (the label or move picker) starts afresh.
                CommandPalette(state: state, stage: state.paletteStage)
                    .id(state.paletteStage)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(.snappy(duration: 0.25), value: state.sidebarVisible)
        .animation(.easeOut(duration: 0.15), value: state.showSettings)
        .animation(.easeOut(duration: 0.16), value: state.searching)
        .animation(.easeOut(duration: 0.16), value: state.showPalette)
        .background(MacTheme.content)
        .frame(minWidth: 760, minHeight: 480)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { windowSize = $0 }
        // A standard toolbar: the traffic lights and the sidebar button
        // where a Mac user looks for them. No window title: the view's
        // title is the toolbar's own item.
        .toolbar { MainToolbar(state: state, model: model) }
        .toolbar(removing: .title)
        // Under a floating panel the bar is clear (and empty), so the dim
        // reaches the top of the window.
        .toolbarBackgroundVisibility(overlaid ? .hidden : .automatic, for: .windowToolbar)
        .focusedSceneValue(\.windowState, state)
        // Keys that reach the window itself (nothing else has focus): the
        // same map the list and the thread handle.
        .onKeyPress(phases: .down) { press in state.handle(press, model: model) }
        .overlay(alignment: .bottom) { MacToast() }
        // While the Bundles sheet is open it presents these itself
        // (AppModel.modal, BundleSheetPresenters).
        .sheet(item: model.modal(\.pendingRemind, inBundles: false)) { row in RemindSheet(row: row) }
        .sheet(item: model.modal(\.pendingBundlePick, inBundles: false)) { row in AddToBundleSheet(row: row) }
        .sheet(isPresented: $model.showBundles, onDismiss: { model.bundlesStartId = nil }) {
            BundlesSheet(initialBundleId: model.bundlesStartId)
        }
        .sheet(item: composeSheet) { draft in
            ComposeView(draft: draft)
                .composeSheetSize(fullScreen: model.composeFullScreen, window: windowSize)
        }
        .sheet(item: model.modal(\.summarySheet, inBundles: false)) { p in SummarySheet(presentation: p) }
        .sheet(item: $model.askSheet) { p in AskSheet(question: p.question) }
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
        // The model's sheet flags are the phone's; here Settings is a page
        // of the window (⌘,, the palette) and the sidebar the drawer.
        .onChange(of: model.showSettings, initial: true) { _, show in
            guard show else { return }
            model.showSettings = false
            state.searching = false
            state.showSettings = true
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
/// A bordered panel at the bottom edge, as the Claude app's notices are.
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
            .padding(.horizontal, 16).padding(.vertical, 11)
            .macPanel()
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: toast.id) {
                try? await Task.sleep(for: .seconds(5))
                if model.toast?.id == toast.id { withAnimation { model.toast = nil } }
            }
        }
    }
}

/// Where the Mac writes a draft: under the thread it answers when that
/// thread is on screen (Superhuman's inline reply), else in the sheet.
/// Pure, so the tests can ask it.
enum ComposePlacement {
    /// True for a reply to the window's open thread or to one in a thread
    /// window of its own, unless the user pulled it out into a window.
    static func isInline(_ draft: SendDraft, openThread: String?, threadWindows: Set<String> = [],
                         detached: Bool) -> Bool {
        guard !detached, let id = draft.replyToThreadId else { return false }
        return openThread == id || threadWindows.contains(id)
    }
}

private extension View {
    /// The composer's sheet: a dialog, or (its full-screen button) as big
    /// as the window allows; a sheet cannot outgrow its window. One frame
    /// call, not an if/else: a branch would be a new view and the switch
    /// would throw away what is typed.
    func composeSheetSize(fullScreen: Bool, window: CGSize) -> some View {
        let w = max(720, window.width - 24), h = max(600, window.height - 24)
        return frame(minWidth: fullScreen ? w : 720, idealWidth: fullScreen ? w : 800,
                     maxWidth: fullScreen ? w : nil,
                     minHeight: fullScreen ? h : 600, idealHeight: fullScreen ? h : 720,
                     maxHeight: fullScreen ? h : nil)
    }
}
