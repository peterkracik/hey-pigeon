// The parcel card on the Swift side (docs/specs/parcel-card.md): which
// parcels it shows and when a dismissed one comes back, its words, and
// what it does to a bundle's folded row — as pure rules, then through
// AppModel over the mock engine. What a parcel is and what its mail says
// about it are the core's, tested in Rust (crates/core/src/parcels.rs).

import Foundation
import Testing
@testable import HeyPigeon

private func parcel(_ id: String, bundle: String = "b1", thread: String = "t4",
                    account: String = "me@personal.test", at: Date = Date(timeIntervalSince1970: 1_795_000_000),
                    progress: ParcelProgress? = nil, day: String? = nil, title: String? = nil,
                    host: String = "www.dhl.com", subject: String = "Your order has shipped",
                    sender: String = "Zalando") -> ParcelItem {
    ParcelItem(id: id, bundleId: bundle, threadId: thread, accountId: account,
               url: URL(string: "https://\(host)/track")!, host: host, subject: subject, sender: sender, at: at,
               progress: progress, expectedDay: day, title: title)
}

private func shop(_ id: String, _ name: String = "Zalando order") -> BundleItem {
    BundleItem(id: id, name: name, category: .shopping, description: "", isArchived: false,
               createdAt: Date(), threadCount: 2, openCount: 2, lastActivityAt: Date())
}

private func quiet(_ id: String, bundle: String, at: Date = Date()) -> ThreadRow {
    var row = makeRow(id, at: at)
    row.bundleId = bundle
    return row
}

