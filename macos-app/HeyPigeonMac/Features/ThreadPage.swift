// The open thread ("Open full thread ›", Return), in the list's place,
// under the window's toolbar (where the navigation stack puts Back and the
// shared ThreadView its title, sparkle and actions menu): the phone's
// thread screen (Features/Thread/ThreadView — messages, attachments, the Reply pill and
// the glass triage bar). The thread's "close" (after done, delete, mark
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
            .overlay(alignment: .bottom) { MacToast() }
        } else {
            ContentUnavailableView("This thread is no longer here", systemImage: "envelope.open")
                .frame(minWidth: 540, minHeight: 480)
        }
    }
}
