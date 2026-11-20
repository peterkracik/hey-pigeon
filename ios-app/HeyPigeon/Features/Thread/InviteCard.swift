// A calendar invitation in a thread (Shared/CalendarInvite.swift): what,
// when, where — read on the device from the message's .ics attachment —
// with Accept · Maybe · Decline, which answer the organizer by mail from
// the account that was invited (through the send's usual Undo), and Add
// to Calendar.
//
// It is a block of the thread's paper under its own title, not a card
// (docs/specs/marker-look.md): "Invitation" over a rule, the event as
// writing with its time in the mono, and the answers as outlined
// capsules. None of them is ink: the thread's one ink action is Reply.

import SwiftUI

struct InviteCard: View {
    let invite: CalendarInvite
    let row: ThreadRow
    @Environment(AppModel.self) private var model
    /// The answer sent for this thread, so its button shows it: the
    /// model's (AppModel.inviteAnswers), so it is still shown when the
    /// thread is opened again and goes when the answer's send is undone.
    private var answered: CalendarInvite.Answer? { model.inviteAnswers[row.id]?.answer }
    @State private var added = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Invitation")
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: invite.isCancellation ? "calendar.badge.minus" : "calendar")
                    .font(.title3)
                    .foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(invite.summary.isEmpty ? "Invitation" : invite.summary)
                        .font(Theme.text(.bodySmall, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    // A date and a time are data: the mono.
                    if let when = invite.whenText {
                        Text(when).font(Theme.meta).foregroundStyle(Theme.textSecondary)
                    }
                    if let place = invite.location {
                        Text(place).font(Theme.secondary).foregroundStyle(Theme.textTertiary).lineLimit(2)
                    }
                    if invite.isCancellation {
                        Text("The organizer cancelled this event.").font(Theme.secondary).foregroundStyle(Theme.textTertiary)
                    } else if let organizer = invite.organizerName ?? invite.organizerEmail {
                        Text("From \(organizer)").font(Theme.secondary).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            if invite.isAnswerable || canAdd {
                // Four labelled buttons do not fit a phone's width in one
                // row: they wrap (a single row reads as before).
                FlowLayout(spacing: 8) {
                    if invite.isAnswerable {
                        ForEach(CalendarInvite.Answer.allCases) { answer in
                            Button { send(answer) } label: {
                                Label(answer.title, systemImage: answered == answer ? "checkmark" : symbol(answer))
                                    .font(Self.answerFont)
                            }
                            .disabled(answered != nil)
                        }
                    }
                    if canAdd {
                        Button { add() } label: {
                            Label(added ? "Added" : "Add to Calendar", systemImage: added ? "checkmark" : "calendar.badge.plus")
                                .font(Self.answerFont)
                        }
                        .disabled(added)
                    }
                }
                .buttonStyle(OutlineButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Invitation: \(invite.summary)")
    }

    /// The answers' words: the thread's small text in semibold, a step
    /// under the event's own name (the capsule's default is a sheet's
    /// button size).
    private static let answerFont = Theme.text(.secondary, .semibold)

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
        model.answerInvite(answer, with: draft, threadId: row.id, from: account.id)
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
