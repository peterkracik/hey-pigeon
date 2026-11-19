// The app-side models and the pure helpers around them: address parsing,
// draft shapes, the thread transcript and folding, search operators, the
// view and provider enums, the formatters, the summary markup, the quote
// splitter, the rich-text serializer, the swipe geometry and the Spotlight
// fingerprint. No engine, no model, no device.

import Foundation
import Testing
@testable import HeyPigeon

/// A row with every field defaulted; tests set what they look at.
func makeRow(_ id: String = "t", account: String = "me@work.test", subject: String = "Subject",
             snippet: String = "Preview", at: Date = Date(), read: Bool = true, archived: Bool = false,
             count: Int = 1, from: String = "Ana", fromAddress: String = "ana@acme.test",
             scheduledAt: Date? = nil, followUp: Bool = false, needsReply: Bool = false, starred: Bool = false,
             triage: [String] = [], labels: [String] = ["INBOX"]) -> ThreadRow {
    ThreadRow(id: id, accountId: account, subject: subject, snippet: snippet, lastMessageAt: at, isRead: read,
              isArchived: archived, messageCount: count, fromSummary: from, lastFromAddress: fromAddress,
              scheduledAt: scheduledAt, isFollowUp: followUp, needsReply: needsReply, isStarred: starred,
              hasAttachment: false, priority: nil, triageLabelIds: triage, labels: labels)
}

func makeMessage(_ id: String, from: String = "Ana", address: String = "ana@acme.test", to: [String] = ["me"],
                 text: String? = nil, read: Bool = true, mine: Bool = false, draft: Bool = false,
                 at: Date = Date()) -> MessageItem {
    MessageItem(id: id, fromName: from, fromAddress: address, to: to, date: at, snippet: "snippet \(id)",
                bodyHTML: nil, bodyText: text, isRead: read, isMine: mine, isDraft: draft)
}

