// The list with a hardware keyboard (an iPad's, mostly): j / k move a
// cursor down and up the rows, Return opens the row under it, and the
// Mac's keys act on it — e Mark done, h Remind me, n Need reply, s Pin,
// u Mark read / unread, ⌘⌫ Delete (`RowAction.key`, the map the Mac
// window and the thread's bar already use). The same model calls as the
// swipes, so Undo and the toast are the same.
//
// The keys are key equivalents on buttons nobody sees, as the thread's
// bar has them (`threadKey`: the iPad only; the Mac's list runs its keys
// through its window's key map). Touch is untouched: the cursor exists
// only once a key has moved it, and a tap never sets it.

import SwiftUI

/// Where the list's keyboard cursor goes. Pure, so it is tested.
enum ListCursor {
    /// j / k: the neighbour, clamped at the ends; from nothing, the first
    /// row going down and the last going up (the Mac's `WindowState.move`).
    static func moved(from current: String?, by delta: Int, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return delta > 0 ? ids.first : ids.last
        }
        return ids[min(max(index + delta, 0), ids.count - 1)]
    }

    /// The row that takes the cursor when the one under it leaves the
    /// list (done, deleted): the next one, or the one before the last.
    static func after(removing id: String, in ids: [String]) -> String? {
        guard let index = ids.firstIndex(of: id) else { return nil }
        if index + 1 < ids.count { return ids[index + 1] }
        return index > 0 ? ids[index - 1] : nil
    }
}

/// The keys themselves: invisible buttons behind the list.
struct ListKeys: View {
    @Binding var cursor: String?
    /// Off while the list is not what the keys would act on: another tab,
    /// a thread pushed over it (its bar has the same letters), a sheet up.
    let isOn: Bool
    /// Return: open the row as a tap does.
    let open: (ThreadRow) -> Void
    @Environment(AppModel.self) private var model

    /// The actions with a bare letter, in the Mac's order.
    private static let lettered: [RowAction] = [.done, .remind, .needReply, .pin, .read]

    private var row: ThreadRow? {
        guard let cursor, model.listIndex(of: cursor) != nil else { return nil }
        return model.row(forThreadId: cursor)
    }

    var body: some View {
        ZStack {
            Button("Next thread") { move(1) }.threadKey("j")
            Button("Previous thread") { move(-1) }.threadKey("k")
            Button("Open thread") { if let row { open(row) } }.threadKey(.return)
            ForEach(Self.lettered) { action in
                if let letter = action.key.lowercased().first {
                    Button(action.title) { act(action) }.threadKey(KeyEquivalent(letter))
                }
            }
            Button(RowAction.delete.title) { act(.delete) }.threadKey(.delete, modifiers: .command)
        }
        .disabled(!isOn)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func move(_ delta: Int) {
        cursor = ListCursor.moved(from: cursor, by: delta, in: model.flatRowIds)
    }

    /// What the swipe would do to the row under the cursor
    /// (`AppModel.run`). Done and Delete take the row out of the list:
    /// the cursor goes to the row that takes its place.
    private func act(_ action: RowAction) {
        guard let row else { return }
        if action == .done || action == .delete {
            cursor = ListCursor.after(removing: row.id, in: model.flatRowIds)
        }
        model.run(action, on: row)
    }
}