struct ParcelRuleTests {
    /// 19 November 2026, noon, in a calendar that does not depend on
    /// where the test runs.
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Prague") ?? .gmt
        c.locale = Locale(identifier: "en_GB")
        return c
    }
    private var noon: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 12)) ?? Date()
    }

    @Test func aDismissedParcelComesBackWithANewerEmail() {
        let old = parcel("number:bfa83b19dfd2e747", at: noon)
        let other = parcel("thread:t9", at: noon)
        let dismissed = ParcelCard.dismissing([old], from: [], now: noon)
        #expect(dismissed == [ParcelCard.entry(old)])
        #expect(ParcelCard.visible([old, other], dismissed: dismissed, accountId: nil).map(\.id) == ["thread:t9"])
        // The same parcel after a newer email about it: back.
        let newer = parcel("number:bfa83b19dfd2e747", at: noon.addingTimeInterval(3600))
        #expect(ParcelCard.visible([newer], dismissed: dismissed, accountId: nil).map(\.id) == ["number:bfa83b19dfd2e747"])
        // A device that has not read the newer email yet still hides it.
        let later = ParcelCard.dismissing([newer], from: dismissed, now: noon)
        #expect(later == [ParcelCard.entry(newer)], "one entry per parcel")
        #expect(ParcelCard.visible([old], dismissed: later, accountId: nil).isEmpty)
        // What a pref may hold besides: ignored, never a crash.
        #expect(ParcelCard.visible([old], dismissed: ["", "@", "x@y", "number:bfa83b19dfd2e747"], accountId: nil).count == 1)
        #expect(ParcelCard.parse("thread:a@b@12")?.id == "thread:a@b")
        // A date no Int64 holds is an entry like any other, not a trap.
        #expect(ParcelCard.entry(parcel("thread:far", at: .distantFuture)).hasPrefix("thread:far@"))
        #expect(ParcelCard.entry(parcel("thread:far", at: Date(timeIntervalSince1970: .greatestFiniteMagnitude)))
            == "thread:far@\(Int64.max)")
    }

    @Test func dismissalsAreSortedAndOldOnesGo() {
        let a = parcel("thread:a", at: noon)
        let b = parcel("number:B", at: noon)
        let stale = parcel("thread:old", at: noon.addingTimeInterval(-200 * 86_400))
        let kept = ParcelCard.dismissing([a], from: [ParcelCard.entry(b), ParcelCard.entry(stale), "junk"], now: noon)
        #expect(kept == [ParcelCard.entry(b), ParcelCard.entry(a)].sorted())
    }

    @Test func theCardIsTheAccountsOwn() {
        let mine = parcel("thread:a", account: "me@personal.test")
        let work = parcel("thread:b", account: "me@work.test")
        #expect(ParcelCard.visible([mine, work], dismissed: [], accountId: nil).count == 2)
        #expect(ParcelCard.visible([mine, work], dismissed: [], accountId: "me@work.test").map(\.id) == ["thread:b"])
    }

    @Test func theStatusLineSaysWhatIsKnownAndNothingElse() {
        func line(_ p: ParcelItem, updates: Int = 0) -> String {
            ParcelCard.statusLine(p, updates: updates, now: noon, calendar: calendar)
        }
        #expect(line(parcel("a", progress: .delivered, day: "2026-11-20")) == "Delivered · www.dhl.com")
        #expect(line(parcel("a", progress: .outForDelivery)) == "Out for delivery · www.dhl.com")
        #expect(line(parcel("a", progress: .shipped, day: "2026-11-19")) == "Expected today · www.dhl.com")
        #expect(line(parcel("a", day: "2026-11-20")) == "Expected tomorrow · www.dhl.com")
        #expect(line(parcel("a", day: "2026-11-18")) == "Expected yesterday · www.dhl.com")
        #expect(line(parcel("a", day: "2026-11-22")) == "Expected Sunday · www.dhl.com")
        #expect(line(parcel("a", day: "2026-12-03")).hasPrefix("Expected 3"))
        // No day: where the link leads, what the email says, when — never
        // a guess, and the host before the mail's own words.
        let time = Formatters.rowTime(noon, now: noon)
        #expect(line(parcel("a", at: noon)) == "www.dhl.com · Your order has shipped · \(time)")
        #expect(line(parcel("a", at: noon, progress: .shipped)) == "www.dhl.com · Shipped · \(time)")
        // A day that is no day falls back too.
        #expect(line(parcel("a", at: noon, progress: .shipped, day: "soon")) == "www.dhl.com · Shipped · \(time)")
        #expect(line(parcel("a", day: "2026-11-20"), updates: 3) == "Expected tomorrow · www.dhl.com · 3 updates")
        #expect(ParcelCard.dayString(noon, calendar: calendar) == "2026-11-19")
    }

    /// The row always says where Track parcel leads, in the link's own
    /// host: whatever is known about the parcel, whoever the email says
    /// it is from, and whatever the host's first label spells.
    @Test func everyFormOfTheLineNamesTheHostItOpens() {
        func line(_ p: ParcelItem) -> String { ParcelCard.statusLine(p, now: noon, calendar: calendar) }
        // A click-redirect: its host, not the sender's display name.
        let redirect = parcel("a", at: noon, host: "u1.ct.sendgrid.net", sender: "DHL Express")
        #expect(line(redirect).contains(redirect.host))
        #expect(!line(redirect).contains("DHL"))
        #expect(ParcelCard.trackLabel(redirect) == "Track parcel, opens u1.ct.sendgrid.net")
        // The day is known: the host is still there.
        let dated = parcel("a", day: "2026-11-19", host: "evil.example", sender: "DHL")
        #expect(line(dated) == "Expected today · evil.example")
        // A look-alike is read as what it is, never as the brand.
        for host in ["dhl.top", "dhl.com.de", "dhl.evil.example"] {
            for p in [parcel("a", at: noon, host: host), parcel("a", progress: .delivered, host: host),
                      parcel("a", progress: .outForDelivery, host: host), parcel("a", day: "2026-11-20", host: host)] {
                #expect(line(p).contains(host), "\(host)")
                #expect(!line(p).contains("DHL"), "\(host)")
            }
        }
    }

    /// A parcel's address becomes a link only when the host the system
    /// will open is the host the row names (`ParcelItem.init?` and the
    /// bundle's Info page in RustEngine go through this).
    @Test func aLinkIsOfferedOnlyWhenItsHostIsTheOneNamed() {
        #expect(MailLink.url("https://www.dhl.com/track?id=1", host: "www.dhl.com") != nil)
        #expect(MailLink.url("https://WWW.DHL.com:443/track", host: "www.dhl.com") != nil)
        #expect(MailLink.url("http://tracking.gls.example/p/77", host: "tracking.gls.example") != nil)
        // The host the core read is not the one the URL leads to.
        #expect(MailLink.url("https://evil.example/track", host: "dhl.com") == nil)
        // A user or a password before the host, however it got there.
        #expect(MailLink.url("https://dhl.com@evil.example/track", host: "evil.example") == nil)
        #expect(MailLink.url("https://dhl.com:x@evil.example/track") == nil)
        #expect(MailLink.url("https://dhl.com%5C@evil.example/track") == nil)
        // The backslash forms: whatever URL(string:) makes of them, the
        // result is never a link shown as dhl.com.
        for spoof in ["https://dhl.com\\@evil.example/track", "https://dhl.com:443\\@evil.example/x",
                      "https://dhl.com\\.evil.example/track"] {
            #expect(MailLink.url(spoof, host: "dhl.com") == nil, "\(spoof)")
            if let url = MailLink.url(spoof) { #expect(MailLink.host(of: url) != "dhl.com", "\(spoof)") }
        }
        // Not a web address, or none at all.
        for other in ["ftp://dhl.com/x", "javascript:alert(1)", "mailto:a@dhl.com", "dhl.com/track", "https:///track", ""] {
            #expect(MailLink.url(other) == nil, "\(other)")
        }
    }

    @Test func titlesAndLabels() {
        let b = shop("b1")
        #expect(ParcelCard.title(parcel("a", title: "Kettle"), bundle: b) == "Kettle")
        #expect(ParcelCard.title(parcel("a"), bundle: b) == "Zalando order")
        #expect(ParcelCard.title(parcel("a"), bundle: nil) == "Your order has shipped")
        #expect(ParcelCard.trackLabel(parcel("a")) == "Track parcel, opens www.dhl.com")
        #expect(ParcelCard.dismissedToast(1) == "Parcel dismissed")
        #expect(ParcelCard.dismissedToast(3) == "3 parcels dismissed")
    }

    /// The status line comes apart around the host its button opens (the
    /// view sets the host in the mono) and goes back together to the same
    /// words; a line that does not name the host stays whole.
    @Test func theStatusLineSplitsAroundItsHost() {
        let line = "Expected tomorrow · www.dhl.test · 2 updates"
        let pieces = ParcelCard.statusPieces(line, host: "www.dhl.test")
        #expect(pieces.before == "Expected tomorrow · ")
        #expect(pieces.host == "www.dhl.test")
        #expect(pieces.after == " · 2 updates")
        #expect(pieces.before + pieces.host + pieces.after == line)
        let whole = ParcelCard.statusPieces("Expected tomorrow", host: "www.dhl.test")
        #expect(whole.before == "Expected tomorrow")
        #expect(whole.host.isEmpty && whole.after.isEmpty)
    }

    @MainActor @Test func aBundleUnderTheCardGetsNoFoldedRowAndItsMailIsCounted() {
        let rows = [quiet("r1", bundle: "b1"), quiet("r2", bundle: "b1"), quiet("r3", bundle: "b2"),
                    quiet("r4", bundle: "b2"), makeRow("plain", read: false)]
        let bundles = [shop("b1"), shop("b2", "Lisbon trip")]
        let plain = AppModel.group(rows, view: .inbox, searching: false, triageFilterId: nil, pinList: true, bundles: bundles)
        #expect(Set(plain.flatMap(\.folds).map(\.id)) == ["b1", "b2"])
        let under = AppModel.group(rows, view: .inbox, searching: false, triageFilterId: nil, pinList: true,
                                   bundles: bundles, underParcels: ["b1"])
        #expect(under.flatMap(\.folds).map(\.id) == ["b2"])
        #expect(under.flatMap(\.rows).map(\.id) == ["plain"], "the folded mail has no row of its own either way")
        // It is counted on the bundle's first parcel in the card, once.
        let first = parcel("thread:a", bundle: "b1")
        let second = parcel("thread:b", bundle: "b1")
        let folds = Dictionary(uniqueKeysWithValues: AppModel.fold(rows, bundles: bundles).folds.map { ($0.bundle.id, $0) })
        #expect(ParcelCard.updates(for: first, in: [first, second], folds: folds, folding: true) == 2)
        #expect(ParcelCard.updates(for: second, in: [first, second], folds: folds, folding: true) == 0)
        #expect(ParcelCard.updates(for: first, in: [first, second], folds: folds, folding: false) == 0)
    }
}

