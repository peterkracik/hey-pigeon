// ⌘K: the desktop's command palette. One field, every command and folder
// filtered as you type, arrows to pick, Return to run — in the search's
// Spotlight panel (SpotlightPanel) over the blurred window, not a sheet. `l` and `v` open
// it pre-staged on the label and move pickers for the selected thread; ⌘B
// (or the Bundles… row) on the bundles stage, the recently active ones
// first, where one opens as the Bundles page. The filter is a pure
// function (PaletteFilter) so it can be tested.

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

    /// How well an item answers the query, 0 best, nil not at all: the
    /// title starts with it; every word starts a word of the title; every
    /// word is in the title; in the title or the subtitle; or the query is
    /// the title's initials ("gti" for "Go to Inbox", "mu" for "Mark
    /// unread").
    static func score(_ query: String, title: String, subtitle: String? = nil) -> Int? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        let t = title.lowercased()
        if t.hasPrefix(q) { return 0 }
        let titleWords = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if matches(q, title: title) {
            let words = q.split(whereSeparator: \.isWhitespace)
            return words.allSatisfy { w in titleWords.contains { $0.hasPrefix(w) } } ? 1 : 2
        }
        if matches(q, title: title, subtitle: subtitle) { return 3 }
        let initials = String(titleWords.compactMap(\.first))
        if q.count >= 2, !q.contains(" "), initials.hasPrefix(q) { return 4 }
        return nil
    }

    /// The items that answer the query, the best first; equally good ones
    /// keep their order, the ones in `recents` (ids, newest first) ahead of
    /// the rest. An empty query keeps everything, recents first.
    static func filter(_ items: [PaletteItem], query: String, recents: [String] = []) -> [PaletteItem] {
        let recency = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let ranked = items.enumerated().compactMap { index, item -> (item: PaletteItem, score: Int, recent: Int, index: Int)? in
            guard let rank = Self.score(query, title: item.title, subtitle: item.subtitle) else { return nil }
            return (item, rank, recency[item.id] ?? Int.max, index)
        }
        return ranked.sorted { a, b in
            if a.score != b.score { return a.score < b.score }
            if a.recent != b.recent { return a.recent < b.recent }
            return a.index < b.index
        }.map(\.item)
    }
}

/// The palette rows run lately, newest first, on this Mac: an empty
/// palette opens on them, and they win a tie as the query is typed.
enum PaletteRecents {
    static let key = "paletteRecents"
    static let limit = 8

    static func load(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    /// `id` to the front. Rows about one thread or one search result are
    /// not habits: they are left out.
    static func remember(_ id: String, _ defaults: UserDefaults = .standard) {
        guard !["hit.", "person.", "label.", "move.", "scheduled."].contains(where: { id.hasPrefix($0) }) else { return }
        defaults.set(pushed(id, onto: load(defaults)), forKey: key)
    }

    /// Pure, for the tests.
    static func pushed(_ id: String, onto list: [String]) -> [String] {
        Array(([id] + list.filter { $0 != id }).prefix(limit))
    }
}

struct CommandPalette: View {
    @Bindable var state: WindowState
    let stage: PaletteStage
    @Environment(AppModel.self) private var model
    @AppStorage(MacWindows.readingPaneKey) private var readingPane = false
    @State private var query = ""
    @State private var cursor = 0
    @FocusState private var focused: Bool

    /// Threads the typed words find, and the people they name: the
    /// palette is also the quickest way to a thread or to someone's mail.
    @State private var hits: [ThreadRow] = []
    @State private var people: [PersonSuggestion] = []
    @State private var recents = PaletteRecents.load()

    private var items: [PaletteItem] {
        PaletteFilter.filter(allItems, query: query, recents: stage == .all ? recents : []) + resultItems
    }

    /// Below the commands: up to three people and five threads for the
    /// typed words (the whole palette only, two letters or more).
    private var resultItems: [PaletteItem] {
        guard stage == .all, query.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let named = people.filter { $0.person.name.lowercased().contains(q) || $0.person.address.lowercased().contains(q) }.prefix(3)
        var out = named.map { p in
            PaletteItem(id: "person.\(p.person.address)", title: "Mail from \(p.person.name)", subtitle: p.person.address,
                        systemImage: "person.crop.circle") {
                // The list, with this person's mail in it.
                state.showSettings = false
                if state.showBundles { state.closeBundles() }
                state.path = []
                var filters = SearchFilters()
                filters.from = p.person
                model.searchText = ""
                model.searchFilters = filters
                model.rememberSearch()
            }
        }
        out += hits.prefix(5).map { row in
            PaletteItem(id: "hit.\(row.id)", title: row.subject.isEmpty ? "(no subject)" : row.subject,
                        subtitle: "\(row.fromSummary) · \(Formatters.rowTime(row.lastMessageAt))", systemImage: "envelope") {
                state.open(row, in: model)
            }
        }
        return out
    }

