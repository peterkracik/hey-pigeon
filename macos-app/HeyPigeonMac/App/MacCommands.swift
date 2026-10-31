// The menu bar: the desktop's actions as Mac menu commands, with ⌘-based
// equivalents (Apple Mail's where it has one: ⌘R reply, ⇧⌘R reply all,
// ⇧⌘F forward, ⇧⌘U read/unread, ⇧⌘L pin — Mail's flag). The bare-letter
// map (e · h · n · s · u · j · k …) is handled by the focused window
// (WindowState.handle) rather than the menu, because a single-letter menu
// key equivalent would steal the letter from every text field.
//
// Thread commands act on the key window's selection through the focused
// scene value; they are disabled while nothing is selected.

import AppKit
import SwiftUI

struct MacCommands: Commands {
    let model: AppModel
    let updater: MacUpdater
    @FocusedValue(\.windowState) private var state

    private var hasSelection: Bool { !(state?.selection.isEmpty ?? true) }
    private var hasOne: Bool { state?.selection.count == 1 }

    var body: some Commands {
        // Under "About Hey Pigeon", where every Mac app keeps it. Disabled
        // while Sparkle is busy, and in a build without the update key.
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }

        CommandGroup(before: .newItem) {
            Button("New Message") { model.compose(SendDraft()) }
                .keyboardShortcut("n", modifiers: .command)
            Button("Check for Mail") { Task { await model.sync() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
        }

        CommandMenu("Message") {
            Button(selectedDone ? "Mark Not Done" : "Mark Done") { run(.markDone) }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!hasSelection)
            Button("Remind Me…") { run(.remind) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!hasOne)
            Button("Need Reply") { run(.needReply) }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(!hasSelection)
            Button("Pin") { run(.pin) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!hasSelection)
            Button("Mark Read / Unread") { run(.toggleRead) }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(!hasSelection)
            Divider()
            Button("Reply") { run(.reply) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!hasOne)
            Button("Reply All") { run(.replyAll) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!hasOne)
            Button("Forward") { run(.forward) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!hasOne)
            Divider()
            Button("Add Label…") { run(.label) }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(!hasOne)
            Button("Move to Folder…") { run(.move) }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(!hasOne)
            Divider()
            if model.aiConfigured {
                Button("Summarize Thread") { run(.summarizeThread) }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(!hasOne)
                Button("Draft Reply with AI") { run(.draftReply) }
                    .keyboardShortcut("d", modifiers: [.command, .option])
                    .disabled(!hasOne)
                Divider()
            }
            Button("Open in New Window") { run(.openInWindow) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!hasOne)
            Button("Delete") { run(.delete) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!hasSelection)
        }

        CommandMenu("Go") {
            folder("Inbox", .inbox, "1")
            folder("Scheduled", .scheduled, "2")
            folder("Need Reply", .needReply, "3")
            folder("Starred", .starred, "4")
            folder("Drafts", .drafts, "5")
            folder("Sent", .sent, "6")
            folder("Archive", .archive, "7")
            folder("All Emails", .all, "8")
            Divider()
            Button("All Accounts") { run(.account(nil)) }
                .keyboardShortcut("0", modifiers: .control)
            ForEach(Array(model.accounts.prefix(9).enumerated()), id: \.element.id) { index, account in
                Button(account.displayName) { run(.account(index)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
            }
            Divider()
            Button("Search") { run(.search) }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Command Palette") { run(.palette) }
                .keyboardShortcut("k", modifiers: .command)
            Button("Keyboard Shortcuts") { run(.shortcuts) }
                .keyboardShortcut("/", modifiers: .command)
        }

        CommandMenu("Mailbox") {
            Button("Summarize This View") { run(.summarizeView) }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(!model.aiConfigured)
            Button("Ask My Inbox…") { run(.ask) }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!InboxAsk.isAvailable(model))
            Button("Triage Inbox…") { run(.triage) }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!TriageAgent.isAvailable(model))
            Divider()
            Button("Load Older Mail") { Task { _ = try? await model.engine.backfillOlder(); model.reload() } }
        }

        CommandGroup(replacing: .help) {
            Button("Hey Pigeon Help") {
                if let url = URL(string: "https://heypigeon.app") { NSWorkspace.shared.open(url) }
            }
            Button("Keyboard Shortcuts") { run(.shortcuts) }
        }
    }

    private var selectedDone: Bool {
        guard let state, let row = state.selectedRow(in: model) else { return false }
        return row.isDone
    }

    private func folder(_ title: String, _ view: MailView, _ key: Character) -> some View {
        Button(title) { run(.go(view)) }
            .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
    }

    private func run(_ command: MailCommand) {
        state?.run(command, in: model)
    }
}
