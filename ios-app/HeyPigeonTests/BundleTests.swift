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

@MainActor
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

/// The model's answer, mapped against the bundles it was shown
/// (AI/BundlePrompt.swift). No model needed.
@MainActor
struct BundlePromptTests {
    let shown: [(id: String, name: String, category: BundleCategory)] = [
        (id: "b1", name: "Lisbon trip", category: .trip), (id: "b2", name: "Zalando order", category: .shopping),
    ]

    private func decide(_ action: String, bundle: String = "", name: String = "", kind: String = "other",
                        confidence: String = "high") -> BundleDecision {
        BundlePrompt.decision(action: action, bundle: bundle, name: name, kind: kind, confidence: confidence, candidates: shown)
    }

    @Test func joinNamesAListedBundleOfTheSameKind() {
        #expect(decide("join", bundle: " lisbon TRIP ", kind: "trip") == .join(bundleId: "b1"))
        #expect(decide("join", bundle: "Rome trip", kind: "trip") == .noBundle, "an unlisted name is no bundle")
        // A shop appointment the model put in the trip: the kinds differ.
        #expect(decide("join", bundle: "Lisbon trip", kind: "other") == .noBundle)
        #expect(decide("join", bundle: "Lisbon trip", kind: "shopping") == .noBundle)
    }

    @Test func onlyAHighConfidenceAnswerCounts() {
        #expect(decide("join", bundle: "Lisbon trip", kind: "trip", confidence: "medium") == .noBundle)
        #expect(decide("new", name: "Rome trip", kind: "trip", confidence: "low") == .noBundle)
        #expect(decide("new", name: "Rome trip", kind: "trip") == .new(name: "Rome trip", category: .trip))
    }

    @Test func newNeedsANameAndARealKind() {
        #expect(decide("new", name: "Acme website", kind: "project") == .new(name: "Acme website", category: .project))
        #expect(decide("new", name: "", kind: "trip") == .noBundle)
        #expect(decide("new", name: "Stuff", kind: "other") == .noBundle)
        // A "new" bundle with a listed name joins it, when the kinds agree.
        #expect(decide("new", name: "Zalando Order", kind: "shopping") == .join(bundleId: "b2"))
        #expect(decide("new", name: "Zalando Order", kind: "trip") == .noBundle)
        #expect(decide("nothing") == .noBundle)
    }

    @Test func thePromptListsTheBundlesAndTheEmail() {
        let p = BundlePrompt.prompt(subject: "Seat for AT 1326", from: "news@atlantic.test", snippet: "Choose your seat",
                                    bundles: [(name: "Lisbon trip", category: .trip, description: "",
                                               examples: ["Booking confirmed"], notExamples: ["Team lunch"])])
        #expect(p.contains("- Lisbon trip (trip) — has: \"Booking confirmed\" — not: \"Team lunch\""))
        #expect(p.contains("Subject: Seat for AT 1326"))
        #expect(p.contains("Preview: Choose your seat"))
        #expect(BundlePrompt.prompt(subject: "", from: "a@b.test", snippet: "", bundles: []).contains("Existing bundles: none yet."))
    }
}

/// The sidebar's Bundles section (AppModel.sidebarBundles).
@MainActor
struct SidebarBundleTests {
    private func item(_ id: String, daysAgo: Double) -> BundleItem {
        BundleItem(id: id, name: id, category: .trip, description: "", isArchived: false,
                   createdAt: Date().addingTimeInterval(-30 * 86_400), threadCount: 2, openCount: 1,
                   lastActivityAt: Date().addingTimeInterval(-daysAgo * 86_400))
    }