    private var placeholder: String {
        switch stage {
        case .all: "Type a command or a folder…"
        case .label: "Add or remove a label…"
        case .move: "Move to folder…"
        case .bundles: "Open a bundle…"
        }
    }

    private var stageImage: String {
        switch stage {
        case .all: "command"
        case .label: "tag"
        case .move: "folder"
        case .bundles: "square.stack"
        }
    }

    var body: some View {
        SpotlightPanel(onClose: { close() }) { panel }
            .onAppear { focused = true }
            .onChange(of: query) { _, _ in cursor = 0 }
            // The typed words as a search, a moment after the last key,
            // off the main thread; the newest query wins.
            .task(id: query) {
                let words = query.trimmingCharacters(in: .whitespaces)
                guard stage == .all, words.count >= 2 else {
                    if !hits.isEmpty { hits = [] }
                    return
                }
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                let rows = await model.engine.searchInBackground(words, limit: 5)
                if !Task.isCancelled { hits = AppModel.unique(rows) }
            }
            // The people to offer, once per palette, read off the main thread.
            .task {
                guard stage == .all else { return }
                let mine = Set(model.accounts.map { $0.email.lowercased() })
                let rows = try? await model.engine.readInBackground { store in
                    try store.threads(in: .all, accountId: nil, before: nil, limit: 500)
                }
                if let rows, !Task.isCancelled { people = AppModel.people(from: rows, excluding: mine) }
            }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: stageImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($focused)
                    .onSubmit { runCursor() }
                    .onExitCommand { close() }
                    .onKeyPress(.upArrow) { cursor = max(0, cursor - 1); return .handled }
                    .onKeyPress(.downArrow) { cursor = min(max(0, items.count - 1), cursor + 1); return .handled }
            }
            .padding(.horizontal, 20)
            .frame(height: 60)
            Hairline().opacity(0.6)
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
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(index == cursor ? MacTheme.selected : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                .scrollIndicators(.never)
                .frame(maxHeight: 400)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: cursor) { _, i in
                    if items.indices.contains(i) { proxy.scrollTo(items[i].id) }
                }
            }
        }
    }

    /// The panel goes and the list takes the keys back.
    private func close() {
        state.showPalette = false
        state.listFocusRequest += 1
    }

    private func runCursor() {
        guard items.indices.contains(cursor) else { return }
        run(items[cursor])
    }

    private func run(_ item: PaletteItem) {
        PaletteRecents.remember(item.id)
        close()
        item.run()
    }

    // MARK: Items

    private var allItems: [PaletteItem] {
        let row = state.focusRow(in: model)
        switch stage {
        case .label: return row.map { labelItems(for: $0) } ?? []
        case .move: return row.map { moveItems(for: $0) } ?? []
        case .bundles: return bundleItems
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
                ("Print or save as PDF…", "printer", "⌘P", .print),
                ("Delete", "trash", "#", .delete),
            ]
            // The app's own rules: mute the thread, block its sender.
            if model.isMuted(row) {
                out.append(PaletteItem(id: "thread.unmute", title: "Unmute", subtitle: row.subject, systemImage: "bell") {
                    model.unmute(threadId: row.id)
                })
            } else {
                out.append(PaletteItem(id: "thread.mute", title: "Mute", subtitle: row.subject, systemImage: "bell.slash") {
                    state.advance(in: model)
                    model.mute(row)
                })
            }
            if !row.lastFromAddress.isEmpty, !model.isBlocked(row.lastFromAddress) {
                out.append(PaletteItem(id: "thread.block", title: "Block \(row.lastFromAddress)", subtitle: row.subject,
                                       systemImage: "hand.raised.slash") {
                    state.advance(in: model)
                    model.block(sender: row.lastFromAddress, row: row)
                })
            }
            // Report spam, or the way back out of Spam and Trash.
            switch model.view {
            case .spam:
                out.append(PaletteItem(id: "thread.notspam", title: "Not spam", subtitle: row.subject, systemImage: "tray.and.arrow.down") {
                    state.advance(in: model)
                    model.markNotSpam(row)
                })
            case .trash:
                out.append(PaletteItem(id: "thread.untrash", title: "Move to inbox", subtitle: row.subject, systemImage: "tray.and.arrow.down") {
                    state.advance(in: model)
                    model.untrash(row)
                })
            default:
                out.append(PaletteItem(id: "thread.spam", title: "Report spam", subtitle: row.subject, systemImage: "xmark.bin") {
                    state.advance(in: model)
                    model.markSpam(row)
                })
            }
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
        // A new message that starts from a snippet, and what is waiting to
        // be sent later (picking one puts it back in the composer).
        for snippet in model.snippets {
            out.append(PaletteItem(id: "snippet.\(snippet.id)", title: "New message · \(snippet.name)", subtitle: snippet.body,
                                   systemImage: "text.quote") {
                var draft = SendDraft()
                draft.bodyText = snippet.body
                model.compose(draft)
            })
        }
        for send in model.scheduledSends {
            let subject = send.draft.subject.isEmpty ? "(no subject)" : send.draft.subject
            out.append(PaletteItem(id: "scheduled.\(send.id)", title: "Scheduled · \(subject)",
                                   subtitle: "Sends \(Formatters.reminder(send.at)) — pick to edit or cancel", systemImage: "clock") {
                model.cancelScheduledSend(send.id, reopen: true)
            })
        }
        out.append(PaletteItem(id: "search", title: "Search", systemImage: "magnifyingglass", key: "/") {
            state.run(.search, in: model)
        })
        out.append(PaletteItem(id: "sidebar", title: state.sidebarVisible ? "Hide folders" : "Show folders",
                               systemImage: "sidebar.leading", key: "⌘S") {
            state.run(.toggleSidebar, in: model)
        })
        out.append(PaletteItem(id: "pane", title: readingPane ? "Hide the reading pane" : "Show the reading pane",
                               subtitle: "The open thread beside the list, on a wide window",
                               systemImage: "rectangle.split.2x1", key: "⌥⌘P") {
            readingPane.toggle()
        })
        if state.isThreadOpen {
            out.append(PaletteItem(id: "back", title: "Back to the list", systemImage: "chevron.left", key: "Esc") {
                state.run(.back, in: model)
            })
        }
        out.append(PaletteItem(id: "stage.bundles", title: "Bundles…", subtitle: bundlesSubtitle,
                               systemImage: "square.stack", key: "⌘B") {
            state.paletteStage = .bundles
            state.showPalette = true
        })
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
        if model.canUndoLast {
            out.append(PaletteItem(id: "undo", title: "Undo the last action", systemImage: "arrow.uturn.backward", key: "Z") {
                state.run(.undo, in: model)
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

    /// The Bundles… row's second line: the newest bundles by name.
    private var bundlesSubtitle: String? {
        let names = recentBundles.prefix(3).map(\.name)
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }

    /// The active bundles, most recently active first (the sidebar's
    /// order, with nothing folded or hidden).
    private var recentBundles: [BundleItem] {
        AppModel.sidebarBundles(model.activeBundles, hidden: [], expanded: true).shown
    }

    /// ⌘B: every active bundle, the recent ones first, then the list of
    /// them all; one opens as the Bundles page (WindowState.openBundles).
    private var bundleItems: [PaletteItem] {
        var out = recentBundles.map { b in
            PaletteItem(id: "bundle.\(b.id)", title: b.name, subtitle: Self.bundleSubtitle(b),
                        systemImage: b.category.systemImage) {
                state.openBundles(at: b.id)
            }
        }
        out.append(PaletteItem(id: "bundle.all", title: model.activeBundles.isEmpty ? "Bundles" : "All bundles",
                               subtitle: model.activeBundles.isEmpty ? "No bundles yet" : nil,
                               systemImage: "square.stack") {
            state.openBundles(at: nil)
        })
        return out
    }

    /// "Trip · 3 open · 2 days ago": the category, what is still in the
    /// inbox, and when it last moved. Pure, for the tests.
    static func bundleSubtitle(_ b: BundleItem, now: Date = .now) -> String {
        var parts = [b.category.title]
        if b.openCount > 0 { parts.append("\(b.openCount) open") }
        if let at = b.lastActivityAt { parts.append(Formatters.rowTime(at, now: now)) }
        return parts.joined(separator: " · ")
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