/// docs/specs/read-status.md, step 1: the words of a sent message's
/// status, and the mock's copy of the core's rule (R1, R3, R4).
struct ReadStatusTests {
    private let cal = Calendar.current
    private var noon: Date { cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())! }

    @Test func eachStateHasItsWords() {
        let now = noon
        #expect(ReadStatusText.line(ReadStatus(state: .sent), now: now) == "Sent")
        #expect(ReadStatusText.line(ReadStatus(state: .notDelivered, at: now), now: now) == "Not delivered")
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        #expect(ReadStatusText.line(ReadStatus(state: .replied, at: yesterday), now: now) == "Replied yesterday")
        let earlier = now.addingTimeInterval(-3_600)
        #expect(ReadStatusText.line(ReadStatus(state: .replied, at: earlier), now: now)
                == "Replied \(Formatters.rowTime(earlier, now: now))")
        #expect(ReadStatusText.line(ReadStatus(state: .replied), now: now) == "Replied")
        // Three states, three different symbols.
        #expect(Set([ReadState.sent, .notDelivered, .replied].map(ReadStatusText.symbol)).count == 3)
    }

    /// R1, R5: an open names the one recipient there was, and nobody when
    /// there were several; "hidden" is its own words and never "Opened".
    @Test func openedAndHiddenHaveTheirWords() {
        let now = noon
        let earlier = now.addingTimeInterval(-3_600)
        let time = Formatters.rowTime(earlier, now: now)
        let opened = ReadStatus(state: .opened, at: earlier)
        let names = ["peter@acme.test": "Peter"]
        #expect(ReadStatusText.line(opened, recipients: ["Peter@acme.test"], names: names, now: now) == "Opened by Peter \(time)")
        #expect(ReadStatusText.line(opened, recipients: ["ana@acme.test"], names: names, now: now) == "Opened by ana@acme.test \(time)")
        #expect(ReadStatusText.line(opened, recipients: ["peter@acme.test", "ana@acme.test"], names: names, now: now) == "Opened \(time)")
        #expect(ReadStatusText.line(opened, now: now) == "Opened \(time)")
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        #expect(ReadStatusText.line(ReadStatus(state: .opened, at: yesterday), recipients: ["peter@acme.test"], names: names, now: now)
                == "Opened by Peter yesterday")
        let hidden = ReadStatus(state: .hidden, at: earlier)
        #expect(ReadStatusText.line(hidden, recipients: ["peter@acme.test"], names: names, now: now) == "Delivered · opens hidden")
        #expect(!ReadStatusText.line(hidden, now: now).contains("Opened"))
        #expect(Set([ReadState.sent, .hidden, .opened, .notDelivered, .replied].map(ReadStatusText.symbol)).count == 5)
    }

    /// R5, R6: under the status, who could have opened it when that is not
    /// one person, and what the relay reported when it says more.
    @Test func detailsListWhatTheRelayReported() {
        let now = noon
        let t1 = now.addingTimeInterval(-3_600), t2 = now.addingTimeInterval(-1_800)
        let one = ReadStatus(state: .opened, at: t1, events: [ReadEvent(opened: true, at: t1)])
        // One open, one recipient: the status line said it all.
        #expect(ReadStatusText.details(one, recipients: ["a@x.test"], now: now).isEmpty)
        #expect(ReadStatusText.details(one, recipients: ["a@x.test", "b@x.test", "c@x.test"], now: now) == ["by one of 3 recipients"])
        let both = ReadStatus(state: .opened, at: t2, events: [ReadEvent(opened: true, at: t2), ReadEvent(opened: false, at: t1)])
        #expect(ReadStatusText.details(both, recipients: ["a@x.test"], now: now) == [
            "Opened · \(Formatters.messageTime(t2, now: now))",
            "Delivered to a device that hides opens · \(Formatters.messageTime(t1, now: now))",
        ])
        // A reply does not hide that it was opened before.
        let replied = ReadStatus(state: .replied, at: now, events: [ReadEvent(opened: true, at: t1)])
        #expect(ReadStatusText.details(replied, recipients: ["a@x.test"], now: now) == ["Opened · \(Formatters.messageTime(t1, now: now))"])
        // An untracked message has nothing under it.
        #expect(ReadStatusText.details(ReadStatus(state: .sent), recipients: ["a@x.test", "b@x.test"], now: now).isEmpty)
        // A long list ends in a count.
        let many = ReadStatus(state: .opened, at: now, events: (0..<8).map { ReadEvent(opened: true, at: now.addingTimeInterval(Double(-$0) * 600)) })
        let lines = ReadStatusText.details(many, recipients: ["a@x.test"], now: now)
        #expect(lines.count == ReadStatusText.maxEvents + 1)
        #expect(lines.last == "and 3 earlier")
    }

    /// The mock's copy of the precedence with what the relay reported:
    /// a reply, a bounce, an open, "hidden", sent.
    @Test func theMockRanksOpensLikeTheCore() {
        let t0 = noon
        let open = ReadEvent(opened: true, at: t0.addingTimeInterval(600))
        let hide = ReadEvent(opened: false, at: t0.addingTimeInterval(900))
        let mine = makeMessage("s", from: "Me", address: "me@work.test", mine: true, at: t0)
        func status(_ thread: [MessageItem], _ events: [ReadEvent]) -> ReadStatus? {
            MockEngine.withReadStatus(thread, events: ["s": events]).first { $0.id == "s" }.flatMap { $0.readStatus }
        }
        #expect(status([mine], [])?.state == .sent)
        #expect(status([mine], [hide]) == ReadStatus(state: .hidden, at: hide.at, events: [hide]))
        // An open outranks a later hidden fetch; the list is newest first.
        #expect(status([mine], [open, hide]) == ReadStatus(state: .opened, at: open.at, events: [hide, open]))
        let bounce = makeMessage("b", from: "Mail Delivery Subsystem", address: "mailer-daemon@googlemail.com", at: t0.addingTimeInterval(60))
        #expect(status([mine, bounce], [open])?.state == .notDelivered)
        let reply = makeMessage("r", at: t0.addingTimeInterval(1_200))
        #expect(status([mine, bounce, reply], [open, hide])?.state == .replied)
        // Events for a message that is not the user's say nothing.
        #expect(MockEngine.withReadStatus([reply], events: ["r": [open]])[0].readStatus == nil)
    }

    /// What an AI call is given of a thread (`ThreadDetail.transcript`) is
    /// the messages' text: nothing of a picture's address can be in it,
    /// whatever a body's HTML holds.
    @Test func aTranscriptCarriesNoPictureAddress() {
        let pixel = "https://o.heypigeon.app/o/0123456789abcdef0123456789abcdef.gif"
        let m = MessageItem(id: "m", fromName: "Me", fromAddress: "me@work.test", to: ["ana@acme.test"], date: Date(),
                            snippet: "See you Thursday.", bodyHTML: "<p>See you Thursday.</p><img src=\"\(pixel)\" width=\"1\" height=\"1\">",
                            bodyText: "See you Thursday.", isRead: true, isMine: true)
        let transcript = ThreadDetail.transcript(of: [m])
        #expect(transcript.contains("See you Thursday."))
        #expect(!transcript.contains("heypigeon.app") && !transcript.contains("0123456789abcdef") && !transcript.contains(".gif"))
    }

    /// A fixed place and language for Recent Opens' dates: Thursday 19
    /// November 2026, 11:49, UTC, British English.
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func on(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    private func openFormat(now: Date? = nil) -> RecentOpens.Format {
        RecentOpens.Format(now: now ?? on(2026, 11, 19, 11, 49), calendar: utc, locale: Locale(identifier: "en_GB"))
    }
    private func opened(_ id: String, _ date: Date, to: [String] = ["Peter"], subject: String = "Lunch") -> RecentOpenItem {
        RecentOpenItem(messageId: id, threadId: "t-\(id)", accountId: "me@work.test", subject: subject,
                       recipients: to, openedAt: date)
    }

    /// R7: a row names the one recipient there was and nobody when there
    /// were several.
    @Test func recentOpensNameOneRecipientAndNobodyOfSeveral() {
        let format = openFormat()
        let one = opened("a", on(2026, 11, 19, 8, 45))
        let several = opened("b", on(2026, 11, 17), to: ["Peter", "ana@acme.test", "Ben"], subject: "")
        let none = opened("c", on(2026, 10, 23), to: [])
        #expect(RecentOpens.who(one) == "Peter")
        #expect(RecentOpens.who(several) == "One of 3 recipients")
        #expect(!RecentOpens.who(several).contains("Peter"))
        #expect(RecentOpens.who(none) == "A recipient")
        #expect(RecentOpens.subject(several) == "(no subject)")
        #expect(RecentOpens.spoken(one, format: format) == "Peter opened Lunch, \(format.time(one.openedAt))")
        #expect(RecentOpens.title == "Recent Opens")
    }

    /// The headings: "Last 7 days", "Earlier this month", then a heading
    /// a month, named by the month — across a month's end, a year's end,
    /// and to the second at seven days.
    @Test func recentOpensStandUnderTheirHeadings() {
        let now = on(2026, 11, 19, 11, 49)
        let format = openFormat(now: now)
        let rows = [
            opened("thu", on(2026, 11, 19, 8, 45)),
            opened("fri", on(2026, 11, 13, 9, 0)),          // six days back
            opened("mon", on(2026, 11, 9)),                 // this month, before the week
            opened("sat", on(2026, 11, 1, 0, 0)),           // the month's first minute
            opened("oct31", on(2026, 10, 31, 23, 59)),      // the minute before it
            opened("oct9", on(2026, 10, 9)),
            opened("sep", on(2026, 9, 30)),
        ]
        let sections = RecentOpens.sections(rows, format: format)
        #expect(sections.map(\.title) == ["Last 7 days", "Earlier this month", "October", "September"])
        #expect(sections.map { $0.items.map(\.id) } == [["thu", "fri"], ["mon", "sat"], ["oct31", "oct9"], ["sep"]])
        #expect(sections.map(\.id) == ["week", "month", "2026-10", "2026-9"])
        #expect(RecentOpens.sections([], format: format).isEmpty)

        // Exactly seven days ago is no longer "Last 7 days"; a second less is.
        let edge = now.addingTimeInterval(-RecentOpens.recentSpan)
        #expect(RecentOpens.sections([opened("e", edge)], format: format).map(\.title) == ["Earlier this month"])
        #expect(RecentOpens.sections([opened("e", edge.addingTimeInterval(1))], format: format).map(\.title) == ["Last 7 days"])
        // A clock that runs ahead is recent, not a month of its own.
        #expect(RecentOpens.sections([opened("f", now.addingTimeInterval(3_600))], format: format).map(\.title) == ["Last 7 days"])

        // Early in a month the week reaches into the month before, and
        // what is older there stands under that month's name.
        let earlyDec = openFormat(now: on(2026, 12, 2, 9, 0))
        let december = RecentOpens.sections([opened("a", on(2026, 11, 28)), opened("b", on(2026, 11, 20))], format: earlyDec)
        #expect(december.map(\.title) == ["Last 7 days", "November"])

        // Across a year's end the month carries its year; this year's does not.
        let january = openFormat(now: on(2027, 1, 20, 9, 0))
        let winter = RecentOpens.sections([
            opened("a", on(2027, 1, 18)), opened("b", on(2027, 1, 3)),
            opened("c", on(2026, 12, 24)), opened("d", on(2026, 11, 9)),
        ], format: january)
        #expect(winter.map(\.id) == ["week", "month", "2026-12", "2026-11"])
        #expect(winter[2].title.contains("December") && winter[2].title.contains("2026"))
        #expect(winter[3].title.contains("November") && winter[3].title.contains("2026"))
        #expect(!winter[1].title.contains("2027"))
    }

    /// The row's time: weekday and time of day within the last seven
    /// days; weekday, day and month before that, with the year only when
    /// it is not this one — in the user's language, never spelled here.
    @Test func recentOpensSayWhenInTheUsersWords() {
        let format = openFormat()
        // Within the week (a week ago this evening is still inside it): "Thu 18:59".
        let recent = format.time(on(2026, 11, 12, 18, 59))
        #expect(recent.hasPrefix("Thu") && recent.hasSuffix("18:59"))
        #expect(!recent.contains("Nov"))
        // Older, this year: "Mon, 9 Nov" — no time of day, no year.
        let older = format.time(on(2026, 11, 9, 14, 30))
        #expect(older.contains("Mon") && older.contains("9") && older.contains("Nov"))
        #expect(!older.contains("14") && !older.contains("2026"))
        let october = format.time(on(2026, 10, 23, 9, 0))
        #expect(october.contains("Fri") && october.contains("23") && october.contains("Oct"))
        // Another year: the year is there.
        #expect(format.time(on(2025, 12, 24, 9, 0)).contains("2025"))
        // Another language gets its own words, not these.
        let german = RecentOpens.Format(now: on(2026, 11, 19, 11, 49), calendar: utc, locale: Locale(identifier: "de_DE"))
        #expect(german.time(on(2026, 10, 23, 9, 0)).contains("Okt"))
        #expect(german.heading(on(2026, 10, 23)).title == "Oktober")
        // The headings "Last 7 days" and "Earlier this month" are the app's own words.
        #expect(german.heading(on(2026, 11, 18)).title == "Last 7 days")
    }

    /// The sheet's words when it has no rows, and under them when it has:
    /// honest about a build that cannot track and about read status being
    /// off, and never calling a hidden delivery an open.
    @Test func recentOpensSayWhyTheyAreEmpty() {
        #expect(RecentOpens.emptyState(available: false, anyAccountOn: false).title == "Read status is not available in this build")
        #expect(RecentOpens.emptyState(available: false, anyAccountOn: true).title == "Read status is not available in this build")
        let off = RecentOpens.emptyState(available: true, anyAccountOn: false)
        #expect(off.title == "Read status is off")
        #expect(off.detail.contains("Settings › Accounts"))
        let empty = RecentOpens.emptyState(available: true, anyAccountOn: true)
        #expect(empty.title == "No opens yet")
        #expect(empty.detail.contains("Apple Mail hides opens"))
        #expect(RecentOpens.footer(anyAccountOn: true).contains("a device that hides opens is not listed"))
        // How far back, and whose memory an old row is.
        #expect(RecentOpens.footer(anyAccountOn: true).contains("Opens of the last 90 days, at most 100"))
        #expect(RecentOpens.footer(anyAccountOn: true).contains("The relay keeps its own record of a message for 30 days"))
        #expect(!RecentOpens.footer(anyAccountOn: true).contains("Read status is off"))
        #expect(RecentOpens.footer(anyAccountOn: false).hasSuffix("Read status is off, so nothing new is added."))
    }

    @Test func theMockFollowsTheCoresRule() {
        let t0 = noon
        let thread = MockEngine.withReadStatus([
            makeMessage("s1", from: "Me", address: "me@work.test", mine: true, at: t0),
            makeMessage("r", at: t0.addingTimeInterval(60)),
            makeMessage("s2", from: "Me", address: "me@work.test", mine: true, at: t0.addingTimeInterval(120)),
            makeMessage("b", from: "Mail Delivery Subsystem", address: "MAILER-DAEMON@googlemail.com",
                        at: t0.addingTimeInterval(180)),
            makeMessage("s3", from: "Me", address: "me@work.test", mine: true, at: t0.addingTimeInterval(240)),
            makeMessage("d", from: "Me", address: "me@work.test", mine: true, draft: true, at: t0.addingTimeInterval(300)),
        ])
        func status(_ id: String) -> ReadStatus? { thread.first { $0.id == id }.flatMap { $0.readStatus } }
        #expect(thread.count == 6)
        // A reply overrides the bounce that came later in the thread.
        #expect(status("s1") == ReadStatus(state: .replied, at: t0.addingTimeInterval(60)))
        // Only a bounce followed: not delivered, and not "replied".
        #expect(status("s2") == ReadStatus(state: .notDelivered, at: t0.addingTimeInterval(180)))
        // Nothing but the user's own draft followed.
        #expect(status("s3") == ReadStatus(state: .sent))
        // Other people's mail, the bounce and the draft have none.
        #expect(status("r") == nil)
        #expect(status("b") == nil)
        #expect(status("d") == nil)
    }

    @Test @MainActor func aMockThreadShowsWhatBecameOfSentMail() async throws {
        // t1 has three messages: theirs, mine, theirs.
        let detail = try await MockEngine().thread(id: "t1")
        let messages = try #require(detail?.messages)
        #expect(messages.count == 3)
        // The mock alternates them and me: my message with theirs after it
        // is answered; anyone else's has no status.
        #expect(messages[1].readStatus?.state == .replied)
        #expect(messages[0].readStatus == nil)
    }
}

