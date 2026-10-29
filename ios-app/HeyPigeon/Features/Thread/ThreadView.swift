// A thread: the other people's names between the back and action circles,
// subject with one line of chips (priority, Jev labels, reminder, need
// reply — the list's chips) and the message count, messages as the inbox's
// rows (latest expanded, the middle of long threads folded), and two
// floating glass bars at the bottom: the Reply button — tap for the default
// action, chevron for Reply · Reply all · Forward, as in Superhuman — with
// the AI draft circle beside it, and one triage bar in the desktop's words:
// Done · Remind · Need reply · Pin · Delete.

import AppIntents
import SwiftUI

struct ThreadView: View {
    /// NSUserActivity type for the open thread (project.yml NSUserActivityTypes).
    static let activityType = "app.heypigeon.thread"

    let row: ThreadRow
    let onClose: () -> Void
    @Environment(AppModel.self) private var model
    @State private var detail: ThreadDetail?
    @State private var expanded: Set<String> = []
    @State private var allCollapsed = false
    @State private var failed: String?
    @State private var drafting = false
    /// Reply kind picked from the chevron; nil follows the default.
    @State private var replyChoice: ReplyKind?
    @State private var unfolded = false

    /// Live from the store (AppModel.openThread), never the copy this view
    /// was opened with: that one goes stale with the first action.
    private var current: ThreadRow {
        if let open = model.openThread, open.id == row.id { return open }
        return model.rows.first { $0.id == row.id } ?? detail?.thread ?? row
    }

    private var participants: String {
        guard let msgs = detail?.messages else { return row.fromSummary }
        var seen: [String] = []
        for m in msgs where !m.isMine && !seen.contains(m.fromName) { seen.append(m.fromName) }
        return seen.isEmpty ? row.fromSummary : seen.joined(separator: ", ")
    }

    /// Reply all when someone besides the sender is on the last message,
    /// else Reply.
    private var defaultReply: ReplyKind {
        guard let last = detail?.messages.last, !last.isMine else { return .reply }
        return last.to.contains { $0 != "me" && !$0.isEmpty } ? .replyAll : .reply
    }

    private var replyKind: ReplyKind { replyChoice ?? defaultReply }

    private var accountLabels: [MailLabelItem] {
        model.labels.filter { $0.accountId == current.accountId && !$0.id.hasPrefix("CATEGORY_") }
    }

    /// Plain-text transcript, oldest first, "Me" for own messages (AI context).
    private var transcript: String {
        (detail?.messages ?? []).map { "\($0.isMine ? "Me" : $0.fromName): \($0.bodyText ?? $0.snippet)" }.joined(separator: "\n\n")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text(row.subject.isEmpty ? "(no subject)" : row.subject)
                    .font(Theme.display(22, relativeTo: .title2))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 16).padding(.top, 6)

                metaLine.padding(.horizontal, 16).padding(.top, 8)

