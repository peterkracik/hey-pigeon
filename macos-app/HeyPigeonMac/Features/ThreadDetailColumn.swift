// The right column: the phone's thread screen (Features/Thread/ThreadView
// — messages, attachments, the Reply pill and the glass triage bar) for the
// selected thread; a batch bar when several rows are selected; the pigeon
// when nothing is. The thread's "close" (after done, delete, mark unread,
// move) hands the selection to the next row.

import SwiftUI

struct ThreadDetailColumn: View {
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if state.selection.count > 1 {
                BatchView(state: state)
            } else if let row = state.selectedRow(in: model) {
                ThreadView(row: row) { state.advance(in: model) }
                    .id(row.id)
            } else {
                placeholder
            }
        }
        .background(Theme.canvas)
        // Focusable so the key map works after a click in the thread, with
        // no ring drawn around a whole column.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in state.handle(press, model: model) }
    }

    private var placeholder: some View {
        ContentUnavailableView {
            Label(model.groupedRows.isEmpty ? "All clear" : "No thread selected", systemImage: "bird")
                .font(Theme.display(22, relativeTo: .title2))
        } description: {
            Text(model.groupedRows.isEmpty
                 ? "Nothing waits here."
                 : "Pick a thread, or move with J and K. Press ⌘/ for every key.")
        }
    }
}

/// Several rows selected: how many, and the actions that make sense for
/// all of them at once.
private struct BatchView: View {
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model

    private var rows: [ThreadRow] { state.selectedRows(in: model) }

    var body: some View {
        VStack(spacing: 18) {
            Text("\(state.selection.count) threads selected")
                .font(Theme.display(22, relativeTo: .title2))
                .foregroundStyle(Theme.textPrimary)
            Text("Actions apply to all of them, each with its own Undo in the toast.")
                .font(.subheadline).foregroundStyle(Theme.textTertiary)
            HStack(spacing: 10) {
                batch("Mark done", "checkmark", .markDone)
                batch("Read / unread", "envelope.open", .toggleRead)
                batch("Pin", "pin", .pin)
                batch("Need reply", "arrowshape.turn.up.left", .needReply)
                batch("Delete", "trash", .delete)
            }
            .buttonStyle(.glass)
            Button("Clear selection") { state.selection = [] }
                .buttonStyle(.plain)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func batch(_ title: String, _ systemImage: String, _ command: MailCommand) -> some View {
        Button { state.run(command, in: model) } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

/// A thread in its own window (Return, or "Open in New Window").
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