struct SuggestionPromptTests {
    private var prague: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Prague")!
        return c
    }

    @Test func aDayAndHourBecomeAReminderInTheUsersTimeZone() throws {
        let at = try #require(SuggestionPrompt.remindDate(day: "2026-11-06", hour: 7, calendar: prague))
        let c = prague.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        #expect(c == DateComponents(year: 2026, month: 11, day: 6, hour: 7, minute: 0))
        // 06:00 UTC: Prague is UTC+1 in November.
        #expect(at.timeIntervalSince1970 == 1_793_944_800)
    }

    @Test func notADayIsNoReminder() {
        #expect(SuggestionPrompt.remindDate(day: "Friday", hour: 8, calendar: prague) == nil)
        #expect(SuggestionPrompt.remindDate(day: "", hour: 8, calendar: prague) == nil)
        #expect(SuggestionPrompt.remindDate(day: "2026-02-30", hour: 8, calendar: prague) == nil)
        // An hour out of range falls back to 8 rather than dropping the day.
        let at = SuggestionPrompt.remindDate(day: "2026-11-06", hour: 31, calendar: prague)
        #expect(at.map { prague.component(.hour, from: $0) } == 8)
    }

    @Test func theModelsActionMapsToAProposal() {
        #expect(SuggestionPrompt.suggestion(action: "reply", remindOn: "", hour: 8, calendar: prague) == .needsReply)
        #expect(SuggestionPrompt.suggestion(action: "nothing", remindOn: "2026-11-06", hour: 8, calendar: prague) == nil)
        #expect(SuggestionPrompt.suggestion(action: "remind", remindOn: "soon", hour: 8, calendar: prague) == nil)
        let at = SuggestionPrompt.remindDate(day: "2026-11-06", hour: 8, calendar: prague)!
        #expect(SuggestionPrompt.suggestion(action: "remind", remindOn: "2026-11-06", hour: 8, calendar: prague) == .remind(at: at))
    }

    @Test func thePromptCarriesTheWeekdaySoRelativeDatesResolve() {
        // Sunday 1 November 2026, 13:05 UTC = 14:05 in Prague.
        let received = Date(timeIntervalSince1970: 1_793_538_300)
        let p = SuggestionPrompt.prompt(subject: "", from: "ana@acme.test", body: "See you Friday?",
                                        received: received, calendar: prague)
        #expect(p.hasPrefix("Received: Sunday, 1 November 2026, 14:05\n"))
        #expect(p.contains("Subject: (no subject)") && p.hasSuffix("See you Friday?"))
    }
}

