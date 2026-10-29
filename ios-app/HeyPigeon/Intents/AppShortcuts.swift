// Zero-setup Siri phrases. Only the verbs that make sense with the app
// closed; thread-bound verbs (Done, Remind, Need reply, Pin) reach Siri
// through the open thread, Shortcuts flows and widget buttons instead.
// Every phrase names the app; Siri fills the rest from the intent.

import AppIntents

struct HeyPigeonShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .pink

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WhatNeedsReplyIntent(),
            phrases: [
                "What needs a reply in \(.applicationName)",
                "Who's waiting on me in \(.applicationName)",
                "Show my need reply list in \(.applicationName)",
            ],
            shortTitle: "Need reply",
            systemImageName: "arrowshape.turn.up.left"
        )
        AppShortcut(
            intent: WhatsDueIntent(),
            phrases: [
                "What's due in \(.applicationName)",
                "What's scheduled in \(.applicationName)",
                "Show my reminders in \(.applicationName)",
            ],
            shortTitle: "What's due",
            systemImageName: "clock"
        )
        AppShortcut(
            intent: SummarizeInboxIntent(),
            phrases: [
                "Summarize my inbox in \(.applicationName)",
                "What's new in \(.applicationName)",
                "Catch me up on \(.applicationName)",
            ],
            shortTitle: "Summarize inbox",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: TriageInboxIntent(),
            phrases: [
                "Triage my inbox in \(.applicationName)",
                "Clean up my inbox in \(.applicationName)",
                "Sort my mail in \(.applicationName)",
            ],
            shortTitle: "Triage inbox",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: AskInboxIntent(),
            phrases: [
                "Ask \(.applicationName) \(\.$question)",
                "Ask my inbox in \(.applicationName)",
            ],
            shortTitle: "Ask my inbox",
            systemImageName: "questionmark.bubble"
        )
        AppShortcut(
            intent: SearchMailIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Find an email in \(.applicationName)",
            ],
            shortTitle: "Search mail",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: ComposeIntent(),
            phrases: [
                "Compose in \(.applicationName)",
                "New email in \(.applicationName)",
                "Write an email in \(.applicationName)",
            ],
            shortTitle: "Compose",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: OpenFolderIntent(),
            phrases: [
                "Open \(\.$folder) in \(.applicationName)",
                "Show \(\.$folder) in \(.applicationName)",
            ],
            shortTitle: "Open folder",
            systemImageName: "tray"
        )
        AppShortcut(
            intent: SyncNowIntent(),
            phrases: [
                "Check \(.applicationName)",
                "Check for mail in \(.applicationName)",
            ],
            shortTitle: "Check for mail",
            systemImageName: "arrow.clockwise"
        )
    }
}
