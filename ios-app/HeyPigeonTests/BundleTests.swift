// Bundles on the Swift side (docs/bundles.md): which inbox rows fold into
// one bundle row and where that row sits, and the AppModel actions over the
// mock engine. The identifier links themselves are the core's, tested in
// Rust (crates/core/src/bundles.rs).

import Foundation
import Testing
@testable import HeyPigeon

private func bundle(_ id: String, _ name: String = "Lisbon trip", archived: Bool = false) -> BundleItem {
    BundleItem(id: id, name: name, category: .trip, description: "", isArchived: archived,
               createdAt: Date(), threadCount: 0, openCount: 0, lastActivityAt: nil)
}

private func inBundle(_ row: ThreadRow, _ id: String?) -> ThreadRow {
    var r = row
    r.bundleId = id
    return r
}

/// A row with a priority, which `makeRow` leaves nil.
private func prioritized(_ id: String, _ priority: TriageLevel, bundle: String) -> ThreadRow {
    ThreadRow(id: id, accountId: "me@work.test", subject: "S", snippet: "P", lastMessageAt: Date(), isRead: true,
              isArchived: false, messageCount: 1, fromSummary: "Ana", lastFromAddress: "ana@acme.test",
              scheduledAt: nil, isFollowUp: false, needsReply: false, isStarred: false, hasAttachment: false,
              priority: priority, triageLabelIds: [], labels: ["INBOX"], bundleId: bundle)
}

struct BundleFoldTests {
    let now = Date()

    @Test func quietMailFoldsAndMailThatNeedsYouKeepsItsRow() {
        let rows = [
            inBundle(makeRow("receipt", at: now.addingTimeInterval(-60)), "b1"),
            inBundle(makeRow("seat", at: now.addingTimeInterval(-30)), "b1"),
            inBundle(makeRow("unread", read: false), "b1"),
            inBundle(makeRow("reply", needsReply: true), "b1"),
            inBundle(makeRow("pinned", starred: true), "b1"),
            prioritized("urgent", .high, bundle: "b1"),
            inBundle(makeRow("plain"), nil),
        ]
        let (folds, rest) = AppModel.fold(rows, bundles: [bundle("b1")])
        #expect(folds.count == 1)
        #expect(folds[0].rows.map(\.id) == ["seat", "receipt"], "newest first")
        #expect(folds[0].summary.hasPrefix("2 updates · "))
        #expect(rest.map(\.id) == ["unread", "reply", "pinned", "urgent", "plain"])
    }

    @Test func oneQuietEmailOrAnUnknownBundleDoesNotFold() {
        let rows = [
            inBundle(makeRow("only"), "b1"),
            inBundle(makeRow("x1"), "gone"),
            inBundle(makeRow("x2"), "gone"),
        ]
        let (folds, rest) = AppModel.fold(rows, bundles: [bundle("b1")])
        #expect(folds.isEmpty)
        #expect(rest.count == 3)
    }

    @Test func theFoldSitsInTheDayOfItsNewestEmailInTheInboxOnly() {
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        let rows = [
            inBundle(makeRow("a", at: noon.addingTimeInterval(-600)), "b1"),
            inBundle(makeRow("b", at: noon.addingTimeInterval(-3 * 86_400)), "b1"),
            makeRow("old", at: noon.addingTimeInterval(-30 * 86_400)),
        ]
        let groups = AppModel.group(rows, view: .inbox, searching: false, triageFilterId: nil, pinList: true,
                                    bundles: [bundle("b1")], now: noon)
        #expect(groups.map(\.title) == ["Today", "Older"])
        #expect(groups[0].folds.map(\.id) == ["b1"])
        #expect(groups[0].rows.isEmpty)
        // A search, a label filter or another folder shows every thread.
        let searching = AppModel.group(rows, view: .inbox, searching: true, triageFilterId: nil, pinList: true,
                                       bundles: [bundle("b1")], now: noon)
        #expect(searching.flatMap(\.folds).isEmpty && searching.flatMap(\.rows).count == 3)
        let archive = AppModel.group(rows, view: .all, searching: false, triageFilterId: nil, pinList: true,
                                     bundles: [bundle("b1")], now: noon)
        #expect(archive.flatMap(\.folds).isEmpty)
    }
}

@MainActor
struct BundleModelTests {
    let model: AppModel
    let engine: MockEngine

    init() {
        engine = MockEngine()
        model = AppModel(engine: engine)
        model.reload()
    }

    @Test func theSampleBundleShowsWithItsThread() throws {
        #expect(model.activeBundles.map(\.name) == ["Lisbon trip"])
        let row = try #require(model.row(forThreadId: "t4"))
        #expect(model.bundle(id: row.bundleId)?.name == "Lisbon trip")
        let c = try #require(model.bundleContents(id: "b1"))
        #expect(c.threads.map(\.id) == ["t4"])
        #expect(c.facts.map(\.value) == ["LH1172"])
    }

    @Test func createAddRemoveAndDelete() throws {
        let b = try #require(model.createBundle(name: "  Acme redesign ", category: .project, description: "", threadIds: ["t5"]))
        #expect(b.name == "Acme redesign")
        #expect(model.row(forThreadId: "t5")?.bundleId == b.id)
        #expect(model.createBundle(name: "   ", category: .other, description: "") == nil, "a name is required")

        let t7 = try #require(model.row(forThreadId: "t7"))
        model.addToBundle(t7, bundleId: b.id)
        let c = try #require(model.bundleContents(id: b.id))
        #expect(Set(c.threads.map(\.id)) == ["t5", "t7"])
        #expect(model.bundle(id: b.id)?.threadCount == 2)

        let added = try #require(model.row(forThreadId: "t7"))
        model.removeFromBundle(added)
        #expect(model.row(forThreadId: "t7")?.bundleId == nil)

        model.setBundleArchived(try #require(model.bundle(id: b.id)), true)
        #expect(model.archivedBundles.map(\.id) == [b.id])
        model.deleteBundle(try #require(model.bundle(id: b.id)))
        #expect(model.bundle(id: b.id) == nil)
        #expect(model.row(forThreadId: "t5")?.bundleId == nil, "the mail stays, the grouping goes")
    }

    @Test func doneMailStaysInTheBundleButNotOpen() async throws {
        try await engine.perform(.archive(threadId: "t4"), accountId: "me@personal.test")
        let c = try #require(model.bundleContents(id: "b1"))
        #expect(c.done.map(\.id) == ["t4"])
        #expect(c.open.isEmpty)
    }
}
