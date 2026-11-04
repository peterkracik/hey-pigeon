// The open thread ("Open full thread ›", Return), in the list's place,
// under the top bar (which shows back, the people as a title menu with the
// thread's actions, the AI sparkle and Open in New Window): the phone's
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

/// The thread's actions in the desktop's words, each through the window so
/// the next thread follows an action that takes this one out of the list.
struct ThreadMenu: View {
    let row: ThreadRow
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model

    var body: some View {
        item(row.isDone ? "Mark not done" : "Mark done", row.isDone ? "arrow.uturn.backward" : "checkmark", .markDone)
        item(row.scheduledAt == nil ? "Remind me" : "Remove reminder", "clock", .remind)
        item(row.needsReply ? "Clear need reply" : "Need reply", "arrowshape.turn.up.left", .needReply)
        item(row.isPinned ? "Unpin" : "Pin", row.isPinned ? "pin.slash" : "pin", .pin)
        item(row.isRead ? "Mark unread" : "Mark read", row.isRead ? "envelope.badge" : "envelope.open", .toggleRead)
        Divider()
        item("Add label…", "tag", .label)
        item("Move to folder…", "folder", .move)
        // A sheet of its own (AddToBundleSheet); nothing for the window to advance.
        Button { model.pendingBundlePick = row } label: {
            Label(row.bundleId == nil ? "Add to bundle…" : "Move to bundle…", systemImage: "square.stack")
        }
        item("Forward", "arrowshape.turn.up.right", .forward)
        Divider()
        item("Open in New Window", "macwindow", .openInWindow)
        Button(role: .destructive) { state.run(.delete, in: model) } label: { Label("Delete", systemImage: "trash") }
    }

    private func item(_ title: String, _ systemImage: String, _ command: MailCommand) -> some View {
        Button { state.run(command, in: model) } label: { Label(title, systemImage: systemImage) }
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
