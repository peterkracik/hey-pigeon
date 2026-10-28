// A thread: participants in the glass pill on top, subject with the priority
// chip, messages as flat rows (latest expanded), and two floating glass bars
// at the bottom: Reply, and the triage actions.

import SwiftUI

struct ThreadView: View {
    let row: ThreadRow
    let onClose: () -> Void
    @Environment(AppModel.self) private var model
    @State private var detail: ThreadDetail?
    @State private var expanded: Set<String> = []
    @State private var allCollapsed = false
    @State private var failed: String?

    private var current: ThreadRow { model.rows.first { $0.id == row.id } ?? detail?.thread ?? row }

    private var participants: String {
        guard let msgs = detail?.messages else { return row.fromSummary }
        var seen: [String] = []
        for m in msgs where !m.isMine && !seen.contains(m.fromName) { seen.append(m.fromName) }
        return seen.isEmpty ? row.fromSummary : seen.joined(separator: ", ")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(current.isRead ? .clear : Theme.accent).frame(width: 8, height: 8)
                    Text(row.subject.isEmpty ? "(no subject)" : row.subject)
                        .font(Theme.display(22, relativeTo: .title2))
                        .foregroundStyle(Theme.textPrimary)
                    if let p = current.priority, p != .spam {
                        Chip(text: p.rawValue, background: Theme.priorityColor(p).opacity(0.14), foreground: Theme.priorityColor(p))
                    }
                }
                .padding(.horizontal, 20).padding(.top, 6)
                if current.scheduledAt != nil || current.needsReply {
                    statusLine.padding(.horizontal, 20).padding(.top, 8)
                }
                if let detail {
                    ForEach(detail.messages) { m in
                        let isLast = m.id == detail.messages.last?.id
                        MessageRow(message: m, expanded: !allCollapsed && (expanded.contains(m.id) || isLast)) {
                            allCollapsed = false
                            if expanded.contains(m.id) { expanded.remove(m.id) } else { expanded.insert(m.id) }
                        }
                        Divider().padding(.leading, 20)
                    }
                } else if let failed {
                    ContentUnavailableView("Couldn't load", systemImage: "wifi.exclamationmark", description: Text(failed))
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(.bottom, 140)
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
                    Button { model.toggleStar(current) } label: {
                        Label(current.isStarred ? "Unstar" : "Star", systemImage: current.isStarred ? "star.slash" : "star")
                    }
                    Button { model.toggleRead(current); onClose() } label: { Label("Mark unread", systemImage: "envelope.badge") }
                    Button { forward() } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                    if !model.labels.isEmpty {
                        Menu {
                            ForEach(model.labels.filter { $0.accountId == current.accountId }) { label in
                                let on = current.labels.contains(label.id)
                                Button {
                                    Task { try? await model.engine.perform(.modifyLabel(threadId: current.id, labelId: label.id, add: !on), accountId: current.accountId) }
                                } label: { Label(label.name, systemImage: on ? "checkmark" : "tag") }
                            }
                        } label: { Label("Labels", systemImage: "tag") }
                    }
                    Divider()
                    Button(role: .destructive) { model.trash(current); onClose() } label: { Label("Trash", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("More")
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBars }
        .task(id: row.id) {
            do {
                detail = try await model.engine.thread(id: row.id)
                if detail == nil { failed = "This thread is no longer available." }
            } catch { failed = error.localizedDescription }
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

    /// Reply pill + "new message" circle, then the triage bar underneath.
    private var bottomBars: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { model.composeDraft = SendDraft() } label: { Image(systemName: "square.and.pencil").frame(width: 24, height: 24) }
                    .buttonStyle(.glass)
                    .accessibilityLabel("New message")
                Button { reply() } label: {
                    HStack {
                        Image(systemName: "arrowshape.turn.up.left")
                        Text("Reply")
                        Spacer()
                        Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            HStack {
                bar("Archive", "checkmark") { model.archive(current); onClose() }
                Spacer()
                bar("Remind me", "clock") { model.pendingRemind = current }
                Spacer()
                bar("Need reply", current.needsReply ? "arrowshape.turn.up.left.fill" : "arrowshape.turn.up.left") { model.toggleNeedsReply(current) }
                Spacer()
                bar("Star", current.isStarred ? "star.fill" : "star") { model.toggleStar(current) }
                Spacer()
                bar(allCollapsed ? "Expand all" : "Collapse all", allCollapsed ? "arrow.up.and.down" : "arrow.down.right.and.arrow.up.left") {
                    withAnimation { allCollapsed.toggle(); if !allCollapsed { expanded = [] } }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private func bar(_ label: String, _ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: systemImage).font(.title3).frame(width: 44, height: 44) }
            .buttonStyle(.plain)
            .foregroundStyle(systemImage == "star.fill" ? Color(hex: 0xE3B341) : Theme.textPrimary)
            .accessibilityLabel(label)
    }

    private func reply() {
        guard let last = detail?.messages.last else { return }
        var d = SendDraft()
        d.to = [last.isMine ? (last.to.first ?? "") : last.fromAddress].filter { $0 != "me" && !$0.isEmpty }
        d.subject = row.subject.lowercased().hasPrefix("re:") ? row.subject : "Re: \(row.subject)"
        d.replyToThreadId = row.id
        model.composeDraft = d
    }

    private func forward() {
        guard let last = detail?.messages.last else { return }
        var d = SendDraft()
        d.subject = "Fwd: \(row.subject)"
        d.bodyText = "\n\n---------- Forwarded message ----------\nFrom: \(last.fromName) <\(last.fromAddress)>\nDate: \(Formatters.fullDate(last.date))\n\n\(last.bodyText ?? last.snippet)"
        model.composeDraft = d
    }
}

/// One message: a flat row (sender · date · first line) that expands to the
/// body. No card, hairline separators between rows.
struct MessageRow: View {
    let message: MessageItem
    let expanded: Bool
    let onToggle: () -> Void

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
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}
