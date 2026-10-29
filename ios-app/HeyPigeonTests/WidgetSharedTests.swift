// The widget snapshot the app writes, the deep links the app opens on, and
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