struct EmailAddressTests {
    @Test func parsesHeaderText() {
        #expect(EmailAddress.address(in: "\"Ana Novak\" <ana@acme.test>") == "ana@acme.test")
        #expect(EmailAddress.address(in: "  ana@acme.test ") == "ana@acme.test")
        // A name that holds an address of its own does not choose the sender.
        #expect(EmailAddress.address(in: "\"Support <alerts@bank.test>\" <someone@else.test>") == "someone@else.test")
        #expect(EmailAddress.displayName(in: "\"Ana Novak\" <ana@acme.test>") == "Ana Novak")
        #expect(EmailAddress.displayName(in: "<ana@acme.test>") == "ana@acme.test")
        #expect(EmailAddress.displayName(in: "ana@acme.test") == "ana@acme.test")
    }

    /// The user's own mail is the account address exactly: "hana@…" on
    /// the "ana@…" account used to count as the user's (a substring test).
    @Test func sameMailboxIsWholeAddressNotSubstring() {
        #expect(EmailAddress.same("Ana <ANA@acme.test>", "ana@acme.test"))
        #expect(!EmailAddress.same("hana@acme.test", "ana@acme.test"))
        #expect(!EmailAddress.same("ana@acme.test.evil", "ana@acme.test"))
    }

    @Test func plausibleAddressesBecomeChips() {
        #expect(EmailAddress.isPlausible("ana@acme.test"))
        #expect(EmailAddress.isPlausible("thomas+news@mail.example.com"))
        for bad in ["ana@", "@acme.test", "ana acme@x.y", "ana@acme", "ana@acme.", "ana@@acme.test", "ana@.test"] {
            #expect(!EmailAddress.isPlausible(bad), "\(bad)")
        }
    }
}

struct Base64LengthTests {
    @Test func decodedLengthMatchesDecodingWithAndWithoutPaddingAndLineBreaks() {
        for n in 0..<40 {
            let data = Data((0..<n).map { UInt8($0 % 256) })
            let encoded = data.base64EncodedString()
            #expect(Base64.decodedLength(encoded) == n)
            #expect(Base64.decodedLength(encoded.replacingOccurrences(of: "=", with: "")) == n)
            #expect(Base64.decodedLength(data.base64EncodedString(options: .lineLength64Characters)) == n)
        }
    }
}

struct ThreadModelTests {
    @Test func leadSenderSkipsTheUserAndTheCount() {
        #expect(makeRow(from: "Ana, Me (4)").leadSenderName == "Ana")
        #expect(makeRow(from: "Tomáš (3)").leadSenderName == "Tomáš")
        #expect(makeRow(from: "Me (2)").leadSenderName == nil)
        #expect(makeRow(from: "").leadSenderName == nil)
    }

    @Test func transcriptAndParticipantsLeaveDraftsOut() {
        let detail = ThreadDetail(thread: makeRow(), messages: [
            makeMessage("1", from: "Ana", text: "Can you look?"),
            makeMessage("2", from: "Peter", address: "me@work.test", text: "Sure.", mine: true),
            makeMessage("3", from: "Marek", address: "marek@acme.test"),
            makeMessage("4", from: "Peter", address: "me@work.test", text: "unsent", mine: true, draft: true),
        ])
        #expect(detail.transcript == "Ana: Can you look?\n\nMe: Sure.\n\nMarek: snippet 3")
        #expect(detail.participantNames == "Ana, Marek")
        let mineOnly = ThreadDetail(thread: makeRow(), messages: [makeMessage("1", mine: true)])
        #expect(mineOnly.participantNames == nil)
    }

    @Test func transcriptKeepsWhatEachAuthorWroteAndFits() {
        let quoted = "Sounds good.\n\nOn Mon, Ana wrote:\n> Lunch?\n>\n> A"
        let detail = ThreadDetail(thread: makeRow(), messages: [
            makeMessage("1", from: "Ana", text: "Lunch?"),
            makeMessage("2", from: "Peter", address: "me@work.test", text: quoted, mine: true),
        ])
        #expect(detail.transcript == "Ana: Lunch?\n\nMe: Sounds good.")
        // Outlook's header block and an "On … wrote:" line fold without
        // "> " marks; a "From:" alone, or history with nothing before it, stays.
        #expect(QuotedText.ownText("Yes.\n\nFrom: Ana\nSent: Monday\nTo: me\n\nLunch?") == "Yes.")
        #expect(QuotedText.ownText("Yes.\n\nOn Mon, 3 Nov 2026, Ana wrote:\nLunch?") == "Yes.")
        #expect(QuotedText.ownText("From: the top\nnothing else") == "From: the top\nnothing else")
        #expect(QuotedText.ownText("> only a quote") == "> only a quote")
        // "Quote in reply" writes the shape the fold reads back.
        let reply = "Yes.\n\n" + QuotedText.quote("Lunch?\n\nAt one.\n", from: "Ana", address: "ana@acme.test", date: "Mon, 3 Nov 2026")
        #expect(reply == "Yes.\n\nOn Mon, 3 Nov 2026, Ana <ana@acme.test> wrote:\n> Lunch?\n>\n> At one.")
        #expect(QuotedText.split(reply)?.main == "Yes.")
        // Over budget: the newest messages stay, the oldest are counted out.
        let long = String(repeating: "x", count: 5_000)
        let many = (1...5).map { makeMessage("\($0)", from: "Ana", text: long) }
        let t = ThreadDetail.transcript(of: many)
        #expect(t.hasPrefix("[3 earlier messages omitted]\n\nAna: xxxx"))
        #expect(t.hasSuffix(" …"))
        #expect(t.count < ThreadDetail.transcriptBudget + 100)
    }

