// What the widgets show, as the app last left it. Written by the app after
// every reload (WidgetSnapshotWriter) into the App Group, read by the
// widget extension's timeline providers. A snapshot, not the database: the
// widgets never open SQLite or the Keychain.

import Foundation

struct WidgetSnapshot: Codable, Equatable {
    static let file = "widget-snapshot.json"
    static let maxRows = 5

    struct AccountSummary: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        /// AccountColor's raw value ("sky", "coral", …) — WidgetPalette maps it.
        let color: String
        let unread: Int
    }

    struct Row: Codable, Equatable, Identifiable {
        let id: String
        let from: String
        let subject: String
        let snippet: String
        let accountColor: String
        /// The reminder time for a scheduled row, else when the mail arrived.
        let at: Date
        let isFollowUp: Bool
        let isUnread: Bool
    }

    let updatedAt: Date
    let lastSyncAt: Date?
    let unreadTotal: Int
    let accounts: [AccountSummary]
    /// Reminders whose time has come, soonest first.
    let due: [Row]
    /// Reminders still ahead, soonest first.
    let upcoming: [Row]
    /// Threads flagged Need reply, newest first.
    let needReply: [Row]
    let needReplyTotal: Int

    static let empty = WidgetSnapshot(updatedAt: .distantPast, lastSyncAt: nil, unreadTotal: 0, accounts: [],
                                      due: [], upcoming: [], needReply: [], needReplyTotal: 0)

    /// The sample the widget gallery shows.
    static let placeholder = WidgetSnapshot(
        updatedAt: Date(), lastSyncAt: Date(), unreadTotal: 3,
        accounts: [AccountSummary(id: "a", name: "Personal", color: "sky", unread: 1),
                   AccountSummary(id: "b", name: "Work", color: "coral", unread: 2)],
        due: [Row(id: "d1", from: "Ana", subject: "Contract draft v3", snippet: "One open point on the termination clause.",
                  accountColor: "coral", at: Date().addingTimeInterval(-600), isFollowUp: true, isUnread: false)],
        upcoming: [Row(id: "u1", from: "Lufthansa", subject: "Your trip to Lisbon", snippet: "Check-in opens.",
                       accountColor: "sky", at: Date().addingTimeInterval(3 * 3600), isFollowUp: false, isUnread: false)],
        needReply: [Row(id: "n1", from: "Priya Nair", subject: "Q4 roadmap review", snippet: "Can you look at slides 4–7?",
                        accountColor: "coral", at: Date().addingTimeInterval(-1800), isFollowUp: false, isUnread: true)],
        needReplyTotal: 1
    )

    static func load() -> WidgetSnapshot { AppGroup.read(WidgetSnapshot.self, from: file) ?? .empty }
}
