// A calendar invitation in a thread (Shared/CalendarInvite.swift): what,
// when, where — read on the device from the message's .ics attachment —
// with Accept · Maybe · Decline, which answer the organizer by mail from
// the account that was invited (through the send's usual Undo), and Add
// to Calendar.

import SwiftUI

struct InviteCard: View {
    let invite: CalendarInvite
    let row: ThreadRow
    @Environment(AppModel.self) private var model
    /// The answer sent from this card, so its button shows it.
    @State private var answered: CalendarInvite.Answer?
    @State private var added = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: invite.isCancellation ? "calendar.badge.minus" : "calendar")
                    .font(.title3)
                    .foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(invite.summary.isEmpty ? "Invitation" : invite.summary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let when = invite.whenText {
                        Text(when).font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                    if let place = invite.location {
                        Text(place).font(.footnote).foregroundStyle(Theme.textTertiary).lineLimit(2)
                    }
                    if invite.isCancellation {
                        Text("The organizer cancelled this event.").font(.footnote).foregroundStyle(Theme.textTertiary)
                    } else if let organizer = invite.organizerName ?? invite.organizerEmail {
                        Text("From \(organizer)").font(.footnote).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            if invite.isAnswerable || canAdd {
                HStack(spacing: 8) {
                    if invite.isAnswerable {
                        ForEach(CalendarInvite.Answer.allCases) { answer in
                            Button { send(answer) } label: {
                                Label(answer.title, systemImage: answered == answer ? "checkmark" : symbol(answer))
                            }
                            .disabled(answered != nil)
                        }
                    }
                    if canAdd {
                        Button { add() } label: { Label(added ? "Added" : "Add to Calendar", systemImage: added ? "checkmark" : "calendar.badge.plus") }
                            .disabled(added)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Invitation: \(invite.summary)")
    }

    private var canAdd: Bool { CalendarAccess.isAvailable && !invite.isCancellation && invite.start != nil }

    private func symbol(_ answer: CalendarInvite.Answer) -> String {
        switch answer {
        case .accepted: "checkmark.circle"
        case .tentative: "questionmark.circle"
        case .declined: "xmark.circle"
        }
    }

    /// The answer goes to the organizer as mail from the invited account.
    private func send(_ answer: CalendarInvite.Answer) {
        guard let account = model.account(for: row), let draft = invite.replyDraft(answer, from: account) else { return }
        answered = answer
        model.send(draft, from: account.id)
    }

    private func add() {
        Task {
            do {
                try await CalendarAccess.add(invite)
                added = true
                model.show("Added to your calendar")
            } catch {
                model.show(error.localizedDescription)
            }
        }
    }
}