    @Test func theToLineNamesThePeopleTheThreadKnows() {
        // By address in any case; "me" and a stranger's address as they are.
        let names = ThreadDetail.knownNames([
            makeMessage("a", from: "Ana", address: "Ana@Acme.test"),
            makeMessage("b", from: "Ben", address: "ben@acme.test"),
            makeMessage("c", from: "Ana Maria", address: "ana@acme.test"),
        ])
        #expect(ThreadDetail.recipientLine(["me", "ana@acme.test", "BEN@acme.test", "eve@else.test"], names: names)
                == "me, Ana, Ben, eve@else.test")
        #expect(ThreadDetail.recipientLine([], names: names).isEmpty)
    }

    @Test func longThreadsFoldTheirMiddle() {
        func messages(_ n: Int, unread: Set<Int> = []) -> [MessageItem] {
            (0..<n).map { makeMessage("\($0)", read: !unread.contains($0)) }
        }
        #expect(ThreadDetail.foldedRange([]) == nil)
        #expect(ThreadDetail.foldedRange(messages(4)) == nil) // only one in the middle: nothing to fold
        #expect(ThreadDetail.foldedRange(messages(5)) == 1..<3)
        // An unread run before the last two stays out of the fold.
        #expect(ThreadDetail.foldedRange(messages(7, unread: [3, 4])) == 1..<3)
        #expect(ThreadDetail.foldedRange(messages(5, unread: [1, 2])) == nil)
    }

    @Test func replyGoesToTheSenderAndReplyAllCopiesTheRest() {
        let row = makeRow(subject: "Contract")
        let theirs = makeMessage("1", address: "ana@acme.test", to: ["me", "marek@acme.test", ""])
        let reply = SendDraft.reply(to: theirs, in: row, all: false, history: "h")
        #expect(reply.to == ["ana@acme.test"] && reply.cc.isEmpty)
        #expect(reply.subject == "Re: Contract")
        #expect(reply.replyToThreadId == row.id && reply.fromAccountId == row.accountId && reply.history == "h")
        let all = SendDraft.reply(to: theirs, in: row, all: true, history: nil)
        #expect(all.cc == ["marek@acme.test"])
        // A reply to the user's own message goes to its recipients.
        let mine = makeMessage("2", to: ["me", "ana@acme.test"], mine: true)
        #expect(SendDraft.reply(to: mine, in: row, all: false, history: nil).to == ["ana@acme.test"])
        // One "Re:", whatever its case.
        #expect(SendDraft.reply(to: theirs, in: makeRow(subject: "RE: Contract"), all: false, history: nil).subject == "RE: Contract")
    }

    @Test func replyGoesWhereTheSenderAskedAndNeverToTheUsersOwnAlias() {
        let row = makeRow(subject: "Booking")
        var list = makeMessage("1", address: "no-reply@hotel.test", to: ["me", "marek@acme.test", "alias@work.test"])
        list.replyTo = ["desk@hotel.test"]
        #expect(SendDraft.reply(to: list, in: row, all: false, history: nil).to == ["desk@hotel.test"])
        #expect(SendDraft.reply(to: list, in: row, all: false, history: nil).repliesElsewhere)
        let all = SendDraft.reply(to: list, in: row, all: true, history: nil, mine: ["alias@work.test"])
        #expect(all.to == ["desk@hotel.test"] && all.cc == ["marek@acme.test"])
        // A Reply-To that is the sender itself redirects nothing.
        var same = makeMessage("3", address: "ana@acme.test")
        same.replyTo = ["Ana@acme.test"]
        #expect(!SendDraft.reply(to: same, in: row, all: false, history: nil).repliesElsewhere)
        // The row's state, as VoiceOver says it on both apps.
        #expect(makeRow().spokenState(showsDone: true) == "")
        #expect(makeRow(read: false, needsReply: true, starred: true).spokenState(showsDone: true) == "Unread, Need reply, Pinned")
        // Mail sent from an alias is the user's own: the reply follows it.
        let sent = makeMessage("2", address: "Alias@work.test", to: ["ana@acme.test"])
        let followUp = SendDraft.reply(to: sent, in: row, all: false, history: nil, mine: ["alias@work.test"])
        #expect(followUp.to == ["ana@acme.test"] && followUp.fromAddress == "Alias@work.test")
        // Mail that came to the alias is answered from it; other mail
        // from the account's own address (nil).
        #expect(all.fromAddress == "alias@work.test")
        #expect(SendDraft.reply(to: list, in: row, all: false, history: nil).fromAddress == nil)
        // The open message says where a reply will go, when not to its sender.
        #expect(list.repliesGoTo == ["desk@hotel.test"])
        #expect(same.repliesGoTo.isEmpty && sent.repliesGoTo.isEmpty)
        // Into a composer without style blocks or cid: pictures.
        #expect(ComposerHTML.clean("<STYLE type=\"text/css\">p{display:none}</style><p>Hi<img alt=\"\" src=\"cid:logo@x\"> <img src=\"https://x.test/a.png\"></p>")
            == "<p>Hi <img src=\"https://x.test/a.png\"></p>")
    }

    @Test func forwardQuotesTheMessageUnderOneFwd() {
        let m = makeMessage("1", from: "Ana", address: "ana@acme.test", text: "The deck.")
        let d = SendDraft.forward(of: m, in: makeRow(subject: "Deck"))
        #expect(d.subject == "Fwd: Deck")
        #expect(d.to.isEmpty)
        #expect(d.bodyText.contains("From: Ana <ana@acme.test>") && d.bodyText.hasSuffix("The deck."))
        #expect(SendDraft.forward(of: m, in: makeRow(subject: "fwd: Deck")).subject == "fwd: Deck")
        // The signature goes over the quote, not under the forwarded text.
        let signed = SendDraft.forward(of: m, in: makeRow(subject: "Deck"), signature: "Peter")
        #expect(signed.bodyText.hasPrefix("\n\nPeter\n\n---------- Forwarded message ----------\n"))
        #expect(signed.bodyText.contains("\nSubject: Deck\n"))
    }

    @Test func textStillInARecipientFieldCountsOnceItIsAnAddress() {
        #expect(EmailAddress.pending(" Boss@X.com,") == "boss@x.com")
        #expect(EmailAddress.pending("ana@") == nil)
        #expect(EmailAddress.pending("") == nil)
    }
}