                if let detail {
                    messageList(detail.messages).padding(.top, 14)
                } else if let failed {
                    ContentUnavailableView("Couldn't load", systemImage: "wifi.exclamationmark", description: Text(failed))
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 150)
        }
        .background(Theme.canvas)
        // The names are the principal item. No .toolbar(removing: .title)
        // here: a plain-text principal counts as the title and went with it.
        .navigationTitle(participants)
        .toolbarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(participants)
                    .font(Theme.display(17, relativeTo: .headline))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
            if model.aiConfigured {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let d = detail { model.openThreadSummary(current, messages: d.messages) }
                    } label: { Image(systemName: "sparkles") }
                    .disabled(detail == nil)
                    .accessibilityLabel("Summarize thread")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { model.togglePin(current) } label: {
                        Label(current.isPinned ? "Unpin" : "Pin", systemImage: current.isPinned ? "pin.slash" : "pin")
                    }
                    Button { model.toggleRead(current); onClose() } label: { Label("Mark unread", systemImage: "envelope.badge") }
                    Button { model.pendingRemind = current } label: {
                        Label(current.scheduledAt == nil ? "Remind me" : "Change reminder", systemImage: "clock")
                    }
                    if !accountLabels.isEmpty {
                        Menu {
                            ForEach(accountLabels) { label in
                                Button { model.move(current, to: label); onClose() } label: { Label(label.name, systemImage: "tray") }
                            }
                        } label: { Label("Move to folder", systemImage: "folder") }
                        Menu {
                            ForEach(accountLabels) { label in
                                let on = current.labels.contains(label.id)
                                Button { model.setLabel(current, label, on: !on) } label: {
                                    Label(on ? "Remove \(label.name)" : label.name, systemImage: on ? "checkmark" : "tag")
                                }
                            }
                        } label: { Label("Add label", systemImage: "tag") }
                    }
                    Button { if let last = detail?.messages.last { forward(last) } } label: {
                        Label("Forward", systemImage: "arrowshape.turn.up.right")
                    }
                    Divider()
                    Button(role: .destructive) { model.delete(current); onClose() } label: { Label("Delete", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("More")
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBars }
        // On-screen awareness: "Hey Siri, remind me about this tomorrow"
        // resolves to this thread (MailThreadQuery.defaultResult is the
        // fallback when Siri cannot read the activity).
        .userActivity(ThreadView.activityType) { activity in
            activity.title = row.subject.isEmpty ? row.fromSummary : row.subject
            activity.appEntityIdentifier = EntityIdentifier(for: MailThreadEntity(current, account: model.account(for: current)))
        }
        .onAppear { model.showThread(row) }
        .onDisappear { model.hideThread(row) }
        .task(id: row.id) {
            do {
                detail = try await model.engine.thread(id: row.id)
                if detail == nil { failed = "This thread is no longer available." }
                else if model.autoSummarize && model.aiConfigured, let d = detail {
                    model.summarizeThread(current, messages: d.messages)
                }
            } catch { failed = error.localizedDescription }
        }
    }

    // MARK: Messages

    /// The messages with 1 pt gaps, as in the list. Long threads fold their
    /// middle into one row: the first message, "N earlier", then the last
    /// two and any unread run before them. Opening a message unfolds.
    private func messageList(_ messages: [MessageItem]) -> some View {
        let lastIndex = messages.count - 1
        var keepFrom = max(lastIndex - 1, 1)
        while keepFrom > 1 && !messages[keepFrom - 1].isRead { keepFrom -= 1 }
        let foldable = !unfolded && keepFrom - 1 >= 2
            && !messages[1..<keepFrom].contains { expanded.contains($0.id) }
        return VStack(spacing: 1) {
            ForEach(Array(messages.enumerated()), id: \.element.id) { index, m in
                if foldable && index > 0 && index < keepFrom {
                    if index == 1 {
                        EarlierRow(count: keepFrom - 1) { withAnimation(.snappy) { unfolded = true } }
                    }
                } else {
                    MessageRow(message: m, expanded: !allCollapsed && (expanded.contains(m.id) || index == lastIndex)) {
                        allCollapsed = false
                        if expanded.contains(m.id) { expanded.remove(m.id) } else { expanded.insert(m.id) }
                    } onAction: { kind in run(kind, on: m) }
                }
            }
        }
        .background(Theme.separator.opacity(0.6))
    }

    // MARK: Header pieces

    /// One line of the list's chips: priority, the Jev labels with a "+"
    /// chip to edit them by hand (sticky until "Reanalyze all emails" in
    /// Settings), the reminder and need-reply badges; then the count.
    private var metaLine: some View {
        let names = current.triageLabelIds.compactMap { id in model.triageLabels.first { $0.id == id } }
        return HStack(spacing: 6) {
            if let p = current.priority { PriorityIndicator(priority: p) }
            ForEach(names) { l in
                Chip(text: l.name, background: Theme.sunken, foreground: Theme.textSecondary)
            }
            if !model.triageLabels.isEmpty {
                Menu {
                    ForEach(model.triageLabels) { label in
                        let on = current.triageLabelIds.contains(label.id)
                        Button {
                            var ids = current.triageLabelIds
                            if on { ids.removeAll { $0 == label.id } } else { ids.append(label.id) }
                            model.setTriageLabels(current, ids)
                        } label: { Label(label.name, systemImage: on ? "checkmark" : "tag") }
                    }
                } label: {
                    Chip(text: names.isEmpty ? "Label" : "", systemImage: "plus",
                         background: Theme.sunken, foreground: Theme.textTertiary)
                }
                .accessibilityLabel("Edit labels")
            }
            if let at = current.scheduledAt {
                Chip(text: Formatters.reminder(at), systemImage: current.isFollowUp ? "clock.arrow.circlepath" : "clock",
                     background: Theme.tagBackground(Self.remindTone), foreground: Theme.tagForeground(Self.remindTone), capsule: true)
                    .accessibilityLabel(current.isFollowUp ? "Follow up \(Formatters.reminder(at)) if no reply" : "Reminder \(Formatters.reminder(at))")
            }
            if current.needsReply {
                Chip(text: "Need reply", systemImage: "arrowshape.turn.up.left",
                     background: Theme.tagBackground(Self.replyTone), foreground: Theme.tagForeground(Self.replyTone), capsule: true)
            }
            Spacer(minLength: 4)
            let count = detail?.messages.count ?? row.messageCount
            if count > 1 {
                Text("\(count)").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textTertiary).monospacedDigit()
                    .accessibilityLabel("\(count) messages")
            }
        }
    }

    // MARK: Bottom bars

    /// The Reply pill, then the triage actions as one glass bar.
    /// State colours, shared by the header badges and the active bar buttons.
    private static let remindTone = AccountColor.lavender
    private static let replyTone = AccountColor.sky
    private static let doneTone = AccountColor.mint

    private var bottomBars: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                replyPill
                if model.aiConfigured {
                    Button { Task { await draftReply() } } label: {
                        Image(systemName: "sparkles").font(.title3).foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Theme.accent.opacity(drafting ? 0.4 : 0.9), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(detail == nil || drafting)
                    .accessibilityLabel("Draft a reply with AI")
                }
            }
            // Each toggle shows its state: filled icon in the state's colour.
            HStack(spacing: 0) {
                bar(current.isDone ? "Mark not done" : "Mark done", current.isDone ? "checkmark.circle.fill" : "checkmark",
                    tint: current.isDone ? Theme.tagForeground(Self.doneTone) : nil) {
                    model.toggleDone(current); onClose()
                }
                bar(current.scheduledAt == nil ? "Remind me" : "Change reminder", current.scheduledAt == nil ? "clock" : "clock.fill",
                    tint: current.scheduledAt == nil ? nil : Theme.tagForeground(Self.remindTone)) {
                    model.pendingRemind = current
                }
                bar(current.needsReply ? "Clear need reply" : "Need reply",
                    current.needsReply ? "arrowshape.turn.up.left.fill" : "arrowshape.turn.up.left",
                    tint: current.needsReply ? Theme.tagForeground(Self.replyTone) : nil) {
                    model.toggleNeedsReply(current)
                }
                bar(current.isPinned ? "Unpin" : "Pin", current.isPinned ? "pin.fill" : "pin", tint: current.isPinned ? Theme.pin : nil) {
                    model.togglePin(current)
                }
                bar("Delete", "trash", tint: Color(hex: 0xB34E2E)) { model.delete(current); onClose() }
            }
            .frame(height: 52)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    /// Superhuman's reply button: the chevron picks Reply · Reply all ·
    /// Forward (kept for this thread), the label runs it on the latest
    /// message. The AI draft is its own circle next to it.
    private var replyPill: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(ReplyKind.allCases) { kind in
                    Button { replyChoice = kind; run(kind) } label: {
                        Label(kind.title, systemImage: kind == replyKind ? "checkmark" : kind.systemImage)
                        Text(recipients(kind))
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: replyKind.systemImage)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
                .padding(.leading, 18).padding(.trailing, 12)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Choose reply type")
            Rectangle().fill(Theme.separator).frame(width: 1, height: 22)
            Button { run(replyKind) } label: {
                Text(replyKind.title)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Theme.textPrimary)
        .frame(height: 48)
        .glassEffect(.regular, in: .capsule)
        .disabled(detail == nil)
    }

    /// Who a reply kind goes to, for the menu's second line.
    private func recipients(_ kind: ReplyKind) -> String {
        guard let last = detail?.messages.last else { return "" }
        switch kind {
        case .forward: return "Choose recipients"
        case .reply, .replyAll:
            let d = replyDraft(to: last, all: kind == .replyAll)
            let names = (d.to + d.cc).map { address in
                detail?.messages.first { $0.fromAddress == address }?.fromName ?? address
            }
            return names.joined(separator: ", ")
        }
    }

    private func bar(_ label: String, _ systemImage: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.title3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? Theme.textPrimary)
        .accessibilityLabel(label)
    }

    // MARK: Reply / forward

    /// Runs a reply kind on one message; the latest when none is given.
    private func run(_ kind: ReplyKind, on message: MessageItem? = nil) {
        guard let m = message ?? detail?.messages.last else { return }
        switch kind {
        case .reply: reply(to: m, all: false)
        case .replyAll: reply(to: m, all: true)
        case .forward: forward(m)
        }
    }

    private func reply(to m: MessageItem, all: Bool) {
        model.composeDraft = replyDraft(to: m, all: all)
    }

    private func replyDraft(to m: MessageItem, all: Bool) -> SendDraft {
        SendDraft.reply(to: m, in: current, all: all, history: transcript)
    }

    private func forward(_ m: MessageItem) {
        var d = SendDraft()
        d.subject = row.subject.lowercased().hasPrefix("fwd:") ? row.subject : "Fwd: \(row.subject)"
        d.bodyText = "\n\n---------- Forwarded message ----------\nFrom: \(m.fromName) <\(m.fromAddress)>\nDate: \(Formatters.fullDate(m.date))\n\n\(m.bodyText ?? m.snippet)"
        d.fromAccountId = current.accountId
        model.composeDraft = d
    }

    /// Desktop "Draft with AI" in the inline reply: writes the reply body,
    /// the user edits and sends.
    private func draftReply() async {
        guard let last = detail?.messages.last else { return }
        drafting = true
        defer { drafting = false }
        do {
            let text = try await model.engine.aiDraftReply(subject: row.subject, history: transcript, notes: nil)
            reply(to: last, all: false)
            model.composeDraft?.bodyText = text
        } catch { model.show(error.localizedDescription) }
    }
}