    @Test func foldedShowsTheMostRecentNotHiddenUpToTheLimit() {
        let all = (0..<8).map { item("b\($0)", daysAgo: Double($0)) }
        let folded = AppModel.sidebarBundles(all.shuffled(), hidden: ["b1"], expanded: false, limit: 3)
        #expect(folded.shown.map(\.id) == ["b0", "b2", "b3"])
        #expect(folded.more == 5)
        // Expanded: every bundle, the hidden one too, newest first.
        let open = AppModel.sidebarBundles(all, hidden: ["b1"], expanded: true, limit: 3)
        #expect(open.shown.count == 8 && open.shown[1].id == "b1" && open.more == 0)
    }

    @Test func hidingIsATogglePref() {
        let model = AppModel(engine: MockEngine())
        let b = item("b1", daysAgo: 0)
        model.toggleHidden(b)
        #expect(model.hiddenBundleIds == ["b1"])
        model.toggleHidden(b)
        #expect(model.hiddenBundleIds.isEmpty)
    }
}

/// The shared sheets go to whichever surface is up (AppModel.modal), and
/// the bundle brief is cached against the bundle's mail.
@MainActor
struct BundleSheetTests {
    @Test func theOpenBundlesSheetPresentsTheSharedSheets() throws {
        let model = AppModel(engine: MockEngine())
        let row = try #require(model.row(forThreadId: "t4"))
        model.pendingRemind = row
        #expect(model.modal(\.pendingRemind, inBundles: false).wrappedValue?.id == "t4")
        #expect(model.modal(\.pendingRemind, inBundles: true).wrappedValue == nil)
        model.showBundles = true
        #expect(model.modal(\.pendingRemind, inBundles: false).wrappedValue == nil)
        #expect(model.modal(\.pendingRemind, inBundles: true).wrappedValue?.id == "t4")
        // Dismissing from either side clears the one state.
        model.modal(\.pendingRemind, inBundles: true).wrappedValue = nil
        #expect(model.pendingRemind == nil)
    }

    @Test func theBriefKeyFollowsTheMail() throws {
        let model = AppModel(engine: MockEngine())
        model.reload()
        let before = try #require(model.bundleContents(id: "b1"))
        let row = try #require(model.row(forThreadId: "t5"))
        model.addToBundle(row, bundleId: "b1")
        let after = try #require(model.bundleContents(id: "b1"))
        #expect(AppModel.briefKey(before) != AppModel.briefKey(after))
        #expect(model.brief(for: after) == nil)
    }

    /// Wait for the brief that is being asked for, five seconds at most.
    private func settle(_ model: AppModel, _ id: String) async throws {
        for _ in 0..<100 where model.bundleBriefs[id]?.generating == true {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Opening a bundle asks for the brief with no tap because the model
    /// is on this device. When the model goes before the request is made,
    /// nothing is sent to the provider that answers instead, and nothing
    /// is said: the card offers the summary on a tap.
    @Test func aBriefOnOpenStaysOnTheDeviceOrIsNotAsked() async throws {
        let engine = MockEngine()
        engine.onDeviceAI = true
        engine.cloudAI = true
        let model = AppModel(engine: engine)
        model.autoSummarize = false
        #expect(model.aiConfigured)
        let c = try #require(model.bundleContents(id: "b1"))

        model.summarizeBundleOnOpen(c)
        #expect(model.brief(for: c)?.generating == true)
        engine.onDeviceAI = false
        try await settle(model, "b1")
        #expect(model.brief(for: c) == nil)

        // Apple's cloud answers now: opening asks for nothing.
        model.summarizeBundleOnOpen(c)
        #expect(model.brief(for: c) == nil)
        // A tap goes to whoever answers.
        model.summarizeBundle(c)
        try await settle(model, "b1")
        #expect(model.brief(for: c)?.brief != nil)

        // With the model on this device, opening asks and it answers.
        engine.onDeviceAI = true
        let other = AppModel(engine: engine)
        other.autoSummarize = false
        let again = try #require(other.bundleContents(id: "b1"))
        other.summarizeBundleOnOpen(again)
        try await settle(other, "b1")
        #expect(other.brief(for: again)?.brief != nil)
    }
}
