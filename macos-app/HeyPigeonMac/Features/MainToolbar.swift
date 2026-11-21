// The window's toolbar: a real, unified macOS toolbar, so the traffic
// lights sit where every Mac app has them and behave as they do. At the
// leading end, over the list column (past the sidebar when it is out:
// SidebarInset), the three places the phone has as tabs — Inbox · Remind
// me · Need reply — with their counts, the shown one an ink capsule
// (another folder picked in the sidebar shows its name after them, and so
// do Settings and the Bundles page); at the trailing end summarize, ask
// and search on the toolbar's glass, then New message alone at the far
// end: the window's one ink action, an ink circle, unless something else
// on screen is the ink action (`composeIsInk`). The sidebar button is the
// glass circle in the window's bottom corner (MainWindow), Settings is in
// the app menu (⌘,). A page over the list (a thread; a bundle or an email
// on the Bundles page) gets the window's own Back as the first item over
// the content column — the stack's sat beside the traffic lights, over the
// sidebar — and, but for a thread, its name after the tabs; the shared
// view's items (the thread's sparkle and actions menu) join at the
// trailing end. While the search or the command palette floats over the
// window the bar is left empty, so nothing stands over the dim but the
// panel.

import SwiftUI

struct MainToolbar: ToolbarContent {
    @Bindable var state: WindowState
    let model: AppModel

    /// The panels float over the window: the bar stays out of the way.
    private var overlaid: Bool { state.searching || state.showPalette }

    /// The view when it is none of the three tabs (a folder, a label,
    /// Settings, the Bundles page, a search), for the title after them.
    /// An open thread has none: its subject heads the reading column and
    /// every message names its sender, so the people's names up here
    /// said it a third time, in the heaviest type of the window.
    private var otherTitle: String? {
        if state.showSettings { return state.settingsPath.last?.title ?? "Settings" }
        if state.openThread != nil { return nil }
        if state.showBundles { return state.bundlesTitle(in: model) }
        if model.isSearching { return "Search" }
        return ViewTabs.views.contains(model.view) ? nil : model.view.title
    }

    /// New message is drawn in ink while nothing else on screen is the
    /// ink action: an open thread and a row opened in place end with
    /// their own ink Reply, and the composer has Send. One ink action a
    /// screen (docs/specs/marker-look.md, R8).
    private var composeIsInk: Bool {
        if state.isThreadOpen || model.composeDraft != nil { return false }
        // A row open in the list is out of sight under Settings.
        return state.showSettings || state.expanded == nil
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
                        .font(Theme.sans(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .accessibilityAddTraits(.isHeader)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            ToolbarSpacer(.flexible)
            ToolbarItemGroup {
                // No network: say so, with what is waiting to be sent.
                if !Connectivity.shared.isOnline {
                    // The words in the app's face, the glyph in the system's.
                    Label {
                        Text(model.queuedChanges > 0 ? "Offline · \(model.queuedChanges) to send" : "Offline")
                            .font(Theme.sans(size: 12, weight: .medium))
                    } icon: {
                        Image(systemName: "wifi.slash").font(.system(size: 12, weight: .medium))
                    }
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .help("No network. What you do is kept and sent when it is back.")
                }
                // Something could not be sent for good: the Outbox.
                if model.failedChanges > 0 {
                    Button { model.openOutbox() } label: {
                        Label("\(model.failedChanges) not sent", systemImage: "exclamationmark.triangle")
                            .labelStyle(.titleAndIcon)
                    }
                    .help("Changes that could not be sent. Review them in the Outbox.")
                }
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
                Button { state.run(.search, in: model) } label: { Label("Search", systemImage: "magnifyingglass") }
                    .help("Search (/)")
            }
            // New message, an item of its own after the glass group and a
            // little apart from it (the spacer keeps the toolbar from
            // putting the two on one piece of glass): an ink circle that
            // the toolbar puts no glass behind, or — when something else
            // is the screen's ink action — the system's plain glass
            // button like its neighbours.
            ToolbarSpacer(.fixed)
            ToolbarItem {
                if composeIsInk {
                    Button { model.compose(SendDraft()) } label: { Label("New message", systemImage: "square.and.pencil") }
                        .buttonStyle(InkCircleButtonStyle())
                        .help("New message (⌘N)")
                } else {
                    Button { model.compose(SendDraft()) } label: { Label("New message", systemImage: "square.and.pencil") }
                        .help("New message (⌘N)")
                }
            }
            .sharedBackgroundVisibility(composeIsInk ? .hidden : .automatic)
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

/// Inbox · Remind me · Need reply, the phone's tabs, as one switcher on
/// the toolbar's glass: the shown one an ink capsule, a count in the mono
/// beside each (Remind me's due count in the reminder's lavender).
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
        let badge = count(view)
        return TabPill(title: view.title, count: badge?.number, countColor: badge?.color ?? Theme.textTertiary, on: on) {
            state.run(.go(view), in: model)
        }
    }

    /// The count beside a tab and its colour (Remind me's due count in
    /// the reminder's colour); none when there is nothing to count.
    private func count(_ view: MailView) -> (number: Int, color: Color)? {
        switch view {
        case .inbox:
            let n = model.engineUnread(accountId: model.selectedAccountId)
            return n > 0 ? (number: n, color: Theme.textTertiary) : nil
        case .scheduled:
            if model.dueCount > 0 { return (number: model.dueCount, color: Theme.state(.lavender)) }
            return model.scheduledCount > 0 ? (number: model.scheduledCount, color: Theme.textTertiary) : nil
        case .needReply:
            return model.needReplyCount > 0 ? (number: model.needReplyCount, color: Theme.textTertiary) : nil
        default:
            return nil
        }
    }
}