enum ReplyKind: String, CaseIterable, Identifiable {
    case reply, replyAll, forward
    var id: String { rawValue }

    var title: String {
        switch self {
        case .reply: "Reply"
        case .replyAll: "Reply all"
        case .forward: "Forward"
        }
    }

    var systemImage: String {
        switch self {
        case .reply: "arrowshape.turn.up.left"
        case .replyAll: "arrowshape.turn.up.left.2"
        case .forward: "arrowshape.turn.up.right"
        }
    }
}

/// One message as the inbox row: sender · time, one snippet line; the
/// unread bar on the left edge. Expanded, it sits on the card surface with
/// the recipients and the body, and its ••• (or a long press on any row)
/// replies to or forwards this message.
struct MessageRow: View {
    let message: MessageItem
    let expanded: Bool
    let onToggle: () -> Void
    let onAction: (ReplyKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(message.isMine ? "Me" : message.fromName)
                            .font(Theme.sender(!message.isRead))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(expanded ? Formatters.fullDate(message.date) : Formatters.rowTime(message.date))
                            .font(.footnote)
                            .foregroundStyle(message.isRead ? Theme.textTertiary : Theme.textSecondary)
                            .monospacedDigit()
                        if expanded { actionsMenu }
                    }
                    if expanded {
                        Text("to \(message.to.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    } else {
                        Text(message.snippet).font(.footnote).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                MessageBodyView(html: message.bodyHTML, text: message.bodyText ?? message.snippet, senderAddress: message.fromAddress)
                    .padding(.top, 12)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, expanded ? 12 : 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(expanded ? Theme.card : Theme.canvas)
        .overlay(alignment: .leading) {
            if !message.isRead { Rectangle().fill(Theme.unreadBar).frame(width: 3) }
        }
        .contextMenu {
            ForEach(ReplyKind.allCases) { kind in
                Button { onAction(kind) } label: { Label(kind.title, systemImage: kind.systemImage) }
            }
        }
    }

    private var actionsMenu: some View {
        Menu {
            ForEach(ReplyKind.allCases) { kind in
                Button { onAction(kind) } label: { Label(kind.title, systemImage: kind.systemImage) }
            }
        } label: {
            Image(systemName: "ellipsis").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                .frame(width: 28, height: 22).contentShape(Rectangle())
        }
        .accessibilityLabel("Actions for this message")
    }
}

/// The folded middle of a long thread: "4 earlier messages".
private struct EarlierRow: View {
    let count: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal").font(.caption.weight(.bold))
                Text("\(count) earlier messages").font(.footnote.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.canvas)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
