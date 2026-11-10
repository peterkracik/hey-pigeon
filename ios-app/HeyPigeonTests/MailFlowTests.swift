// The mail flows the Mac review fixed or added, over the mock: reply-all
// with the Cc line, the unsubscribe header, the list's flat order, the
// labels' round trip.

import Foundation
import Testing
@testable import HeyPigeon

struct ReplyAllTests {
    private func message(to: [String], cc: [String], mine: Bool = false) -> MessageItem {
        MessageItem(id: "m1", fromName: "Ana", fromAddress: "ana@acme.test", to: to, date: Date(), snippet: "",
                    bodyHTML: nil, bodyText: "Hello", isRead: true, isMine: mine, isDraft: false, cc: cc)
    }

    @Test func replyAllKeepsEveryoneOnTheCcLine() {
        let m = message(to: ["me", "ben@acme.test"], cc: ["Cyd@acme.test", "ana@acme.test", "ben@acme.test"])
        let all = SendDraft.reply(to: m, in: makeRow(), all: true, history: nil)
        #expect(all.to == ["ana@acme.test"])
        // To's others first, then Cc's; each once, the sender not again.
        #expect(all.cc == ["ben@acme.test", "Cyd@acme.test"])
        let one = SendDraft.reply(to: m, in: makeRow(), all: false, history: nil)
        #expect(one.cc.isEmpty)
    }

    @Test func aReplyToMyOwnMessageGoesWhereItWent() {
        let m = message(to: ["ben@acme.test"], cc: ["cyd@acme.test", "me"], mine: true)
        #expect(SendDraft.reply(to: m, in: makeRow(), all: false, history: nil).to == ["ben@acme.test"])
        let all = SendDraft.reply(to: m, in: makeRow(), all: true, history: nil)
        #expect(all.to == ["ben@acme.test"])
        #expect(all.cc == ["cyd@acme.test"])
    }
}

struct UnsubscribeTests {
    @Test func oneClickWinsThenMailThenThePage() throws {
        let both = "<mailto:leave@list.test?subject=unsubscribe>, <https://list.test/u/abc>"
        #expect(Unsubscribe.links(in: both).count == 2)
        #expect(Unsubscribe.method(header: both, oneClick: true) == .post(try #require(URL(string: "https://list.test/u/abc"))))
        // Without the sender's say-so a POST is not known to be enough.
        #expect(Unsubscribe.method(header: both, oneClick: false) == .mail(try #require(URL(string: "mailto:leave@list.test?subject=unsubscribe"))))
        #expect(Unsubscribe.method(header: "<http://list.test/u>", oneClick: false) == .open(try #require(URL(string: "http://list.test/u"))))
        // One-click needs https (RFC 8058); http alone is just a page.
        #expect(Unsubscribe.method(header: "<http://list.test/u>", oneClick: true) == .open(try #require(URL(string: "http://list.test/u"))))
        #expect(Unsubscribe.method(header: "no brackets here", oneClick: true) == nil)
    }

    @Test func theNewestMessageFromSomeoneElseMakesTheOffer() {
        var news = makeMessage("m1", from: "The Weekly", address: "news@list.test")
        news.listUnsubscribe = "<https://list.test/u/1>"
        news.unsubscribeOneClick = true
        let mine = makeMessage("m2", mine: true)
        let offer = Unsubscribe.offer(in: [news, mine])
        #expect(offer?.sender == "The Weekly")
        #expect(Unsubscribe.offer(in: [mine]) == nil)
    }
}

struct CalendarInviteTests {
    private let ics = [
        "BEGIN:VCALENDAR", "VERSION:2.0", "METHOD:REQUEST", "BEGIN:VEVENT",
        "UID:evt-42@acme.test", "SEQUENCE:3",
        "DTSTART;TZID=Europe/Bratislava:20261112T100000", "DTEND;TZID=Europe/Bratislava:20261112T113000",
        "SUMMARY:Roadmap\\, part two", "LOCATION:Room 4\\; 2nd ",
        " floor", "ORGANIZER;CN=\"Kov\u{E1}\u{10D}, Ana\":mailto:ana@acme.test",
        "BEGIN:VALARM", "TRIGGER:-PT10M", "SUMMARY:not the event's", "END:VALARM",
        "END:VEVENT", "END:VCALENDAR",
    ].joined(separator: "\r\n")