struct EnumTests {
    @Test func searchFiltersComposeTheCoreOperators() {
        var f = SearchFilters()
        #expect(f.isEmpty && f.operators.isEmpty)
        f.from = SearchPerson(name: "Ana", address: "ana@acme.test")
        f.to = SearchPerson(name: "Sam", address: "sam@x.test")
        f.unreadOnly = true
        f.accountId = "me@work.test"
        #expect(!f.isEmpty)
        #expect(f.operators == ["from:ana@acme.test", "to:sam@x.test", "is:unread", "account:me@work.test"])
    }

    @Test func viewsKnowHowTheyPageAndWhatDoneDoes() {
        #expect(MailView.inbox.archivesOut && MailView.label(id: "L", name: "x").archivesOut)
        #expect(!MailView.archive.archivesOut && !MailView.all.archivesOut)
        #expect(!MailView.scheduled.isPaged && !MailView.needReply.isPaged && MailView.inbox.isPaged)
        #expect(MailView.label(id: "Label_1", name: "Invoices").countKey == "label:Label_1")
        #expect(MailView.label(id: "Label_1", name: "Invoices").title == "Invoices")
    }

    @Test func providersAndPrioritiesRoundTrip() {
        for p in AIProvider.allCases + [.other("mlx")] {
            #expect(AIProvider(rawValue: p.rawValue) == p)
        }
        #expect(AIProvider.apple.title.hasSuffix("on this \(Device.name)"))
        #expect(AIProvider.keyed.allSatisfy(\.takesKey) && !AIProvider.apple.takesKey)
        #expect(TriageClassifier.anthropic.aiProvider == .anthropic && TriageClassifier.jev.aiProvider == nil)
        #expect([TriageLevel.high, .spam, .medium, .low].sorted() == [.spam, .low, .medium, .high])
        #expect(RowAction(rawValue: "unread") == .read && RowAction(rawValue: "needreply") == .needReply)
    }

    @Test func deviceNamesFollowTheModel() {
        #expect(Device.name(forModel: "iPad13,1") == "iPad")
        #expect(Device.name(forModel: "iPhone17,2") == "iPhone")
        #expect(Device.name(forModel: "arm64") == "iPhone")
        #expect(["iPhone", "iPad", "Mac"].contains(Device.name))
    }
}

struct FormatterTests {
    private let cal = Calendar.current
    /// Noon today, so ±hours never cross midnight by accident.
    private var noon: Date { cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())! }

    @Test func rowTimeIsRelativeToNow() {
        let now = noon
        #expect(Formatters.rowTime(now.addingTimeInterval(-3_600), now: now) != "Yesterday")
        #expect(Formatters.rowTime(cal.date(byAdding: .day, value: -1, to: now)!, now: now) == "Yesterday")
        // A fixed `now` in the past: the answers follow it, not the clock.
        let lastYear = cal.date(byAdding: .year, value: -1, to: now)!
        #expect(Formatters.rowTime(cal.date(byAdding: .day, value: -1, to: lastYear)!, now: lastYear) == "Yesterday")
    }

    @Test func reminderBadgesNameTomorrow() {
        let now = noon
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now)!
        #expect(Formatters.reminder(tomorrow, now: now).hasPrefix("Tomorrow "))
        #expect(!Formatters.reminder(now.addingTimeInterval(600), now: now).contains("Tomorrow"))
        #expect(Formatters.reminder(cal.date(byAdding: .day, value: 30, to: now)!, now: now).contains(","))
    }

    /// A clock time on a day of the calendar, for a pinned `now`.
    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func anOpenMessagesTimeIsAsShortAsItsDayAllows() {
        // Thursday 19 November 2026, noon. The strings follow the locale
        // (12 or 24 hours, the order of day and month), so each is
        // compared with the pieces the row's own formatter gives.
        let now = at(2026, 11, 19, 12, 0)
        let early = Formatters.messageTime(at(2026, 11, 19, 5, 57), now: now)
        let morning = Formatters.messageTime(at(2026, 11, 19, 9, 12), now: now)
        // Today: the time alone, as in the list.
        #expect(early == Formatters.rowTime(at(2026, 11, 19, 5, 57), now: now))
        #expect(early != morning)
        #expect(Formatters.messageTime(at(2026, 11, 18, 5, 57), now: now) == "Yesterday, \(early)")
        // Within the week: the weekday.
        let monday = at(2026, 11, 16, 9, 12)
        #expect(Formatters.messageTime(monday, now: now) == "\(Formatters.rowTime(monday, now: now)), \(morning)")
        // Older, this year: the day and the month, no year.
        let october = at(2026, 10, 12, 9, 12)
        let thisYear = Formatters.messageTime(october, now: now)
        #expect(thisYear == "\(Formatters.rowTime(october, now: now)), \(morning)")
        #expect(!thisYear.contains("2026"))
        // Another year: said.
        let lastYear = Formatters.messageTime(at(2025, 11, 12, 9, 12), now: now)
        #expect(lastYear.contains("2025"))
        #expect(lastYear.hasSuffix(", \(morning)"))
        // The year turns: a week-old message of December is not this year's.
        #expect(Formatters.messageTime(at(2026, 12, 20, 9, 12), now: at(2027, 1, 5, 12, 0)).contains("2026"))
        // A date ahead of `now` (a sender's fast clock) is no weekday:
        // it reads as it will a month on.
        let ahead = at(2026, 11, 21, 9, 12)
        #expect(Formatters.messageTime(ahead, now: now) == Formatters.messageTime(ahead, now: at(2026, 12, 19, 12, 0)))
    }

    @Test func dayAndDueBuckets() {
        let now = noon
        let day = Formatters.dayGrouper(now: now)
        #expect(day(now) == "Today")
        #expect(day(cal.date(byAdding: .day, value: -3, to: now)!) == "Last 7 days")
        #expect(day(cal.date(byAdding: .day, value: -10, to: now)!) == "Older")
        let due = Formatters.dueGrouper(now: now)
        #expect(due(cal.date(byAdding: .day, value: -1, to: now)!) == "Overdue")
        #expect(due(now.addingTimeInterval(3_600)) == "Today")
        #expect(due(cal.date(byAdding: .day, value: 1, to: now)!) == "Tomorrow")
        #expect(due(cal.date(byAdding: .day, value: 3, to: now)!) == "This week")
        #expect(due(cal.date(byAdding: .day, value: 10, to: now)!) == "Later")
    }
}

