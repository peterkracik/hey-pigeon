// The open thread ("Open full thread ›", Return), in the list's place,
// under the window's toolbar (which holds its Back (MainToolbar), with
// the shared ThreadView's sparkle and actions menu; the thread names
// itself, with its subject): the phone's thread screen
// (Features/Thread/ThreadView) in a reading column of its own
// (`MacLayout.readingWidth`, kept by the shared view's `threadColumn`, so
// a thread window and an email on the Bundles page have it too) on the
// paper — the messages one under the other, parted by hairlines, the
// last ending with Reply (the ink pill) · Reply all · Forward, the triage
// buttons on a small paper panel at the bottom. The thread's "close"
// (after done, delete, mark unread, move) hands the window to the next
// thread, or back to the list when there is none. ThreadWindow is the
// same thread in a window of its own (⌘↩).

import SwiftUI

struct ThreadPage: View {
    let row: ThreadRow
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        ThreadView(row: row) { state.closeOpen(in: model) }
            .id(row.id)
            // The stack's own Back sat beside the traffic lights, over the
            // sidebar; the window's toolbar has its own over the content.
            .navigationBarBackButtonHidden(true)
            .scrollIndicators(.never)
            // The column is the thread view's own (`threadColumn`): in
            // the middle of the window, or of the reading pane.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MacTheme.content)
            // Focusable so the key map works after a click in the thread, with
            // no ring drawn around the page.
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(phases: .down) { press in state.handle(press, model: model) }
            .onAppear { focused = true }
            .onChange(of: row.id) { _, _ in focused = true }
    }
}

/// The threads open in windows of their own, for the composer's
/// placement (ComposePlacement): a reply to one is written there, under
/// its messages, and the main window shows no sheet for it.
@MainActor
enum ThreadWindows {
    static var open: Set<String> = []
}

/// A thread in its own window (⌘↩, or "Open in New Window").
struct ThreadWindow: View {
    let threadId: String?
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        if let threadId, let row = model.row(forThreadId: threadId) {
            NavigationStack {
                ThreadView(row: row) { dismissWindow(id: MacWindows.thread, value: threadId) }
                    .scrollIndicators(.never)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(MacTheme.content)
            }
            .frame(minWidth: 540, minHeight: 480)
            .overlay(alignment: .bottom) { ToastStack() }
            .onAppear { ThreadWindows.open.insert(threadId) }
            .onDisappear { ThreadWindows.open.remove(threadId) }
        } else {
            MacEmptyState(title: "This thread is no longer here", systemImage: "envelope.open")
                .frame(minWidth: 540, minHeight: 480)
                .background(MacTheme.content)
        }
    }
}