@MainActor
struct ParcelModelTests {
    let model: AppModel
    let engine: MockEngine

    /// The parcels are read off the main actor, a moment after the rows
    /// (`AppModel.reload` carries the ones it holds): wait for them.
    init() async {
        engine = MockEngine()
        engine.parcelStore = [parcel("thread:t4", progress: .shipped, title: "Travel adapter")]
        model = AppModel(engine: engine)
        model.reload()
        await model.settleReloads()
    }

    /// The main actor's reload does not work the parcels out: it keeps
    /// the ones the model holds, and the read that follows brings the new.
    @Test func aReloadCarriesTheParcelsAndTheNextReadBringsTheNew() async {
        let fresh = AppModel(engine: engine)
        fresh.reload()
        #expect(fresh.parcels.isEmpty && !fresh.rows.isEmpty, "rows now, parcels after")
        await fresh.settleReloads()
        #expect(fresh.inboxParcels.map(\.id) == ["thread:t4"])
        engine.parcelStore = []
        fresh.reload()
        #expect(fresh.inboxParcels.count == 1, "carried")
        await fresh.settleReloads()
        #expect(fresh.inboxParcels.isEmpty && fresh.parcels.isEmpty)
    }

    @Test func theCardStandsOverThePlainInboxOnly() {
        #expect(model.inboxParcels.map(\.id) == ["thread:t4"])
        #expect(!model.listIsEmpty)
        model.triageFilterId = "tl2"
        #expect(model.inboxParcels.isEmpty)
        model.triageFilterId = nil
        #expect(model.inboxParcels.count == 1)
        model.navigate(to: .scheduled)
        #expect(model.inboxParcels.isEmpty)
        model.navigate(to: .inbox, folder: .archive)
        #expect(model.inboxParcels.isEmpty)
        model.navigate(to: .inbox, folder: .inbox)
        #expect(model.inboxParcels.count == 1)
        // Another account's inbox has its own parcels: here, none.
        model.selectedAccountId = "me@work.test"
        #expect(model.inboxParcels.isEmpty)
        model.selectedAccountId = nil
        #expect(model.inboxParcels.count == 1)
    }

