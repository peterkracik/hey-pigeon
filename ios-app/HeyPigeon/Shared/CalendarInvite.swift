// A calendar invitation that came as an .ics attachment (iCalendar, RFC
// 5545): what it is for, when and where, and who sent it — read from the
// attachment on the device — and the answer to its organizer (iTIP REPLY,
// RFC 5546): a message from the invited account with the reply as its
// own .ics, which calendar servers read to mark the attendee's answer.
// Parsing and the reply are pure, for the tests; adding the event to the
// Mac's calendar is CalendarAccess, below.

import Foundation

struct CalendarInvite: Equatable, Sendable {
    var uid: String
    var summary: String
    var start: Date?
    var end: Date?
    var isAllDay = false
    var location: String?
    var organizerEmail: String?
    var organizerName: String?
    /// REQUEST for an invitation, CANCEL when the organizer called it off.
    var method: String?
    var sequence = 0
    /// DTSTART / DTEND as they were written: a reply repeats them.
    var rawStart: String?
    var rawEnd: String?

    var isCancellation: Bool { method?.uppercased() == "CANCEL" }
    /// An invitation that can be answered: it has someone to answer.
    var isAnswerable: Bool { !isCancellation && organizerEmail != nil && !uid.isEmpty }

    enum Answer: String, CaseIterable, Identifiable, Sendable {
        case accepted = "ACCEPTED", tentative = "TENTATIVE", declined = "DECLINED"
        var id: String { rawValue }

        var title: String {
            switch self {
            case .accepted: "Accept"
            case .tentative: "Maybe"
            case .declined: "Decline"
            }
        }

        /// The subject's first word, as calendar clients write it.
        var subjectPrefix: String {
            switch self {
            case .accepted: "Accepted"
            case .tentative: "Tentative"
            case .declined: "Declined"
            }
        }
    }

    // MARK: Parsing

