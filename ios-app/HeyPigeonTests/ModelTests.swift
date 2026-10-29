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
                 text: String? = nil, read: Bool = true, mine: Bool = false, draft: Bool = false) -> MessageItem {
    MessageItem(id: id, fromName: from, fromAddress: address, to: to, date: Date(), snippet: "snippet \(id)",
                bodyHTML: nil, bodyText: text, isRead: read, isMine: mine, isDraft: draft)
}

struct EmailAddressTests {
    @Test func parsesHeaderText() {
        #expect(EmailAddress.address(in: "\"Ana Novak\" <ana@acme.test>") == "ana@acme.test")
        #expect(EmailAddress.address(in: "  ana@acme.test ") == "ana@acme.test")
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

    @Test func forwardQuotesTheMessageUnderOneFwd() {
        let m = makeMessage("1", from: "Ana", address: "ana@acme.test", text: "The deck.")
        let d = SendDraft.forward(of: m, in: makeRow(subject: "Deck"))
        #expect(d.subject == "Fwd: Deck")
        #expect(d.to.isEmpty)
        #expect(d.bodyText.contains("From: Ana <ana@acme.test>") && d.bodyText.hasSuffix("The deck."))
        #expect(SendDraft.forward(of: m, in: makeRow(subject: "fwd: Deck")).subject == "fwd: Deck")
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
        for p in AIProvider.allCases + [.other("anthropic")] {
            #expect(AIProvider(rawValue: p.rawValue) == p)
        }
        #expect(AIProvider.apple.title.hasPrefix("On this "))
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