struct TextFormattingTests {
    @Test func summaryMarkupKeepsBulletsAndBoldOnly() {
        let lines = SummaryMarkup.parse("- **Ana** wants slides\n\n2) Pay *rent*\nplain line\n* last")
        #expect(lines.map(\.bullet) == [true, true, false, true])
        #expect(String(lines[0].text.characters) == "Ana wants slides")
        #expect(lines[0].text.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
        // A single * is not markup; an unmatched ** stays literal.
        #expect(String(lines[1].text.characters) == "Pay *rent*")
        #expect(String(SummaryMarkup.inline("a ** b").characters) == "a ** b")
    }

    @Test func quotedHistorySplitsOffTheEnd() throws {
        let split = try #require(MessageBodyView.splitQuoted("Sounds good.\n\nOn Mon, Ana wrote:\n> Lunch?\n>\n> A"))
        #expect(split.main == "Sounds good.")
        #expect(split.quoted.hasPrefix("On Mon, Ana wrote:"))
        // Nothing before the quote, or no quote at all: never hidden.
        #expect(MessageBodyView.splitQuoted("> only a quote") == nil)
        #expect(MessageBodyView.splitQuoted("Hi\n> inline\nand more") == nil)
    }

    @Test func richTextBecomesHTMLOnlyWhenFormatted() {
        #expect(RichText.html(AttributedString("plain <text>")) == nil)
        var bold = AttributedString("bold")
        bold.inlinePresentationIntent = .stronglyEmphasized
        var link = AttributedString("site")
        link.link = URL(string: "https://x.test/?a=1&b=2")
        let html = RichText.html(AttributedString("a < b\n") + bold + AttributedString(" ") + link)
        #expect(html == "a &lt; b<br><b>bold</b> <a href=\"https://x.test/?a=1&amp;b=2\">site</a>")
    }

    /// A saved draft reopens with its formatting: the html part reads back
    /// into what wrote it. Anything else opens as plain text.
    @Test func aSavedDraftsHTMLReadsBackIntoTheEditor() throws {
        // The phone's editor only: the Mac's loads the html part as it is
        // (these tests also build for the Mac).
        #if os(iOS)
        let html = "a &lt; b<br><b>bold</b> <i>it</i> <u>under</u> <s>gone</s> <a href=\"https://x.test/?a=1&amp;b=2\" rel=\"noopener noreferrer\">site</a>"
        let rich = try #require(RichText.attributed(html: html))
        #expect(String(rich.characters) == "a < b\nbold it under gone site")
        #expect(RichText.html(rich) == html.replacingOccurrences(of: " rel=\"noopener noreferrer\"", with: ""))
        // The Mac editor's paragraphs read as blank lines; anything richer
        // (a list, Gmail's blocks) opens as plain text.
        let mac = try #require(RichText.attributed(html: "<p>Hi <b>Ana</b>,</p><p><br></p><p>see you</p>"))
        #expect(String(mac.characters) == "Hi Ana,\n\n\n\n\nsee you")
        #expect(RichText.attributed(html: "<ul><li>one</li></ul>") == nil)
        // Only web and mail links come back as links.
        let odd = try #require(RichText.attributed(html: "<a href=\"javascript:alert(1)\">x</a>"))
        #expect(odd.runs.allSatisfy { $0.link == nil })
        #endif
        var draft = SendDraft()
        draft.bodyText = "plain"
        #expect(String(ComposeView.richBody(of: draft).characters) == "plain")
    }

    @Test func swipeTiersArmAtTheirDistances() {
        #expect(SwipeGeometry.tier(for: 10) == 0)
        #expect(SwipeGeometry.tier(for: SwipeGeometry.shortThreshold) == 1)
        #expect(SwipeGeometry.tier(for: -SwipeGeometry.longThreshold) == -2)
        #expect(SwipeGeometry.tier(for: -100) == -1)
        #expect(SwipeGeometry.rubberBand(100) == 100)
        #expect(SwipeGeometry.rubberBand(-400) > -400 && SwipeGeometry.rubberBand(-400) < -SwipeGeometry.longThreshold)
    }
}

struct SpotlightFingerprintTests {
    private let account = MailAccount(id: "a", email: "a@x.test", displayName: "Work", color: .sky, avatarURL: nil, signature: "")

    @Test func fingerprintMovesWithWhatTheIndexShows() {
        let row = makeRow(read: false)
        let base = SpotlightIndexer.fingerprint(row, labelNames: ["Travel"], account: account)
        #expect(base == SpotlightIndexer.fingerprint(row, labelNames: ["Travel"], account: account))
        #expect(base != SpotlightIndexer.fingerprint(makeRow(read: true), labelNames: ["Travel"], account: account))
        #expect(base != SpotlightIndexer.fingerprint(row, labelNames: ["Invoices"], account: account))
        let renamed = MailAccount(id: "a", email: "a@x.test", displayName: "Job", color: .sky, avatarURL: nil, signature: "")
        #expect(base != SpotlightIndexer.fingerprint(row, labelNames: ["Travel"], account: renamed))
    }