    @Test func dismissIsUndoableSyncedAndEndsWithANewerEmail() async throws {
        let shown = try #require(model.inboxParcels.first)
        // At once: a dismissal filters the list the model holds.
        model.dismiss(shown)
        #expect(model.inboxParcels.isEmpty)
        #expect(model.toasts.last?.text == "Parcel dismissed")
        #expect(try engine.prefs()["inbox.dismissed_parcels"] as? [String] == [ParcelCard.entry(shown)])
        // Another device (a second model over the same prefs) hides it too.
        let other = AppModel(engine: engine)
        other.reload()
        await other.settleReloads()
        #expect(other.parcels.count == 1 && other.inboxParcels.isEmpty)
        // Undo brings it back, at once, and clears the pref.
        #expect(model.undoLast())
        #expect(model.inboxParcels.count == 1)
        #expect(try engine.prefs()["inbox.dismissed_parcels"] as? [String] == [])
        // Dismiss all, then a newer email about the parcel: back by itself.
        model.dismissAllParcels()
        #expect(model.inboxParcels.isEmpty)
        engine.parcelStore = [parcel("thread:t4", at: shown.at.addingTimeInterval(60), progress: .outForDelivery)]
        model.reload()
        await model.settleReloads()
        #expect(model.inboxParcels.first?.progress == .outForDelivery)
    }

