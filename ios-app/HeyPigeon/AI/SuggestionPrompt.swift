// The "Need reply / Remind me" prompt for new mail, in one place (the core
// decides which emails to ask about: crates/ffi/src/suggest.rs). The model
// reads one new unread email and fills `SuggestionCall`; the date it names
// is turned into a reminder here, in the user's time zone, because the
// core does not know it. Pure Foundation, so the date rules are tested
// without a model (ModelTests).

import Foundation

/// The shipped suggestion prompt and the date rules around it.
enum SuggestionPrompt {
    static let instructions = """
    You help a busy person decide what to do with one new email. Answer with exactly one action. \
    reply: a real person wrote to them directly and is waiting on their answer — a question, a \
    request, an invitation to confirm, a decision only they can make. remind: the email is about \
    something on a later date they will need it for — a meeting, an appointment, a flight, a \
    payment or other deadline, an event — and nobody needs an answer now. nothing: everything \
    else — newsletters, promotions, receipts, notifications, automated mail, FYIs, and anything \
    already settled. Never choose reply for automated or bulk mail. When unsure, choose nothing. \
    For remind: remindOn is the day to bring the email back as YYYY-MM-DD — the day of the meeting \
    or event, or the day before a deadline — worked out from the date the email was received; \
    hour is when on that day, 8 unless the email names an earlier time that day (then one hour \
    before it). For reply and nothing, leave remindOn empty and hour 8.
    """

    /// One email as the model sees it. `received` is written out in the
    /// user's time zone with the weekday, so "Friday" and "tomorrow" have
    /// something to resolve against.
    static func prompt(subject: String, from: String, body: String, received: Date,
                       calendar: Calendar = .current) -> String {
        """
        Received: \(receivedLine(received, calendar: calendar))
        From: \(from)
        Subject: \(subject.isEmpty ? "(no subject)" : subject)

        \(body)
        """
    }

    /// "Sunday, 1 November 2026, 14:05", English whatever the device
    /// language: the model works out dates from it.
    static func receivedLine(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        return f.string(from: date)
    }

    /// The model's answer as a proposal, or nil for "nothing". A remind
    /// without a valid day is nothing too (the core also drops a date in
    /// the past or more than a year out).
    static func suggestion(action: String, remindOn: String, hour: Int,
                           calendar: Calendar = .current) -> MailSuggestion? {
        switch action {
        case "reply": return .needsReply
        case "remind": return remindDate(day: remindOn, hour: hour, calendar: calendar).map { .remind(at: $0) }
        default: return nil
        }
    }

    /// "2026-11-06" at `hour`:00 in the calendar's time zone; nil when the
    /// text is not a real day (the model wrote "Friday", or "2026-02-30").
    /// An hour outside 0…23 means the default, 8.
    static func remindDate(day: String, hour: Int, calendar: Calendar = .current) -> Date? {
        let parts = day.trimmingCharacters(in: .whitespaces).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let c = DateComponents(year: parts[0], month: parts[1], day: parts[2],
                               hour: (0...23).contains(hour) ? hour : 8, minute: 0)
        guard let date = calendar.date(from: c) else { return nil }
        // `date(from:)` rolls 30 February over into March; refuse instead.
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == parts[0], back.month == parts[1], back.day == parts[2] else { return nil }
        return date
    }
}
