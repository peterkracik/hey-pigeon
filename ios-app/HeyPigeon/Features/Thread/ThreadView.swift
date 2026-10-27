// A thread: latest message expanded, older ones collapsed to one line.
// The bottom bar is the only toolbar in the app.

import SwiftUI

struct ThreadView: View {
    let row: ThreadRow
    let onClose: () -> Void
    @Environment(AppModel.self) private var model
    @State private var detail: ThreadDetail?
    @State private var expanded: Set<String> = []
    @State private var failed: String?

    private var current: ThreadRow { model.rows.first { $0.id == row.id } ?? detail?.thread ?? row }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text(row.subject.isEmpty ? "(no subject)" : row.subject)
                    .font(Theme.display(22, relativeTo: .title2))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 20).padding(.top, 8)
                if current.scheduledAt != nil || current.needsReply {
                    statusLine.padding(.horizontal, 20)
                }
                if let detail {
                    ForEach(detail.messages) { m in
                        MessageCard(message: m, expanded: expanded.contains(m.id) || m.id == detail.messages.last?.id) {
                            if expanded.contains(m.id) { expanded.remove(m.id) } else { expanded.insert(m.id) }
                        }
                    }
                } else if let failed {
                    ContentUnavailableView("Couldn't load", systemImage: "wifi.exclamationmark", description: Text(failed))
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.canvas)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { model.archive(current); onClose() } label: { Label("Archive", systemImage: "checkmark") }
                Spacer()
                Button { model.pendingRemind = current } label: { Label("Remind", systemImage: "clock") }
                Spacer()
                Button { model.toggleNeedsReply(current) } label: {
                    Label("Need reply", systemImage: current.needsReply ? "arrowshape.turn.up.left.fill" : "arrowshape.turn.up.left")
                }
                Spacer()
                Button { reply() } label: { Label("Reply", systemImage: "arrowshape.turn.up.left.2") }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Menu {
                    Button { model.toggleStar(current) } label: {
                        Label(current.isStarred ? "Unstar" : "Star", systemImage: current.isStarred ? "star.slash" : "star")
                    }
                    Button { model.toggleRead(current); onClose() } label: { Label("Mark unread", systemImage: "envelope.badge") }
                    Button { forward() } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                    Divider()
                    Button(role: .destructive) { model.trash(current); onClose() } label: { Label("Trash", systemImage: "trash") }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
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

struct MessageCard: View {
    let message: MessageItem
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onToggle) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.fromName)
                            .font(Theme.sender(false))
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
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                MessageBodyView(html: message.bodyHTML, text: message.bodyText ?? message.snippet, senderAddress: message.fromAddress)
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 12)
    }
}