    /// The first event of an .ics file; nil when the text holds none.
    static func parse(_ ics: String) -> CalendarInvite? {
        // Unfold: a line that starts with a space or a tab continues the
        // one before it.
        var lines: [String] = []
        for raw in ics.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: true) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else {
                lines.append(String(raw))
            }
        }
        var method: String?
        var inEvent = false
        var nested = 0
        var invite = CalendarInvite(uid: "", summary: "")
        var found = false
        for line in lines {
            guard let colon = Self.valueSeparator(in: line) else { continue }
            let head = line[..<colon]
            let value = String(line[line.index(after: colon)...])
            var params = head.split(separator: ";").map(String.init)
            let name = (params.isEmpty ? "" : params.removeFirst()).uppercased()
            if !inEvent {
                if name == "METHOD" { method = value.trimmingCharacters(in: .whitespaces) }
                if name == "BEGIN", value.uppercased() == "VEVENT" {
                    guard !found else { break }
                    inEvent = true
                    found = true
                }
                continue
            }
            // An alarm inside the event has properties of its own.
            if name == "BEGIN" { nested += 1; continue }
            if name == "END" {
                if nested > 0 { nested -= 1 } else if value.uppercased() == "VEVENT" { inEvent = false }
                continue
            }
            guard nested == 0 else { continue }
            switch name {
            case "UID": invite.uid = value
            case "SUMMARY": invite.summary = unescape(value)
            case "LOCATION":
                let place = unescape(value)
                invite.location = place.isEmpty ? nil : place
            case "SEQUENCE": invite.sequence = Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
            case "DTSTART":
                invite.rawStart = line
                let parsed = date(value, params: params)
                invite.start = parsed?.date
                invite.isAllDay = parsed?.allDay ?? false
            case "DTEND":
                invite.rawEnd = line
                invite.end = date(value, params: params)?.date
            case "ORGANIZER":
                invite.organizerEmail = address(value)
                invite.organizerName = params.first { $0.uppercased().hasPrefix("CN=") }
                    .map { String($0.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            default: break
            }
        }
        guard found else { return nil }
        invite.method = method
        return invite
    }

    /// The colon that ends the property's name and parameters: the first
    /// one outside a quoted parameter value (`CN="Doe: Jane"`).
    private static func valueSeparator(in line: String) -> String.Index? {
        var quoted = false
        for i in line.indices {
            if line[i] == "\"" { quoted.toggle() }
            if line[i] == ":", !quoted { return i }
        }
        return nil
    }

    private static func unescape(_ text: String) -> String {
        var out = ""
        var escaped = false
        for c in text {
            if escaped {
                out.append(c == "n" || c == "N" ? "\n" : c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// `mailto:ana@acme.test` → the address.
    private static func address(_ value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespaces)
        let bare = v.lowercased().hasPrefix("mailto:") ? String(v.dropFirst(7)) : v
        return bare.contains("@") ? bare : nil
    }

    /// `20261110T090000Z` (UTC), `20261110T100000` with a `TZID=`
    /// parameter (or floating: the device's zone), or `20261110` (a day).
    private static func date(_ value: String, params: [String]) -> (date: Date, allDay: Bool)? {
        let v = value.trimmingCharacters(in: .whitespaces)
        let zoneName = params.first { $0.uppercased().hasPrefix("TZID=") }.map { String($0.dropFirst(5)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        if v.count == 8 {
            formatter.dateFormat = "yyyyMMdd"
            formatter.timeZone = .current
            return formatter.date(from: v).map { ($0, true) }
        }
        if v.hasSuffix("Z") {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
        } else {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            formatter.timeZone = zoneName.flatMap(TimeZone.init(identifier:)) ?? .current
        }
        return formatter.date(from: v).map { ($0, false) }
    }

    // MARK: The answer

    /// The iTIP REPLY for this invitation from `attendee`.
    func reply(_ answer: Answer, from attendee: String, now: Date = Date()) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(identifier: "UTC")
        stamp.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var lines = [
            "BEGIN:VCALENDAR",
            "PRODID:-//Hey Pigeon//Mail//EN",
            "VERSION:2.0",
            "METHOD:REPLY",
            "BEGIN:VEVENT",
            "UID:\(uid)",
            "SEQUENCE:\(sequence)",
            "DTSTAMP:\(stamp.string(from: now))",
        ]
        if let rawStart { lines.append(rawStart) }
        if let rawEnd { lines.append(rawEnd) }
        if let organizerEmail { lines.append("ORGANIZER:mailto:\(organizerEmail)") }
        lines.append("ATTENDEE;PARTSTAT=\(answer.rawValue):mailto:\(attendee)")
        if !summary.isEmpty { lines.append("SUMMARY:\(Self.escape(summary))") }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\;")
            .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
    }

    /// The message that carries the answer to the organizer.
    func replyDraft(_ answer: Answer, from account: MailAccount) -> SendDraft? {
        guard let organizerEmail else { return nil }
        let title = summary.isEmpty ? "Invitation" : summary
        let ics = reply(answer, from: account.email)
        var draft = SendDraft()
        draft.to = [organizerEmail]
        draft.subject = "\(answer.subjectPrefix): \(title)"
        draft.bodyText = "\(account.displayName) \(answer.subjectPrefix.lowercased()) this invitation: \(title)"
        draft.attachments = [DraftAttachment(filename: "invite.ics", mimeType: "text/calendar; method=REPLY; charset=UTF-8",
                                             size: ics.utf8.count, dataBase64: Data(ics.utf8).base64EncodedString())]
        draft.fromAccountId = account.id
        return draft
    }

    /// "Tue 10 Nov, 10:00 – 11:00", a day for an all-day event.
    var whenText: String? {
        guard let start else { return nil }
        if isAllDay { return start.formatted(date: .complete, time: .omitted) }
        let from = start.formatted(date: .abbreviated, time: .shortened)
        guard let end, end > start else { return from }
        let sameDay = Calendar.current.isDate(start, inSameDayAs: end)
        return from + " – " + (sameDay ? end.formatted(date: .omitted, time: .shortened) : end.formatted(date: .abbreviated, time: .shortened))
    }
}

extension AttachmentItem {
    /// An invitation: a calendar part, or a file named like one.
    var isCalendar: Bool {
        mimeType.lowercased().hasPrefix("text/calendar") || mimeType.lowercased() == "application/ics"
            || filename.lowercased().hasSuffix(".ics")
    }
}

#if canImport(EventKit)
import EventKit

/// The event of an invitation into the user's calendar, with write-only
/// access: the app can add this one event and read nothing.
enum CalendarAccess {
    enum Failure: LocalizedError {
        case denied, noTime
        var errorDescription: String? {
            switch self {
            case .denied: "Hey Pigeon may not add events. Allow it in System Settings › Privacy & Security › Calendars."
            case .noTime: "The invitation has no start time."
            }
        }
    }

    /// The Mac only: the phone's build carries no calendar usage string.
    static var isAvailable: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Not on the main actor: the store is made, asked and written to in
    /// one place, off the UI.
    static func add(_ invite: CalendarInvite) async throws {
        guard let start = invite.start else { throw Failure.noTime }
        let store = EKEventStore()
        guard try await store.requestWriteOnlyAccessToEvents() else { throw Failure.denied }
        let event = EKEvent(eventStore: store)
        event.title = invite.summary.isEmpty ? "Invitation" : invite.summary
        event.startDate = start
        event.endDate = invite.end ?? start.addingTimeInterval(invite.isAllDay ? 0 : 3600)
        event.isAllDay = invite.isAllDay
        event.location = invite.location
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
    }
}
#endif