    @Test func anInvitationIsReadFromItsFile() throws {
        let invite = try #require(CalendarInvite.parse(ics))
        #expect(invite.uid == "evt-42@acme.test")
        #expect(invite.summary == "Roadmap, part two")
        // A folded line continues the one before it.
        #expect(invite.location == "Room 4; 2nd floor")
        #expect(invite.organizerEmail == "ana@acme.test")
        #expect(invite.organizerName == "Kov\u{E1}\u{10D}, Ana")
        #expect(invite.sequence == 3)
        #expect(invite.method == "REQUEST")
        #expect(invite.isAnswerable)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Bratislava"))
        let start = try #require(invite.start)
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: start)
        #expect(parts.year == 2026 && parts.month == 11 && parts.day == 12 && parts.hour == 10)
        #expect(invite.end?.timeIntervalSince(start) == 5400)
        #expect(CalendarInvite.parse("BEGIN:VCALENDAR\r\nEND:VCALENDAR") == nil)
    }

    @Test func theAnswerNamesTheEventAndTheAttendee() throws {
        let invite = try #require(CalendarInvite.parse(ics))
        let reply = invite.reply(.accepted, from: "me@work.test", now: Date(timeIntervalSince1970: 0))
        #expect(reply.contains("METHOD:REPLY\r\n"))
        #expect(reply.contains("UID:evt-42@acme.test\r\n"))
        #expect(reply.contains("SEQUENCE:3\r\n"))
        #expect(reply.contains("DTSTART;TZID=Europe/Bratislava:20261112T100000\r\n"))
        #expect(reply.contains("ATTENDEE;PARTSTAT=ACCEPTED:mailto:me@work.test\r\n"))
        #expect(reply.contains("DTSTAMP:19700101T000000Z\r\n"))
        // A day-long event, and a cancellation, which is not answered.
        let day = try #require(CalendarInvite.parse("BEGIN:VCALENDAR\nMETHOD:CANCEL\nBEGIN:VEVENT\nUID:d1\nDTSTART;VALUE=DATE:20261224\nORGANIZER:mailto:ana@acme.test\nEND:VEVENT\nEND:VCALENDAR"))
        #expect(day.isAllDay)
        #expect(day.isCancellation)
        #expect(!day.isAnswerable)
    }
}

@MainActor
struct BannerActionTests {
    @Test func aBannersButtonsActThroughTheModel() async throws {
        let model = AppModel(engine: MockEngine())
        let id = try #require(model.rows.first { !$0.isDone && $0.scheduledAt == nil }?.id)
        await NewMailNotifier.perform(NotificationActions.remindInAnHour, threadId: id, model: model)
        let reminded = try #require(try model.engine.threadRow(id: id))
        #expect(reminded.scheduledAt.map { $0 > Date() } == true)
        await NewMailNotifier.perform(NotificationActions.done, threadId: id, model: model)
        #expect(try model.engine.threadRow(id: id)?.isDone == true)
        // A plain tap asks the inbox for the thread.
        await NewMailNotifier.perform("com.apple.UNNotificationDefaultActionIdentifier", threadId: id, model: model)
        #expect(model.pendingThreadId == id)
    }
}

@MainActor
struct ListOrderTests {
    @Test func theFlatOrderFollowsTheGroupsAndCountsItsChanges() async {
        let model = AppModel(engine: MockEngine())
        let ids = model.groupedRows.flatMap { $0.rows.map(\.id) }
        #expect(model.flatRowIds == ids)
        for (index, id) in ids.enumerated() { #expect(model.listIndex(of: id) == index) }
        let before = model.rowOrderRevision
        // A reload that moves nothing leaves the order, and its counter, alone.
        model.reload()
        #expect(model.rowOrderRevision == before)
        if let row = model.rows.first(where: { $0.id == ids[1] }) { model.markDone(row) }
        #expect(model.listIndex(of: ids[1]) == nil)
        #expect(model.rowOrderRevision != before)
    }

    @Test func labelsAreMadeRenamedAndDeleted() async {
        let model = AppModel(engine: MockEngine())
        let count = model.labels.count
        let label = await model.createLabel(named: "  Receipts ", accountId: "me@work.test")
        #expect(label?.name == "Receipts")
        #expect(model.labels.count == count + 1)
        if let label {
            await model.renameLabel(label, to: "Bills")
            #expect(model.labels.contains { $0.id == label.id && $0.name == "Bills" })
            if let renamed = model.labels.first(where: { $0.id == label.id }) { await model.deleteLabel(renamed) }
            #expect(!model.labels.contains { $0.id == label.id })
        }
    }
}
