// `?` / ⌘/: the keyboard map on one sheet — the desktop's cheat sheet. The
// bare keys work when the list or the thread has the focus (not in a text
// field); the ⌘ equivalents are in the menus and work everywhere.

import SwiftUI

struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private static let groups: [(String, [(String, String)])] = [
        ("Move", [
            ("J · K", "Next · previous thread"), ("↩", "Open in a new window"), ("Esc", "Clear the selection or the search"),
            ("/", "Search"), ("⌘K", "Command palette"), ("?", "This sheet"),
        ]),
        ("Act on a thread", [
            ("E", "Mark done (and back)"), ("H", "Remind me (or remove the reminder)"), ("N", "Need reply"),
            ("S", "Pin"), ("U", "Read / unread"), ("# · ⌫", "Delete"), ("L", "Add label"), ("V", "Move to folder"),
            ("I", "Summarize the thread"),
        ]),
        ("Write", [
            ("C · ⌘N", "New message"), ("R", "Reply"), ("A", "Reply all"), ("F", "Forward"),
        ]),
        ("Go", [
            ("G then I", "Inbox"), ("G then S", "Scheduled"), ("G then N", "Need reply"), ("G then P", "Pinned (Starred)"),
            ("G then D", "Drafts"), ("G then T", "Sent"), ("G then A", "Archive"),
            ("0 · 1 · 2", "All accounts · the first · the second"), ("⌘1 … ⌘8", "The folders, in the sidebar's order"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard").font(Theme.display(22, relativeTo: .title2)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(role: .close) { dismiss() }
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Self.groups, id: \.0) { title, rows in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title).font(Theme.display(13, relativeTo: .caption)).foregroundStyle(Theme.textTertiary)
                            ForEach(rows, id: \.0) { key, what in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(key)
                                        .font(.subheadline.weight(.semibold).monospaced())
                                        .foregroundStyle(Theme.textPrimary)
                                        .frame(width: 120, alignment: .leading)
                                    Text(what).font(.subheadline).foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                        .padding(14)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    Text("The letters work while the list or the thread has the keyboard, never inside a text field. Every action is also in the Message and Go menus, with ⌘ shortcuts.")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
        .frame(width: 520, height: 640)
        .background(Theme.canvas)
    }
}