    @Test func theSettingTurnsTheCardOffEverywhere() async throws {
        model.parcelCardEnabled = false
        #expect(model.inboxParcels.isEmpty)
        #expect(try engine.prefs()["inbox.parcel_card"] as? Bool == false)
        model.reload()
        #expect(model.parcels.isEmpty, "off, the reload carries none")
        await model.settleReloads()
        #expect(model.parcels.isEmpty, "and does not ask for parcels")
        let other = AppModel(engine: engine)
        #expect(!other.parcelCardEnabled)
    }

    /// From an empty inbox to another empty folder no row moves: the card
    /// must still go (it once followed only the rows).
    @Test func theCardLeavesWithTheFolderEvenWhenNoRowMoves() async throws {
        let empty = MockEngine()
        for row in try empty.threads(in: .inbox, accountId: nil, before: nil, limit: 100) where row.id != "t4" {
            try await empty.perform(.trash(threadId: row.id), accountId: row.accountId)
        }
        try await empty.perform(.archive(threadId: "t4"), accountId: "me@personal.test")
        empty.parcelStore = [parcel("thread:t4")]
        let model = AppModel(engine: empty)
        model.reload()
        await model.settleReloads()
        #expect(model.rows.isEmpty && model.inboxParcels.count == 1 && !model.listIsEmpty)
        model.navigate(to: .inbox, folder: .spam)
        #expect(model.rows.isEmpty && model.inboxParcels.isEmpty && model.listIsEmpty)
        model.navigate(to: .inbox, folder: .inbox)
        #expect(model.inboxParcels.count == 1)
    }

    @Test func viewDetailsOpensTheBundleOnItsInfoPage() throws {
        let shown = try #require(model.inboxParcels.first)
        model.openParcelDetails(shown)
        #expect(model.showBundles && model.bundlesStartId == "b1" && model.bundlesStartInfoId == "b1")
        // Any other way into Bundles opens on Emails: the Info page asked
        // for by a screen that never appeared does not wait for the next.
        model.openBundles(at: "b1")
        #expect(model.bundlesStartId == "b1" && model.bundlesStartInfoId == nil)
    }

    @Test func aParcelGoesWithItsBundle() throws {
        model.setBundleArchived(try #require(model.bundle(id: "b1")), true)
        #expect(model.inboxParcels.isEmpty)
    }

    /// The sample order (the mock the app runs on without an account):
    /// two read emails that would fold, and two parcels.
    @Test func theSampleOrdersQuietMailStandsUnderItsParcel() async throws {
        let sample = MockEngine.withSampleOrder()
        let model = AppModel(engine: sample)
        model.reload()
        await model.settleReloads()
        #expect(model.inboxParcels.map(\.bundleId) == ["b2", "b2"])
        let fold = try #require(model.parcelFolds["b2"])
        #expect(Set(fold.rows.map(\.id)) == ["t9", "t10"])
        let listed = Set(model.groupedRows.flatMap { $0.rows.map(\.id) })
        if AppModel.foldsOnThisPlatform {
            // No folded row for the bundle and no rows for its quiet mail:
            // it is counted on the first parcel.
            #expect(model.groupedRows.flatMap(\.folds).isEmpty)
            #expect(listed.isDisjoint(with: ["t9", "t10"]))
            #expect(model.parcelUpdates(model.inboxParcels[0]) == 2)
            #expect(model.parcelUpdates(model.inboxParcels[1]) == 0)
        } else {
            // The Mac does not fold: every thread keeps its row.
            #expect(listed.isSuperset(of: ["t9", "t10"]))
            #expect(model.parcelUpdates(model.inboxParcels[0]) == 0)
        }
        // Dismissed, the bundle folds as any other again.
        model.dismissAllParcels()
        #expect(model.toasts.last?.text == "2 parcels dismissed")
        #expect(model.parcelFolds.isEmpty)
        if AppModel.foldsOnThisPlatform {
            #expect(model.groupedRows.flatMap(\.folds).map(\.id) == ["b2"])
        }
        #expect(model.undoLast())
        // Mark all done: the quiet mail is done, the parcels stay.
        model.markDone(try #require(model.parcelFolds["b2"]))
        #expect(model.parcelFolds.isEmpty)
        #expect(model.inboxParcels.count == 2)
        #expect(!model.rows.contains { $0.id == "t9" || $0.id == "t10" })
    }
}
