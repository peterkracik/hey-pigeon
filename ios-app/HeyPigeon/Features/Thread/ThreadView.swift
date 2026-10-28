// A thread: participants in the glass pill on top, subject with the priority
// chip and the Jev labels, messages as flat rows (latest expanded) with the
// desktop's per-message actions (Reply · Reply all · Forward), and two
// floating glass bars at the bottom: Reply (+ AI draft) and the triage
// actions in the desktop's words: Done · Remind · Need reply · Pin · Delete.

import SwiftUI

struct ThreadView: View {
    let row: ThreadRow
    let onClose: () -> Void
    @Environment(AppModel.self) private var model
    @State private var detail: ThreadDetail?
    @State private var expanded: Set<String> = []
    @State private var allCollapsed = false
    @State private var failed: String?
    @State private var summary: String?
    @State private var summarizing = false
    @State private var drafting = false

    private var current: ThreadRow { model.rows.first { $0.id == row.id } ?? detail?.thread ?? row }

    private var participants: String {
        guard let msgs = detail?.messages else { return row.fromSummary }
        var seen: [String] = []
        for m in msgs where !m.isMine && !seen.contains(m.fromName) { seen.append(m.fromName) }
        return seen.isEmpty ? row.fromSummary : seen.joined(separator: ", ")
    }

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
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(current.isRead ? .clear : Theme.accent).frame(width: 8, height: 8)
                    Text(row.subject.isEmpty ? "(no subject)" : row.subject)
                        .font(Theme.display(22, relativeTo: .title2))
                        .foregroundStyle(Theme.textPrimary)
                }
                .padding(.horizontal, 20).padding(.top, 6)

                triageHeader.padding(.horizontal, 20).padding(.top, 10)

                if current.scheduledAt != nil || current.needsReply {
                    statusLine.padding(.horizontal, 20).padding(.top, 8)
                }
                if model.aiConfigured, detail != nil {
                    summaryRow.padding(.horizontal, 20).padding(.top, 10)
                }
                if let detail {
                    ForEach(detail.messages) { m in
                        let isLast = m.id == detail.messages.last?.id
                        MessageRow(message: m, expanded: !allCollapsed && (expanded.contains(m.id) || isLast)) {
                            allCollapsed = false
                            if expanded.contains(m.id) { expanded.remove(m.id) } else { expanded.insert(m.id) }
                        } onReply: { reply(to: m, all: false) } onReplyAll: { reply(to: m, all: true) } onForward: { forward(m) }
                        Divider().padding(.leading, 20)
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
        .toolbarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(participants).font(.subheadline.weight(.semibold)).lineLimit(1)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .glassEffect(.regular, in: .capsule)
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
        .task(id: row.id) {
            do {
                detail = try await model.engine.thread(id: row.id)
                if detail == nil { failed = "This thread is no longer available." }
                else if model.autoSummarize && model.aiConfigured { await summarize() }
            } catch { failed = error.localizedDescription }
        }
    }

    // MARK: Header pieces

    /// Priority + the Jev labels, with a "+" menu to edit them by hand
    /// (sticky until "Reanalyze all emails" in Settings).
    @ViewBuilder
    private var triageHeader: some View {
        let names = current.triageLabelIds.compactMap { id in model.triageLabels.first { $0.id == id } }
        if current.priority != nil || !names.isEmpty || !model.triageLabels.isEmpty {
            HStack(spacing: 6) {
                if let p = current.priority, p != .spam {
                    Chip(text: p.rawValue, background: Theme.priorityColor(p).opacity(0.14), foreground: Theme.priorityColor(p))
                }
                ForEach(names) { l in
                    Chip(text: l.name, systemImage: "sparkles", background: Theme.navy100, foreground: Theme.textSecondary)
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
                        Image(systemName: "plus").font(.caption.weight(.bold)).foregroundStyle(Theme.textTertiary)
                            .frame(width: 24, height: 22)
                            .background(Theme.navy100, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .accessibilityLabel("Edit labels")
                }
                Spacer()
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 10) {
            if let at = current.scheduledAt {
                Label(current.isFollowUp ? "Follow up \(Formatters.reminder(at)) if no reply" : "Reminder \(Formatters.reminder(at))",
                      systemImage: current.isFollowUp ? "clock.arrow.circlepath" : "clock")
            }
            if current.needsReply { Label("Needs your reply", systemImage: "arrowshape.turn.up.left") }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Theme.textSecondary)
        .padding(.leading, 18)
    }

    /// Desktop "Summarize thread": explicit click, cached for the view.
    private var summaryRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if summary == nil { Task { await summarize() } } else { summary = nil }
            } label: {
                Text(summarizing ? "Summarizing…" : (summary == nil ? "Summarize thread" : "Hide summary"))
                    .font(.caption2.weight(.semibold)).foregroundStyle(Theme.textTertiary)
            }
            .disabled(summarizing)
            if let summary {
                Text(summary)
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.navy50, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func summarize() async {
        guard let msgs = detail?.messages, !msgs.isEmpty else { return }
        summarizing = true
        defer { summarizing = false }
        do {
            summary = try await model.engine.aiSummarizeThread(
                subject: row.subject,
                items: msgs.map { (from: $0.isMine ? "Me" : $0.fromName, snippet: String(($0.bodyText ?? $0.snippet).prefix(1500))) }
            )
        } catch { summary = error.localizedDescription }
    }

    // MARK: Bottom bars

    /// Reply pill (+ AI draft) and the "new message" circle, then the triage
    /// bar underneath — every button its own glass element in one container
    /// so taps land on the buttons, not on the glass.
    private var bottomBars: some View {
        VStack(spacing: 10) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Button { model.composeDraft = SendDraft(fromAccountId: current.accountId) } label: {
                        Image(systemName: "square.and.pencil").frame(width: 24, height: 24)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("New message")
                    Button { if let last = detail?.messages.last { reply(to: last, all: false) } } label: {
                        HStack {
                            Image(systemName: "arrowshape.turn.up.left")
                            Text("Reply")
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .disabled(detail == nil)
                    if model.aiConfigured {
                        Button { Task { await draftReply() } } label: {
                            Image(systemName: "sparkles").foregroundStyle(Theme.accent).frame(width: 24, height: 24)
                        }
                        .buttonStyle(.glass)
                        .disabled(detail == nil || drafting)
                        .accessibilityLabel("Draft a reply with AI")
                    }
                }
            }
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    bar(current.isDone ? "Mark not done" : "Mark done", current.isDone ? "arrow.uturn.backward" : "checkmark") {
                        model.toggleDone(current); onClose()
                    }
                    bar("Remind me", "clock") { model.pendingRemind = current }
                    bar(current.needsReply ? "Clear need reply" : "Need reply",
                        current.needsReply ? "arrowshape.turn.up.left.fill" : "arrowshape.turn.up.left") {
                        model.toggleNeedsReply(current)
                    }
                    bar(current.isPinned ? "Unpin" : "Pin", current.isPinned ? "pin.fill" : "pin", tint: current.isPinned ? Theme.pin : nil) {
                        model.togglePin(current)
                    }
                    bar("Delete", "trash", tint: Color(hex: 0xB34E2E)) { model.delete(current); onClose() }
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private func bar(_ label: String, _ systemImage: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.title3).frame(maxWidth: .infinity).frame(height: 28)
        }
        .buttonStyle(.glass)
        .foregroundStyle(tint ?? Theme.textPrimary)
        .accessibilityLabel(label)
    }

    // MARK: Reply / forward

    private func reply(to m: MessageItem, all: Bool) {
        var d = SendDraft()
        let others = m.to.filter { $0 != "me" && !$0.isEmpty }
        if m.isMine {
            d.to = others
        } else {
            d.to = [m.fromAddress]
            if all { d.cc = others }
        }
        d.subject = row.subject.lowercased().hasPrefix("re:") ? row.subject : "Re: \(row.subject)"
        d.replyToThreadId = row.id
        d.fromAccountId = current.accountId
        d.history = transcript
        model.composeDraft = d
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

/// One message: a flat row (sender · date · first line) that expands to the
/// body and the desktop's message actions. No card, hairline separators.
struct MessageRow: View {
    let message: MessageItem
    let expanded: Bool
    let onToggle: () -> Void
    let onReply: () -> Void
    let onReplyAll: () -> Void
    let onForward: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onToggle) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.isMine ? "Me" : message.fromName)
                            .font(Theme.sender(true))
                            .foregroundStyle(Theme.textPrimary)
                        if expanded {
                            Text("to \(message.to.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        } else {
                            Text(message.snippet).font(.subheadline).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Text(expanded ? Formatters.fullDate(message.date) : Formatters.rowTime(message.date))
                        .font(.subheadline).foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                MessageBodyView(html: message.bodyHTML, text: message.bodyText ?? message.snippet, senderAddress: message.fromAddress)
                HStack(spacing: 18) {
                    action("Reply", "arrowshape.turn.up.left", onReply)
                    action("Reply all", "arrowshape.turn.up.left.2", onReplyAll)
                    action("Forward", "arrowshape.turn.up.right", onForward)
                    Spacer()
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func action(_ title: String, _ systemImage: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: systemImage).font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
    }
}
