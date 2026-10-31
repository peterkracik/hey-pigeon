// A thread: the other people's names between the back and action circles,
// subject with one line of chips (priority, Jev labels, reminder, need
// reply — the list's chips) and the message count, messages as the inbox's
// rows (latest expanded, the middle of long threads folded), and two
// floating glass bars at the bottom: the Reply button — tap for the default
// action, chevron for Reply · Reply all · Forward, as in Superhuman — with
// the AI draft circle beside it, and one triage bar in the desktop's words:
// Done · Remind · Need reply · Pin · Delete. Unsent reply drafts sit under
// the messages, marked as drafts, to edit or delete; the Reply button then
// continues the draft.

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
    /// The thread's attachments, by message, once the detail is here and
    /// the row has a paperclip. One network read per thread.
    @State private var attachments: [String: [AttachmentItem]] = [:]
    /// The triage hook: a receipt / ticket / shipment with an image or PDF,
    /// read on device as soon as the thread opens; the chips sit under the
    /// subject line. Nil until (and unless) there is something to offer.
    @State private var hintActions: [AttachmentAction] = []
    /// The draft the delete confirmation is asking about.
    @State private var deletingDraft: ThreadDraft?

    /// Live from the store (AppModel.openThread), never the copy this view
    /// was opened with: that one goes stale with the first action.
    private var current: ThreadRow {
        if let open = model.openThread, open.id == row.id { return open }
        return model.rows.first { $0.id == row.id } ?? detail?.thread ?? row
    }

    private var participants: String { detail?.participantNames ?? row.fromSummary }

    /// Reply all when someone besides the sender is on the last message,
    /// else Reply.
    private var defaultReply: ReplyKind {
        guard let last = detail?.mail.last, !last.isMine else { return .reply }
        return last.to.contains { $0 != "me" && !$0.isEmpty } ? .replyAll : .reply
    }

    private var replyKind: ReplyKind { replyChoice ?? defaultReply }

    private var accountLabels: [MailLabelItem] {
        model.labels.filter { $0.accountId == current.accountId && !$0.id.hasPrefix("CATEGORY_") }
    }

    /// Plain-text transcript, oldest first, "Me" for own messages (AI context).
    private var transcript: String { detail?.transcript ?? "" }

    /// The thread's unsent drafts, oldest first. A draft saved a moment ago
    /// and not synced back yet stands in for the stored copy it updates.
    private var drafts: [ThreadDraft] {
        let local = model.unsyncedDrafts[row.id]
        var out = (detail?.drafts ?? [])
            .filter { $0.id != local?.draftKey }
            .map { ThreadDraft(stored: $0, accountId: current.accountId) }
        if let local { out.append(ThreadDraft(unsynced: local, accountId: current.accountId)) }
        return out
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text(row.subject.isEmpty ? "(no subject)" : row.subject)
                    .font(Theme.display(22, relativeTo: .title2))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 16).padding(.top, 6)

                metaLine.padding(.horizontal, 16).padding(.top, 8)
                if !hintActions.isEmpty {
                    AttachmentActionChips(actions: hintActions, row: current)
                        .padding(.horizontal, 16).padding(.top, 8)
                        .accessibilityLabel("Suggested from the attachment")
                }

                if let detail {
                    messageList(detail.mail).padding(.top, 14)
                    let pending = drafts
                    if !pending.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(pending) { d in
                                DraftRow(draft: d) { edit(d) } onDelete: { deletingDraft = d }
                            }
                        }
                        .padding(.horizontal, 12).padding(.top, 10)
                    }
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
        .hidesTabBar()
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(participants)
                    .font(Theme.display(17, relativeTo: .headline))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
            if model.aiConfigured {
                ToolbarItem(placement: .barTrailing) {
                    Button {
                        if let d = detail { model.openThreadSummary(current, messages: d.mail) }
                    } label: { Image(systemName: "sparkles") }
                    .disabled(detail == nil)
                    .accessibilityLabel("Summarize thread")
                }
            }
            ToolbarItem(placement: .barTrailing) {
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
                                Button { IntentDonations.labeled(current, label, on: true, in: model); model.move(current, to: label); onClose() } label: { Label(label.name, systemImage: "tray") }
                            }
                        } label: { Label("Move to folder", systemImage: "folder") }
                        Menu {
                            ForEach(accountLabels) { label in
                                let on = current.labels.contains(label.id)
                                Button { IntentDonations.labeled(current, label, on: !on, in: model); model.setLabel(current, label, on: !on) } label: {
                                    Label(on ? "Remove \(label.name)" : label.name, systemImage: on ? "checkmark" : "tag")
                                }
                            }
                        } label: { Label("Add label", systemImage: "tag") }
                    }
                    Button { if let last = detail?.mail.last { forward(last) } } label: {
                        Label("Forward", systemImage: "arrowshape.turn.up.right")
                    }
                    Divider()
                    Button(role: .destructive) { IntentDonations.deleted(current, in: model); model.delete(current); onClose() } label: { Label("Delete", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("More")
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBars }
        .confirmationDialog("Delete this draft?", isPresented: Binding(get: { deletingDraft != nil }, set: { if !$0 { deletingDraft = nil } }),
                            titleVisibility: .visible, presenting: deletingDraft) { d in
            Button("Delete draft", role: .destructive) { deleteDraft(d) }
        }
        // On-screen awareness: "Hey Siri, remind me about this tomorrow"
        // resolves to this thread (MailThreadQuery.defaultResult is the
        // fallback when Siri cannot read the activity).
        .userActivity(ThreadView.activityType) { activity in
            activity.title = row.subject.isEmpty ? row.fromSummary : row.subject
            #if os(iOS)
            activity.appEntityIdentifier = EntityIdentifier(for: MailThreadEntity(current, account: model.account(for: current)))
            #endif
        }
        .onAppear { model.showThread(row) }
        .onDisappear { model.hideThread(row) }
        .task(id: row.id) {
            do {
                detail = try await model.engine.thread(id: row.id)
                // The first open stores the bodies: the index can now carry them.
                SpotlightIndexer.invalidate(threadId: row.id)
                if detail == nil { failed = "This thread is no longer available." }
                else if model.autoSummarize && model.aiConfigured, let d = detail {
                    model.summarizeThread(current, messages: d.mail)
                }
            } catch { failed = error.localizedDescription }
            await loadAttachments()
        }
        // A draft was saved, edited or deleted and is now in the store.
        .onChange(of: model.draftsRevision) { _, _ in
            Task { if let fresh = try? await model.engine.thread(id: row.id) { detail = fresh } }
        }
    }

    // MARK: Attachments

    /// The chips under each message, and — for mail that smells like a
    /// receipt, a ticket or a shipment — the on-device read of the first
    /// image or PDF, offered as one-tap chips. Never leaves the device.
    private func loadAttachments() async {
        guard current.hasAttachment, let list = try? await model.engine.attachments(threadId: row.id), !list.isEmpty else { return }
        attachments = Dictionary(grouping: list, by: \.messageId)
        guard AttachmentUnderstanding.isAvailable, AttachmentUnderstanding.looksActionable(subject: row.subject),
              let first = list.first(where: \.isExplainable) else { return }
        do {
            let file = try await model.engine.attachmentFile(first)
            let insight = try await AttachmentUnderstanding.explain(file: file, mimeType: first.mimeType, filename: first.filename)
            withAnimation(.snappy) { hintActions = AttachmentUnderstanding.actions(for: insight) }
        } catch {
            // A hint, not a feature the user asked for: fail quietly.
        }
    }

    // MARK: Messages

    /// The messages with 1 pt gaps, as in the list. Long threads fold their
    /// middle into one row: the first message, "N earlier", then the last
    /// two and any unread run before them. Opening a message unfolds.
    private func messageList(_ messages: [MessageItem]) -> some View {
        let lastIndex = messages.count - 1
        // Folded unless the user unfolded it or opened a message inside it.
        let folded = unfolded ? nil : ThreadDetail.foldedRange(messages).flatMap { range in
            messages[range].contains { expanded.contains($0.id) } ? nil : range
        }
        return VStack(spacing: 1) {
            ForEach(Array(messages.enumerated()), id: \.element.id) { index, m in
                if let folded, folded.contains(index) {
                    if index == folded.lowerBound {
                        EarlierRow(count: folded.count) { withAnimation(.snappy) { unfolded = true } }
                    }
                } else {
                    MessageRow(message: m, expanded: !allCollapsed && (expanded.contains(m.id) || index == lastIndex),
                               attachments: attachments[m.id] ?? []) {
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
            let count = detail?.mail.count ?? row.messageCount
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
            // With a hardware keyboard (iPad, the Mac) the desktop's keys
            // run them: e · h · n · s · ⌘⌫.
            HStack(spacing: 0) {
                bar(current.isDone ? "Mark not done" : "Mark done", current.isDone ? "checkmark.circle.fill" : "checkmark",
                    tint: current.isDone ? Theme.tagForeground(Self.doneTone) : nil, key: "e") {
                    if !current.isDone { IntentDonations.archived(current, in: model) }
                    model.toggleDone(current); onClose()
                }
                bar(current.scheduledAt == nil ? "Remind me" : "Change reminder", current.scheduledAt == nil ? "clock" : "clock.fill",
                    tint: current.scheduledAt == nil ? nil : Theme.tagForeground(Self.remindTone), key: "h") {
                    model.pendingRemind = current
                }
                bar(current.needsReply ? "Clear need reply" : "Need reply",
                    current.needsReply ? "arrowshape.turn.up.left.fill" : "arrowshape.turn.up.left",
                    tint: current.needsReply ? Theme.tagForeground(Self.replyTone) : nil, key: "n") {
                    model.toggleNeedsReply(current)
                }
                bar(current.isPinned ? "Unpin" : "Pin", current.isPinned ? "pin.fill" : "pin", tint: current.isPinned ? Theme.pin : nil, key: "s") {
                    model.togglePin(current)
                }
                bar("Delete", "trash", tint: Color(hex: 0xB34E2E), key: .delete, modifiers: .command) { IntentDonations.deleted(current, in: model); model.delete(current); onClose() }
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
            Button { if let d = drafts.last { edit(d) } else { run(replyKind) } } label: {
                Text(drafts.isEmpty ? replyKind.title : "Continue draft")
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .threadKey("r")
        }
        .foregroundStyle(Theme.textPrimary)
        .frame(height: 48)
        .glassEffect(.regular, in: .capsule)
        .disabled(detail == nil)
    }

    /// Who a reply kind goes to, for the menu's second line.
    private func recipients(_ kind: ReplyKind) -> String {
        guard let last = detail?.mail.last else { return "" }
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

    /// One triage button; `key` is its hardware-keyboard shortcut.
    private func bar(_ label: String, _ systemImage: String, tint: Color? = nil,
                     key: KeyEquivalent, modifiers: EventModifiers = [], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.title3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? Theme.textPrimary)
        .threadKey(key, modifiers: modifiers)
        .accessibilityLabel(label)
    }

    // MARK: Reply / forward

    /// Runs a reply kind on one message; the latest when none is given.
    private func run(_ kind: ReplyKind, on message: MessageItem? = nil) {
        guard let m = message ?? detail?.mail.last else { return }
        switch kind {
        case .reply: reply(to: m, all: false)
        case .replyAll: reply(to: m, all: true)
        case .forward: forward(m)
        }
    }

    private func reply(to m: MessageItem, all: Bool) {
        IntentDonations.replied(current, all: all, in: model)
        model.composeDraft = replyDraft(to: m, all: all)
    }

    private func replyDraft(to m: MessageItem, all: Bool) -> SendDraft {
        SendDraft.reply(to: m, in: current, all: all, history: transcript)
    }

    private func forward(_ m: MessageItem) {
        model.composeDraft = SendDraft.forward(of: m, in: current)
    }

    /// Desktop "Draft with AI" in the inline reply: writes the reply body,
    /// the user edits and sends.
    private func draftReply() async {
        guard let last = detail?.mail.last else { return }
        drafting = true
        defer { drafting = false }
        do {
            let text = try await model.engine.aiDraftReply(subject: row.subject, history: transcript, notes: nil)
            reply(to: last, all: false)
            model.composeDraft?.bodyText = text
        } catch { model.show(error.localizedDescription) }
    }

    // MARK: Drafts

    /// Reopen a draft in the composer: one not synced yet as it was saved,
    /// a stored one read from Gmail (recipients, body, attachments).
    private func edit(_ d: ThreadDraft) {
        if let local = d.unsynced { model.composeDraft = local } else { model.openDraft(current) }
    }

    private func deleteDraft(_ d: ThreadDraft) {
        model.deleteDraft(d.id, from: d.accountId)
        if let detail {
            self.detail = ThreadDetail(thread: detail.thread, messages: detail.messages.filter { $0.id != d.id })
        }
        model.show("Draft deleted")
    }
}

/// An unsent reply under the thread: the stored DRAFT message, or the
/// composer's copy while its save syncs back.
struct ThreadDraft: Identifiable {
    /// The draft's key: the Gmail message id, or the composer's own.
    let id: String
    let accountId: String
    let to: [String]
    let text: String
    let date: Date
    var unsynced: SendDraft?

    init(stored m: MessageItem, accountId: String) {
        id = m.id
        self.accountId = accountId
        to = m.to
        text = m.bodyText ?? m.snippet
        date = m.date
    }

    init(unsynced d: SendDraft, accountId: String) {
        id = d.draftKey
        self.accountId = d.fromAccountId ?? accountId
        to = d.to + d.cc
        text = d.bodyText
        date = Date()
        unsynced = d
    }
}

/// A draft as a card under the messages: the Draft badge in the alert
/// colour, who it goes to, the start of the text, and Edit · Delete.
/// Tapping the card edits it too.
private struct DraftRow: View {
    let draft: ThreadDraft
    let onEdit: () -> Void
    let onDelete: () -> Void

    private static let tone = AccountColor.coral

    private var preview: String {
        let t = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Empty draft" : t
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Chip(text: "Draft", systemImage: "pencil",
                             background: Theme.tagBackground(Self.tone), foreground: Theme.tagForeground(Self.tone), capsule: true)
                        Text(draft.to.isEmpty ? "No recipients" : "to \(draft.to.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Formatters.rowTime(draft.date))
                            .font(.footnote).foregroundStyle(Theme.textTertiary).monospacedDigit()
                    }
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(draft.text.isEmpty ? Theme.textTertiary : Theme.textSecondary)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                Button(action: onEdit) { Label("Edit", systemImage: "square.and.pencil") }
                Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
                    .tint(Color(hex: 0xB34E2E))
                Spacer()
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.tagForeground(Self.tone).opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .contextMenu {
            Button(action: onEdit) { Label("Edit draft", systemImage: "square.and.pencil") }
            Button(role: .destructive, action: onDelete) { Label("Delete draft", systemImage: "trash") }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Draft")
    }
}

/// The reply button's three choices.
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
    var attachments: [AttachmentItem] = []
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
                if !attachments.isEmpty {
                    AttachmentChips(attachments: attachments).padding(.top, 10)
                }
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
