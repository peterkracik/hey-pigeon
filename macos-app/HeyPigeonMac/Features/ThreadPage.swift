// The open thread ("Open full thread ›", Return), in the list's place,
// under the window's toolbar (which names it and holds its Back
// (MainToolbar), with the shared ThreadView's sparkle and actions menu):
// the phone's thread screen (Features/Thread/ThreadView — messages,
// attachments, and the Reply pill and triage buttons on one card at the
// bottom). The thread's "close" (after done, delete, mark
// unread, move) hands the window to the next thread, or back to the list
// when there is none. ThreadWindow is the same thread in a window of its
// own (⌘↩).

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
            .frame(maxWidth: MacLayout.maxWidth)
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
                    .background(Theme.canvas)
            }
            .frame(minWidth: 540, minHeight: 480)
            .overlay(alignment: .bottom) { ToastStack() }
            .onAppear { ThreadWindows.open.insert(threadId) }
            .onDisappear { ThreadWindows.open.remove(threadId) }
        } else {
            ContentUnavailableView("This thread is no longer here", systemImage: "envelope.open")
                .frame(minWidth: 540, minHeight: 480)
        }
    }
}
