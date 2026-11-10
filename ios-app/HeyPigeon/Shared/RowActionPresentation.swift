// How a row action reads and looks, in one place: the words, the glyph
// and the colour the phone's swipe panels, the long-press menu, the
// thread's bar, the Mac's hover bar, its trackpad swipes and the command
// palette all show. Each of them used to spell its own, and they drifted
// ("Done" here, "Mark done" there; the same three colours as hex in four
// files). The vocabulary is the desktop's: Mark done, Remind me, Need
// reply, Pin, Mark read / unread, Delete.

import SwiftUI

extension RowAction {
    /// What running the action on this row does, in full: a menu item, a
    /// tooltip, a palette row, VoiceOver. It follows `AppModel.run(_:on:)`,
    /// so a thread that has a reminder says "Remove reminder" (the swipe
    /// and the key take it off; `remindSheetLabel` is the sheet's).
    func label(for row: ThreadRow) -> String {
        switch self {
        case .done: row.isDone ? "Mark not done" : "Mark done"
        case .delete: "Delete"
        case .remind: row.scheduledAt == nil ? "Remind me" : "Remove reminder"
        case .needReply: row.needsReply ? "Clear need reply" : "Need reply"
        case .pin: row.isPinned ? "Unpin" : "Pin"
        case .read: row.isRead ? "Mark unread" : "Mark read"
        }
    }

    /// The same in the fewest words, for the line under a swipe panel's
    /// icon, which is as narrow as the short swipe.
    func shortLabel(for row: ThreadRow) -> String {
        switch self {
        case .done: row.isDone ? "Not done" : "Done"
        case .delete: "Delete"
        case .remind: row.scheduledAt == nil ? "Remind me" : "Remove reminder"
        case .needReply: row.needsReply ? "Clear reply" : "Need reply"
        case .pin: row.isPinned ? "Unpin" : "Pin"
        case .read: row.isRead ? "Unread" : "Read"
        }
    }

    /// The symbol for what the action does to this row now.
    func glyph(for row: ThreadRow) -> String {
        switch self {
        case .done: row.isDone ? "arrow.uturn.backward" : "checkmark"
        case .delete: "trash"
        case .remind: row.scheduledAt == nil ? "clock" : "clock.badge.xmark"
        case .needReply: "arrowshape.turn.up.left"
        case .pin: row.isPinned ? "pin.slash" : "pin"
        case .read: row.isRead ? "envelope.badge" : "envelope.open"
        }
    }

    /// The swipe panel's colour, on the phone and under the Mac's trackpad
    /// swipe: the accent for the "done" moment, the tag colours for the
    /// rest. White text sits on every one of them.
    var tint: Color {
        switch self {
        case .done: Theme.accent
        case .delete: Theme.danger
        case .remind: Theme.navy700
        case .needReply: Theme.needReply
        case .pin: Theme.pinStrong
        case .read: Theme.navy500
        }
    }

    /// The bare key that runs it: the Mac's key map, its shortcuts sheet
    /// and tooltips, and the iPad's list with a hardware keyboard
    /// (Features/Inbox/ListKeys.swift).
    var key: String {
        switch self {
        case .done: "E"
        case .delete: "#"
        case .remind: "H"
        case .needReply: "N"
        case .pin: "S"
        case .read: "U"
        }
    }

    /// The item that opens the Remind sheet (the long-press menu, the
    /// thread's bar and its More menu), where a set reminder is changed,
    /// not removed.
    static func remindSheetLabel(for row: ThreadRow) -> String {
        row.scheduledAt == nil ? "Remind me" : "Change reminder"
    }
}
