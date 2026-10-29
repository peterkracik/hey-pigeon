// The widget snapshot the app writes, the deep links the app opens on
// (heypigeon:// and mailto:), a Spotlight search continuing in the app, and
// a share becoming a draft — all over the mock engine, no App Group needed
// (the snapshot is built, not written, here).

import Foundation
import Testing
@testable import HeyPigeon

@MainActor
struct WidgetSharedTests {
    let model: AppModel
    let engine: MockEngine

    init() {
        engine = MockEngine()
        model = AppModel(engine: engine)
    }

    @Test func snapshotCarriesCountsDueUpcomingAndNeedReply() throws {
        let now = Date()
        try engine.setReminder(threadId: "t3", at: now.addingTimeInterval(-60), onlyIfNoReply: true)
        try engine.setReminder(threadId: "t4", at: now.addingTimeInterval(3_600), onlyIfNoReply: false)
        try engine.setNeedsReply(threadId: "t5", true)
        let s = WidgetSnapshotWriter.build(model, now: now)
        #expect(s.unreadTotal == 2) // t1 and t2 are unread in the sample inbox
        #expect(s.accounts.map(\.name).sorted() == ["Personal", "Work"])
        #expect(s.due.map(\.id) == ["t3"])
        #expect(s.due[0].isFollowUp)
        #expect(s.upcoming.map(\.id) == ["t4"])
        #expect(s.upcoming[0].at == now.addingTimeInterval(3_600))
        #expect(s.needReply.map(\.id) == ["t5"])
        #expect(s.needReplyTotal == 1)
        #expect(s.needReply[0].accountColor == "coral") // the work account's colour
    }

    @Test func snapshotEqualityIgnoresTheTimestamp() {
        let a = WidgetSnapshotWriter.build(model, now: Date())
        let b = WidgetSnapshotWriter.build(model, now: Date().addingTimeInterval(60))
        #expect(WidgetSnapshotWriter.same(a, b))
    }

    @Test func snapshotRoundTripsThroughJSON() throws {
        let s = WidgetSnapshot.placeholder
        let data = try JSONEncoder.shared.encode(s)
        let back = try JSONDecoder.shared.decode(WidgetSnapshot.self, from: data)
        #expect(back.due == s.due)
        #expect(back.accounts == s.accounts)
    }

    @Test func deepLinksParseAndNavigate() throws {
        #expect(DeepLink(url: AppGroup.Link.thread("t 1")) == .thread(id: "t 1"))
        #expect(DeepLink(url: AppGroup.Link.compose) == .compose)
        #expect(DeepLink(url: AppGroup.Link.folder("scheduled")) == .folder(.scheduled))
        #expect(DeepLink(url: URL(string: "heypigeon://folder/nope")!) == nil)
        #expect(DeepLink(url: URL(string: "https://heypigeon.app")!) == nil)
        #expect(DeepLink(.compose) == .compose)
        #expect(DeepLink(.needReply) == .folder(.needReply))

        model.handle(.folder(.needReply))
        #expect(model.tab == .needReply)
        model.handle(.thread(id: "t2"))
        #expect(model.tab == .inbox)
        #expect(model.pendingThreadId == "t2")
        model.handle(.compose)
        #expect(model.composeDraft != nil)
    }

    @Test func mailtoLinksBecomePrefilledDrafts() throws {
        // RFC 6068: recipients before the `?`, the four headers after it,
        // percent-decoded, CRLF in the body a newline, a `+` left alone.
        let url = URL(string: "mailto:anna@example.com,Ben%20%3Cben%2Bnews@example.com%3E?subject=Deposit%20back%3F&body=Hi%20Anna%2C%0D%0A%0D%0AAny%20news%3F&cc=cc@example.com&bcc=hidden@example.com&to=more@example.com&from=spoof@example.com")!
        guard case .mailto(let d)? = DeepLink(url: url) else { Issue.record("not a mailto link"); return }
        #expect(d.to == ["anna@example.com", "ben+news@example.com", "more@example.com"])
        #expect(d.cc == ["cc@example.com"])
        #expect(d.bcc == ["hidden@example.com"])
        #expect(d.subject == "Deposit back?")
        #expect(d.bodyText == "Hi Anna,\n\nAny news?")
        #expect(d.fromAccountId == nil)

        // A bare mailto: is an empty composer; the scheme is case-insensitive.
        guard case .mailto(let empty)? = DeepLink(url: URL(string: "MAILTO:")!) else { Issue.record("not a mailto link"); return }
        #expect(empty.to.isEmpty && empty.subject.isEmpty && empty.bodyText.isEmpty)

        model.handle(DeepLink(url: url)!)
        #expect(model.composeDraft?.to == ["anna@example.com", "ben+news@example.com", "more@example.com"])
        #expect(model.composeDraft?.subject == "Deposit back?")
    }

    @Test func spotlightSearchContinuesInTheSearchTab() {
        model.showSettings = true
        model.openSearch("  invoice from anna ")
        #expect(model.tab == .search)
        #expect(model.searchText == "invoice from anna")
        #expect(model.searchFilters.isEmpty)
        #expect(!model.showSettings)
        #expect(model.isSearching)
    }

    @Test func shareBecomesADraft() {
        var share = PendingShare()
        share.subject = "Look at this"
        share.text = "Found it."
        share.links = [URL(string: "https://example.com/a")!]
        let draft = SendDraft(share)
        #expect(draft.subject == "Look at this")
        #expect(draft.bodyText == "Found it.\n\nhttps://example.com/a")
        #expect(draft.attachments.isEmpty)
        #expect(!share.isEmpty)
        #expect(PendingShare().isEmpty)
    }

    @Test func snoozeMovesTheReminderAhead() throws {
        try engine.setReminder(threadId: "t6", at: Date().addingTimeInterval(-60), onlyIfNoReply: true)
        model.snooze(threadId: "t6", hours: 2)
        let row = try #require(try engine.threadRow(id: "t6"))
        let at = try #require(row.scheduledAt)
        #expect(at > Date().addingTimeInterval(7_000))
        #expect(row.isFollowUp) // the follow-up nature survives
    }
}
