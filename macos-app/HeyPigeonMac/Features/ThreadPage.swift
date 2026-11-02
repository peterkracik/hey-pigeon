// The open thread, in the list's place: a title row over a hairline (back
// when the sidebar is away, the people as a title menu with the thread's
// actions, the AI sparkle, Open in New Window) over the phone's thread screen
// (Features/Thread/ThreadView — messages, attachments, the Reply pill and
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

    /// Live from the store: the header's badges follow each action.
    private var current: ThreadRow { model.row(forThreadId: row.id) ?? row }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ThreadView(row: row) { state.closeOpen(in: model) }
                .id(row.id)
                .frame(maxWidth: MacLayout.maxWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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

    /// The title row: the sidebar button when the sidebar is away, back,
    /// the people as a title whose chevron opens the thread's actions, the
    /// AI sparkle.
    private var header: some View {
        HStack(spacing: 4) {
            TrafficLightsGap(state: state)
            if !state.sidebarVisible {
                IconButton("sidebar.leading", help: "Show the sidebar (⌃⌘S)") { state.run(.toggleSidebar, in: model) }
                IconButton("chevron.left", help: "Back to the list (Esc)") { state.run(.back, in: model) }
            }
            TitleMenu { ThreadMenu(row: current, state: state) } label: {
                TitleText(text: current.fromSummary)
            }
            .help("Thread actions")
            .accessibilityLabel("\(current.fromSummary). Thread actions")
            Spacer(minLength: 8)
            if model.aiConfigured {
                IconButton("sparkles", help: "Summarize the thread (I)") { state.run(.summarizeThread, in: model) }
            }
            IconButton("macwindow", help: "Open in New Window (⌘↩)") { state.run(.openInWindow, in: model) }
        }
        .titleRow()
    }
}

/// The thread's actions in the desktop's words, each through the window so
/// the next thread follows an action that takes this one out of the list.
private struct ThreadMenu: View {
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
