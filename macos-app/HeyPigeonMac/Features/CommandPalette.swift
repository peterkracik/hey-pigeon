// ⌘K: the desktop's command palette. One field, every command and folder
// filtered as you type, arrows to pick, Return to run. `l` and `v` open
// it pre-staged on the label and move pickers for the selected thread.
// The filter is a pure function (PaletteFilter) so it can be tested.

import SwiftUI

/// One row of the palette.
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    var subtitle: String?
    let systemImage: String
    /// The key that does the same without the palette, when there is one.
    var key: String?
    let run: @MainActor () -> Void
}

enum PaletteFilter {
    /// Every word of the query must appear in the title or the subtitle,
    /// without case; an empty query keeps everything.
    static func matches(_ query: String, title: String, subtitle: String? = nil) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = (title + " " + (subtitle ?? "")).lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    static func filter(_ items: [PaletteItem], query: String) -> [PaletteItem] {
        items.filter { matches(query, title: $0.title, subtitle: $0.subtitle) }
    }
}

struct CommandPalette: View {
    @Bindable var state: WindowState
    let stage: PaletteStage
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var cursor = 0
    @FocusState private var focused: Bool

    private var items: [PaletteItem] { PaletteFilter.filter(allItems, query: query) }

    private var placeholder: String {
        switch stage {
        case .all: "Type a command or a folder…"
        case .label: "Add or remove a label…"
        case .move: "Move to folder…"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: stage == .all ? "command" : (stage == .label ? "tag" : "folder"))
                    .foregroundStyle(Theme.textTertiary)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { runCursor() }
                    .onKeyPress(.upArrow) { cursor = max(0, cursor - 1); return .handled }
                    .onKeyPress(.downArrow) { cursor = min(max(0, items.count - 1), cursor + 1); return .handled }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Button { run(item) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: item.systemImage)
                                        .frame(width: 20)
                                        .foregroundStyle(index == cursor ? Theme.textPrimary : Theme.textSecondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title).font(.body.weight(.medium)).foregroundStyle(Theme.textPrimary)
                                        if let s = item.subtitle {
                                            Text(s).font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    if let key = item.key {
                                        Text(key).font(.caption.weight(.semibold).monospaced())
                                            .foregroundStyle(Theme.textTertiary)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                    }
                                }
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(index == cursor ? Theme.sunken : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                            .onHover { if $0 { cursor = index } }
                        }
                        if items.isEmpty {
                            Text("Nothing matches").font(.subheadline).foregroundStyle(Theme.textTertiary).padding(20)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: cursor) { _, i in
                    if items.indices.contains(i) { proxy.scrollTo(items[i].id) }
                }
            }
        }
        .frame(width: 560, height: 440)
        .background(Theme.canvas)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in cursor = 0 }
        .onExitCommand { dismiss() }
    }

    private func runCursor() {
        guard items.indices.contains(cursor) else { return }
        run(items[cursor])
    }

    private func run(_ item: PaletteItem) {
        dismiss()
        item.run()
    }

    // MARK: Items

    private var allItems: [PaletteItem] {
        let row = state.focusRow(in: model)
        switch stage {
        case .label: return row.map { labelItems(for: $0) } ?? []
        case .move: return row.map { moveItems(for: $0) } ?? []
        case .all: break
        }
        var out: [PaletteItem] = []
        if let row {
            let threadItems: [(String, String, String, MailCommand)] = [
                (row.isDone ? "Mark not done" : "Mark done", row.isDone ? "arrow.uturn.backward" : "checkmark", "E", .markDone),
                (row.scheduledAt == nil ? "Remind me" : "Remove reminder", "clock", "H", .remind),
                (row.needsReply ? "Clear need reply" : "Need reply", "arrowshape.turn.up.left", "N", .needReply),
                (row.isPinned ? "Unpin" : "Pin", row.isPinned ? "pin.slash" : "pin", "S", .pin),
                (row.isRead ? "Mark unread" : "Mark read", row.isRead ? "envelope.badge" : "envelope.open", "U", .toggleRead),
                ("Reply", "arrowshape.turn.up.left", "R", .reply),
                ("Reply all", "arrowshape.turn.up.left.2", "A", .replyAll),
                ("Forward", "arrowshape.turn.up.right", "F", .forward),
                ("Open", "arrow.right.circle", "↩", .open),
                ("Open in new window", "macwindow", "⌘↩", .openInWindow),
                ("Delete", "trash", "#", .delete),
            ]
            for (title, image, key, command) in threadItems {
                out.append(PaletteItem(id: "thread.\(command)", title: title, subtitle: row.subject, systemImage: image, key: key) {
                    state.run(command, in: model)
                })
            }
            if !labelItems(for: row).isEmpty {
                out.append(PaletteItem(id: "stage.label", title: "Add label…", subtitle: row.subject, systemImage: "tag", key: "L") {
                    state.paletteStage = .label
                    state.showPalette = true
                })
                out.append(PaletteItem(id: "stage.move", title: "Move to folder…", subtitle: row.subject, systemImage: "folder", key: "V") {
                    state.paletteStage = .move
                    state.showPalette = true
                })
            }
            if !model.triageLabels.isEmpty {
                for label in model.triageLabels {
                    let on = row.triageLabelIds.contains(label.id)
                    out.append(PaletteItem(id: "jev.\(label.id)", title: "\(on ? "Remove" : "Add") Jev label · \(label.name)",
                                           subtitle: row.subject, systemImage: on ? "checkmark" : "sparkles") {
                        var ids = row.triageLabelIds
                        if on { ids.removeAll { $0 == label.id } } else { ids.append(label.id) }
                        model.setTriageLabels(row, ids)
                    })
                }
            }
            if model.aiConfigured {
                out.append(PaletteItem(id: "ai.summarize", title: "Summarize thread", subtitle: row.subject, systemImage: "sparkles", key: "I") {
                    state.run(.summarizeThread, in: model)
                })
                out.append(PaletteItem(id: "ai.draft", title: "Draft a reply with AI", subtitle: row.subject, systemImage: "sparkles") {
                    state.run(.draftReply, in: model)
                })
            }
        }
        out.append(PaletteItem(id: "compose", title: "New message", systemImage: "square.and.pencil", key: "C") {
            state.run(.compose, in: model)
        })
        out.append(PaletteItem(id: "search", title: "Search", systemImage: "magnifyingglass", key: "/") {
            state.run(.search, in: model)
        })
        out.append(PaletteItem(id: "sidebar", title: state.sidebarVisible ? "Hide folders" : "Show folders",
                               systemImage: "sidebar.leading", key: "⌃⌘S") {
            state.run(.toggleSidebar, in: model)
        })
        if state.isThreadOpen {
            out.append(PaletteItem(id: "back", title: "Back to the list", systemImage: "chevron.left", key: "Esc") {
                state.run(.back, in: model)
            })
        }
        let folders: [(MailView, String?)] = [
            (.inbox, "G I"), (.scheduled, "G S"), (.needReply, "G N"), (.starred, "G P"), (.sent, "G T"),
            (.drafts, "G D"), (.archive, "G A"), (.all, nil), (.spam, nil), (.trash, nil),
        ]
        for (view, key) in folders {
            out.append(PaletteItem(id: "go.\(view.countKey)", title: "Go to \(view.title)", systemImage: view.systemImage, key: key) {
                state.run(.go(view), in: model)
            })
        }
        for label in model.labels where !label.id.hasPrefix("CATEGORY_") {
            out.append(PaletteItem(id: "go.label.\(label.accountId).\(label.id)", title: "Go to \(label.name)",
                                   subtitle: model.accounts.count > 1 ? label.accountId : nil, systemImage: "tag") {
                state.run(.go(.label(id: label.id, name: label.name)), in: model)
            })
        }
        if model.accounts.count > 1 {
            out.append(PaletteItem(id: "account.all", title: "All accounts", systemImage: "circle.grid.2x2", key: "0") {
                state.run(.account(nil), in: model)
            })
            for (index, a) in model.accounts.enumerated() {
                out.append(PaletteItem(id: "account.\(a.id)", title: "Switch to \(a.displayName)", subtitle: a.email,
                                       systemImage: "person.crop.circle", key: "\(index + 1)") {
                    state.run(.account(index), in: model)
                })
            }
        }
        if model.aiConfigured {
            out.append(PaletteItem(id: "ai.view", title: "Summarize this view", systemImage: "sparkles", key: "⌥⌘I") {
                state.run(.summarizeView, in: model)
            })
        }
        if InboxAsk.isAvailable(model) {
            out.append(PaletteItem(id: "ai.ask", title: "Ask my inbox", systemImage: "questionmark.bubble", key: "⌥⌘A") {
                state.run(.ask, in: model)
            })
        }
        if TriageAgent.isAvailable(model) {
            out.append(PaletteItem(id: "ai.triage", title: "Triage inbox", systemImage: "sparkles", key: "⌥⌘T") {
                state.run(.triage, in: model)
            })
        }
        out.append(PaletteItem(id: "sync", title: "Check for mail", systemImage: "arrow.clockwise", key: "⇧⌘N") {
            state.run(.syncNow, in: model)
        })
        out.append(PaletteItem(id: "settings", title: "Settings", systemImage: "gearshape", key: "⌘,") {
            model.showSettings = true
        })
        out.append(PaletteItem(id: "keys", title: "Keyboard shortcuts", systemImage: "keyboard", key: "?") {
            state.run(.shortcuts, in: model)
        })
        return out
    }

    private func accountLabels(for row: ThreadRow) -> [MailLabelItem] {
        model.labels.filter { $0.accountId == row.accountId && !$0.id.hasPrefix("CATEGORY_") }
    }

    /// Desktop `l`: add or remove one Gmail label.
    private func labelItems(for row: ThreadRow) -> [PaletteItem] {
        accountLabels(for: row).map { label in
            let on = row.labels.contains(label.id)
            return PaletteItem(id: "label.\(label.id)", title: on ? "Remove \(label.name)" : "Add \(label.name)",
                               subtitle: row.subject, systemImage: on ? "checkmark" : "tag") {
                IntentDonations.labeled(row, label, on: !on, in: model)
                model.setLabel(row, label, on: !on)
            }
        }
    }

    /// Desktop `v`: the label and done.
    private func moveItems(for row: ThreadRow) -> [PaletteItem] {
        accountLabels(for: row).map { label in
            PaletteItem(id: "move.\(label.id)", title: "Move to \(label.name)", subtitle: row.subject, systemImage: "folder") {
                IntentDonations.labeled(row, label, on: true, in: model)
                state.advance(in: model)
                model.move(row, to: label)
            }
        }
    }
}
