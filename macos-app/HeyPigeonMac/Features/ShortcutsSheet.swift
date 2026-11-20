// `?` / ⌘/: the keyboard map on one sheet — the desktop's cheat sheet. The
// bare keys work when the list or the thread has the focus (not in a text
// field); the ⌘ equivalents are in the menus and work everywhere. Each
// group stands under its light grey title, its rows ruled, every key a
// keycap (`KeyCaps`).

import SwiftUI

struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Not private: the tests check every bare key listed here against
    /// the keyboard map, and the map's keys against this list, so the two
    /// cannot drift apart.
    static let groups: [(String, [(String, String)])] = [
        ("Move", [
            ("J · K", "Next · previous thread (in a thread too)"), ("Space", "Preview the row in place; in a thread, page down (⇧Space up)"),
            ("⇧J · ⇧K · X", "Add the next · previous row to the selection"), ("⌘A", "Select every row"),
            ("↩", "Open the thread"), ("⌘↩", "Open it in a new window"),
            ("Esc · ⌘[", "Back to the list; then leave the search; then clear the selection"),
            ("/", "Search"), ("⌘S", "Show or hide the folders"), ("⌥⌘P", "Reading pane: the thread beside the list"), ("⌘K", "Command palette"), ("⌘B", "Open a bundle"),
            ("?", "This sheet"),
        ]),
        ("Act on a thread", [
            ("E", "Mark done (and back)"), ("H", "Remind me (or remove the reminder)"), ("N", "Need reply"),
            ("S", "Pin"), ("U", "Read / unread"), ("# · ⌫", "Delete"), ("L", "Add label"), ("V", "Move to folder"),
            ("I", "Summarize the thread"), ("Z · ⌘Z", "Undo the last action"), ("⌘P", "Print, or save as PDF"),
        ]),
        ("Write", [
            ("C · ⌘N", "New message"), ("R", "Reply"), ("A", "Reply all"), ("F", "Forward"),
        ]),
        ("In the composer", [
            ("⌘↩", "Send"), ("⌘J", "Write or edit with AI"), ("Esc", "Close the AI panel; then close and keep the draft"),
            ("⌘B · ⌘I · ⌘U", "Bold · italic · underline"), ("⇧⌘X", "Strikethrough"), ("⌘K", "Link"),
            ("⇧⌘8 · ⇧⌘7", "Bulleted · numbered list"), ("↩ · ⇧↩", "New paragraph (with air) · line break (without)"),
        ]),
        ("Go", [
            ("G then I", "Inbox"), ("G then S", "Remind me"), ("G then N", "Need reply"), ("G then P", "Pinned"),
            ("G then D", "Drafts"), ("G then T", "Sent"), ("G then A", "Archive"), ("G then O", "Recent Opens"),
            ("0 · 1 · 2", "All accounts · the first · the second"), ("⌘1 … ⌘8", "The folders, in the sidebar's order"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard").font(Theme.display(24, relativeTo: .title2)).tracking(-0.4)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                // The sheet's close: an outlined circle, as every button
                // that is not the screen's ink action is outlined.
                Button(role: .close) { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().strokeBorder(Theme.textPrimary, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Self.groups, id: \.0) { title, rows in
                        VStack(alignment: .leading, spacing: 0) {
                            SectionTitle(title).padding(.bottom, 2)
                            ForEach(Array(rows.enumerated()), id: \.element.0) { index, row in
                                ShortcutRow(keys: row.0, what: row.1, isLast: index == rows.count - 1)
                            }
                        }
                    }
                    Text("The letters work while the list or the thread has the keyboard, never inside a text field. Every action is also in the Message and Go menus, with ⌘ shortcuts.")
                        .font(Theme.sans(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
        .frame(width: 520, height: 640)
        .background(Theme.raised)
    }
}

/// One shortcut: its keys as caps in a fixed column, what they do beside
/// them, a hairline under the row (but for a group's last).
private struct ShortcutRow: View {
    let keys: String
    let what: String
    var isLast = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            KeyCaps(keys: keys, ink: Theme.textPrimary)
                .frame(width: 120, alignment: .leading)
            Text(what)
                .font(Theme.sans(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            if !isLast { RowRule() }
        }
    }
}