    /// The fingerprints outlive the process (they are kept on disk so a
    /// launch does not index everything again), so the hash must not be
    /// `Hasher`, which is seeded per process.
    @Test func fingerprintsAreStableAndRoundTripThroughDisk() {
        #expect(SpotlightIndexer.fnv1a("") == 0xcbf2_9ce4_8422_2325)
        #expect(SpotlightIndexer.fnv1a("hey pigeon") == 0xd4dc_a193_4a70_0c2d)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fingerprints-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("spotlight-fingerprints.json")
        let map = ["t": SpotlightIndexer.fingerprint(makeRow(read: false), labelNames: ["Travel"], account: account), "u": -7]
        SpotlightIndexer.Fingerprints.save(map, to: url)
        #expect(SpotlightIndexer.Fingerprints.load(from: url) == map)
        #expect(SpotlightIndexer.Fingerprints.load(from: dir.appendingPathComponent("missing.json")).isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }
}

struct PrivateCloudComputeGateTests {
    /// The build has no Private Cloud Compute entitlement, so the cloud
    /// model is never offered and triage decides on the device: the
    /// framework traps on a request from an unentitled app.
    @Test func cloudModelStaysOffWithoutTheEntitlement() {
        #expect(!PrivateCloudComputeProvider.isEnabledInBuild)
        #expect(!PrivateCloudComputeProvider().availability.isAvailable)
        #expect(PrivateCloudComputeProvider().availability.reason?.contains("doesn't include") == true)
        #expect(TriageProfile.current().decideProvider.id == SystemModelProvider().id)
    }
}

struct RowActionPresentationTests {
    /// One vocabulary for every surface that names a row action: the
    /// phone's swipes and menus, the thread's bar, the Mac's hover bar and
    /// the command palette read these.
    @Test func labelsFollowTheRowsState() {
        let fresh = makeRow(read: false)
        #expect(RowAction.allCases.map { $0.label(for: fresh) }
            == ["Mark done", "Delete", "Remind me", "Need reply", "Pin", "Mark read"])
        let handled = makeRow(read: true, archived: true, scheduledAt: Date().addingTimeInterval(3600),
                              needsReply: true, starred: true)
        #expect(RowAction.allCases.map { $0.label(for: handled) }
            == ["Mark not done", "Delete", "Remove reminder", "Clear need reply", "Unpin", "Mark unread"])
    }

    @Test func shortLabelsAndGlyphsFollowIt() {
        let fresh = makeRow(read: false)
        #expect(RowAction.allCases.map { $0.shortLabel(for: fresh) }
            == ["Done", "Delete", "Remind me", "Need reply", "Pin", "Read"])
        #expect(RowAction.allCases.map { $0.glyph(for: fresh) }
            == ["checkmark", "trash", "clock", "arrowshape.turn.up.left", "pin", "envelope.open"])
        let handled = makeRow(read: true, archived: true, scheduledAt: Date().addingTimeInterval(3600),
                              needsReply: true, starred: true)
        #expect(RowAction.allCases.map { $0.shortLabel(for: handled) }
            == ["Not done", "Delete", "Remove reminder", "Clear reply", "Unpin", "Unread"])
        #expect(RowAction.allCases.map { $0.glyph(for: handled) }
            == ["arrow.uturn.backward", "trash", "clock.badge.xmark", "arrowshape.turn.up.left", "pin.slash", "envelope.badge"])
    }

    /// The swipe removes a set reminder; the items that open the sheet
    /// change it, and say so.
    @Test func theSheetsItemChangesAReminder() {
        #expect(RowAction.remindSheetLabel(for: makeRow()) == "Remind me")
        #expect(RowAction.remindSheetLabel(for: makeRow(scheduledAt: Date().addingTimeInterval(3600))) == "Change reminder")
    }
}

struct ReadableLayoutTests {
    /// The iPad's readable column: centred when the screen is wider, the
    /// whole width when it is not.
    @Test func marginsCentreTheColumn() {
        #expect(ReadableLayout.margin(in: 390) == 0)
        #expect(ReadableLayout.margin(in: ReadableLayout.maxWidth) == 0)
        #expect(ReadableLayout.margin(in: ReadableLayout.maxWidth + 200) == 100)
    }
}

struct RowActionKeyTests {
    /// The letters are the Mac's (`RowAction.key`).
    @Test func rowKeysAreOneMap() {
        #expect(RowAction.allCases.map(\.key) == ["E", "#", "H", "N", "S", "U"])
    }
}

struct PullDownTests {
    @Test func aShortPullLetGoOpensTheSearch() {
        var pull = PullDown()
        pull.update(overscroll: 20)
        pull.update(overscroll: 60)
        pull.update(overscroll: 10)   // the list springing back under the finger
        #expect(pull.released())
    }

    @Test func aRestingFingerAndARefreshOpenNothing() {
        var pull = PullDown()
        pull.update(overscroll: 12)
        #expect(!pull.released())
        pull.update(overscroll: 150)   // the system's pull to refresh
        #expect(!pull.released())
    }

    @Test func eachDragStartsFromNothing() {
        var pull = PullDown()
        pull.update(overscroll: 60)
        #expect(pull.released())
        #expect(!pull.released())
    }
}

struct ScrollCollapseTests {
    @Test func aScrollDownFoldsTheBarAndAScrollUpOpensIt() {
        var bar = ScrollCollapse()
        #expect(bar.update(offset: 10) == false)   // under the threshold
        #expect(bar.update(offset: 40) == true)
        #expect(bar.update(offset: 400) == true)
        #expect(bar.update(offset: 390) == true)    // a small move back is not a scroll up
        #expect(bar.update(offset: 370) == false)
        #expect(bar.update(offset: 380) == false)
        #expect(bar.update(offset: 400) == true)
    }

    @Test func theTopOfTheListAlwaysOpensTheBar() {
        var bar = ScrollCollapse()
        _ = bar.update(offset: 300)
        #expect(bar.collapsed)
        #expect(bar.update(offset: 0) == false)
    }

    @Test func theBounceAtEitherEndIsNotAScroll() {
        #expect(ScrollCollapse.clamped(offset: -30, content: 2000, container: 800) == 0)
        #expect(ScrollCollapse.clamped(offset: 1260, content: 2000, container: 800) == 1200)
        // A list shorter than the screen never folds the bar.
        #expect(ScrollCollapse.clamped(offset: 50, content: 300, container: 800) == 0)
    }
}

struct AttachmentTypeLabelTests {
    private func item(_ name: String, _ mime: String) -> AttachmentItem {
        AttachmentItem(threadId: "t", messageId: "m", attachmentId: "a", filename: name, mimeType: mime, size: 0)
    }

    @Test func badgeNamesTheKindOfFile() {
        #expect(item("transaction-confirmation-1.pdf", "application/pdf").typeLabel == "PDF")
        #expect(item("scan", "application/pdf").typeLabel == "PDF")
        #expect(item("report.docx", "application/octet-stream").typeLabel == "DOCX")
        #expect(item("photo", "image/jpeg").typeLabel == "IMG")
        #expect(item("", "application/octet-stream").typeLabel == "FILE")
    }
}
