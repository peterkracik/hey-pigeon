// The window's toolbar: a real, unified macOS toolbar, so the traffic
// lights sit where every Mac app has them and behave as they do. At the
// leading end, over the list column (past the sidebar when it is out:
// SidebarInset), the three places the phone has as tabs — Inbox · Remind
// me · Need reply — with their counts (another folder picked in the
// sidebar shows its name after them, and so do Settings and the Bundles
// page); at the trailing end summarize, ask,
// new message and search. The sidebar button is the
// glass circle in the window's bottom corner (MainWindow), Settings is in
// the app menu (⌘,). A page over the list (a thread; a bundle or an email
// on the Bundles page) gets the window's own Back as the first item over
// the content column — the stack's sat beside the traffic lights, over the
// sidebar — and its name after the tabs; the shared view's items (the
// thread's sparkle and actions menu) join at the trailing end. While the
// search or the command palette floats over the window the bar is left
// empty, so nothing sharp sits above the blur.

import SwiftUI

struct MainToolbar: ToolbarContent {
    @Bindable var state: WindowState
    let model: AppModel

    /// The panels float over the window: the bar stays out of the way.
    private var overlaid: Bool { state.searching || state.showPalette }

    /// The view when it is none of the three tabs (the open thread's
    /// people, a folder, a label, Settings, the Bundles page, a search),
    /// for the title after them.
    private var otherTitle: String? {
        if state.showSettings { return "Settings" }
        if let open = state.openThread { return open.fromSummary }
        if state.showBundles { return state.bundlesTitle(in: model) }
        if model.isSearching { return "Search" }
        return ViewTabs.views.contains(model.view) ? nil : model.view.title
    }

    var body: some ToolbarContent {
        if !overlaid {
            // The window lays its sidebar out itself (MainWindow's HStack),
            // so the toolbar knows nothing of the column under it: with
            // the sidebar out, a clear item first takes up what is left
            // of it past the traffic lights, and the tabs start over the
            // list instead of straddling the divider.
            if state.sidebarVisible {
                ToolbarItem(placement: .navigation) {
                    SidebarInset()
                }
                .sharedBackgroundVisibility(.hidden)
            }
            if state.canGoBack {
                ToolbarItem(placement: .navigation) {
                    Button { state.run(.back, in: model) } label: { Label("Back", systemImage: "chevron.left") }
                        .help("Back (Esc, ⌘[)")
                }
            }
            ToolbarItem(placement: .navigation) {
                ViewTabs(state: state, model: model)
            }
            if let otherTitle {
                ToolbarItem(placement: .navigation) {
                    Text(otherTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .accessibilityAddTraits(.isHeader)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            ToolbarSpacer(.flexible)
            ToolbarItemGroup {
                // Only a sync worth showing: one the user asked for, or one
                // that takes a while. A spinner for every 30-second round
                // came and went, and moved the buttons each time.
                if model.showsSyncActivity {
                    ProgressView().controlSize(.small)
                }
                if !state.isThreadOpen && !state.showSettings && !state.showBundles {
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
}

/// The leading item while the sidebar is out: nothing to see, as wide as
/// the sidebar column minus the part the traffic lights already cover, so
/// the item after it (the tabs) begins at the list's edge. The toolbar
/// lays its items out in the window's title bar, not in the content, so
/// the item reads its own place in the window through an AppKit probe
/// and takes the difference.
struct SidebarInset: View {
    /// Where the item starts in the window, from the left edge. The
    /// first measurement comes once the toolbar is in a window; until
    /// then a typical offset, so the tabs do not jump far.
    @State private var itemX: CGFloat = 80

    var body: some View {
        WindowXProbe(x: $itemX)
            .frame(width: Self.width(sidebar: MacLayout.sidebarWidth + 1, itemX: itemX), height: 1)
            .accessibilityHidden(true)
    }

    /// How much of the sidebar column (its width and the hairline) is
    /// left past where the item starts; nothing when the item already
    /// starts beyond it.
    static func width(sidebar: CGFloat, itemX: CGFloat) -> CGFloat {
        max(0, sidebar - itemX)
    }
}

/// An empty AppKit view that reports its x in the window's coordinates
/// (from the window's left edge, as the content view's are) whenever it is
/// placed, so a toolbar item can measure itself against the window's
/// columns. The report is deferred off the layout pass.
private struct WindowXProbe: NSViewRepresentable {
    @Binding var x: CGFloat

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onMove = { x = $0 }
    }

    final class ProbeView: NSView {
        var onMove: (@MainActor @Sendable (CGFloat) -> Void)?
        private var reported: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            report()
        }

        private func report() {
            guard window != nil else { return }
            let x = convert(bounds, to: nil).minX.rounded()
            guard x != reported else { return }
            reported = x
            let onMove = onMove
            Task { @MainActor in onMove?(x) }
        }
    }
}

/// Inbox · Remind me · Need reply, the phone's tabs, as one segmented
/// control on the toolbar's glass: the shown one in bold on a light pill,
/// a count beside each (Remind me's due count in the accent).
struct ViewTabs: View {
    @Bindable var state: WindowState
    let model: AppModel

    static let views: [MailView] = [.inbox, .scheduled, .needReply]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.views, id: \.self) { view in
                tab(view)
            }
        }
        .padding(2)
    }

    private func tab(_ view: MailView) -> some View {
        let on = !state.showSettings && !state.showBundles && !model.isSearching && model.view == view
        return Button { state.run(.go(view), in: model) } label: {
            HStack(spacing: 5) {
                Text(view.title).font(.system(size: 13, weight: on ? .semibold : .regular))
                count(view)
            }
            .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(on ? MacTheme.selected : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(view.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private func count(_ view: MailView) -> some View {
        switch view {
        case .inbox:
            let n = model.engineUnread(accountId: model.selectedAccountId)
            if n > 0 { number(n, Theme.textTertiary) }
        case .scheduled:
            if model.dueCount > 0 { number(model.dueCount, Theme.accent) }
            else if model.scheduledCount > 0 { number(model.scheduledCount, Theme.textTertiary) }
        case .needReply:
            if model.needReplyCount > 0 { number(model.needReplyCount, Theme.textTertiary) }
        default:
            EmptyView()
        }
    }

    private func number(_ n: Int, _ color: Color) -> some View {
        Text("\(n)").font(.system(size: 11, weight: .medium)).foregroundStyle(color).monospacedDigit()
    }
}
