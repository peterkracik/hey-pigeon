// The parcel card (docs/specs/parcel-card.md): the parcels that are on
// their way, as a card at the top of the plain inbox — what each one is,
// when it is expected, and a Track parcel button. One view for the phone,
// the iPad and the Mac window; each puts it at the head of its own list
// (`ThreadList`, macos-app `InboxPage`).
//
// The core works out what a parcel is and what its mail says about it
// (crates/core/src/parcels.rs: status, expected day, item title; nothing
// is guessed, and a delivered parcel leaves by itself). The model holds
// the list (`AppModel.inboxParcels`, read with every reload) and the
// actions. What is here is the wording and the rules that are the
// shell's own, as pure functions (`ParcelCard`), and the view.
//
// No product pictures: loading one would be a request to the shop from
// the inbox, which the remote-images default forbids. The bundle's icon
// stands in the thumbnail's place.

import SwiftUI

/// The card's rules and words, apart from any view.
enum ParcelCard {
    /// How long a dismissal is kept, counted from the parcel's email: by
    /// then the parcel left the card by itself long ago.
    static let dismissalsKept: TimeInterval = 180 * 86_400

    /// Epoch milliseconds; a date no Int64 holds (a pref can carry any
    /// number) is the far end rather than a trap.
    private static func ms(_ date: Date) -> Int64 {
        Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded()) ?? .max
    }

    /// A dismissal as the synced pref stores it: the parcel's id and the
    /// time of its newest email, `number:bfa83b19dfd2e747@1795089600000`.
    /// The id is the core's: a digest of the tracking or order number,
    /// never the number, because this is written to a pref that syncs.
    /// The time is what lets the parcel come back: a newer email is a
    /// newer time.
    static func entry(_ parcel: ParcelItem) -> String { "\(parcel.id)@\(ms(parcel.at))" }

    /// An entry's id and time; nil for anything else a pref may hold.
    static func parse(_ entry: String) -> (id: String, at: Int64)? {
        guard let split = entry.lastIndex(of: "@"), let at = Int64(entry[entry.index(after: split)...]) else { return nil }
        let id = String(entry[..<split])
        return id.isEmpty ? nil : (id, at)
    }

    /// The parcels the card shows: the account's (nil = every account's),
    /// without the dismissed ones. A parcel is dismissed while no email
    /// about it is newer than the one it was dismissed at.
    static func visible(_ parcels: [ParcelItem], dismissed: [String], accountId: String?) -> [ParcelItem] {
        var dismissedAt: [String: Int64] = [:]
        for entry in dismissed.compactMap(parse) {
            dismissedAt[entry.id] = max(dismissedAt[entry.id] ?? .min, entry.at)
        }
        return parcels.filter { parcel in
            (accountId == nil || parcel.accountId == accountId) && (dismissedAt[parcel.id] ?? .min) < ms(parcel.at)
        }
    }

    /// The pref after dismissing `parcels`: one entry per parcel (an
    /// earlier one for the same parcel is replaced), the ones older than
    /// `dismissalsKept` dropped, sorted so two devices write the same.
    static func dismissing(_ parcels: [ParcelItem], from dismissed: [String], now: Date = Date()) -> [String] {
        let ids = Set(parcels.map(\.id))
        let oldest = ms(now.addingTimeInterval(-dismissalsKept))
        let kept = dismissed.filter { entry in
            guard let parsed = parse(entry) else { return false }
            return !ids.contains(parsed.id) && parsed.at >= oldest
        }
        return Array(Set(kept + parcels.map(entry))).sorted()
    }

    /// The row's first line: what is in the parcel, else the bundle's name.
    static func title(_ parcel: ParcelItem, bundle: BundleItem?) -> String {
        if let title = parcel.title, !title.isEmpty { return title }
        if let name = bundle?.name, !name.isEmpty { return name }
        return parcel.subject.isEmpty ? "Parcel" : parcel.subject
    }

    /// "Track parcel, opens track.dhl.com", for VoiceOver: the button's
    /// words alone do not say which of several parcels it tracks, nor
    /// where it leads. The host is the link's own (`ParcelItem.host`),
    /// never a name: a carrier's name worked out from a host's label read
    /// "DHL" for `dhl.top`, and the email's sender is whoever the email
    /// says it is.
    static func trackLabel(_ parcel: ParcelItem) -> String {
        "Track parcel, opens \(parcel.host)"
    }

    /// `2026-11-20`: a calendar day in the form the core hands one over.
    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "Expected tomorrow" for a day as the core hands it over; nil for
    /// anything that is not a date.
    static func expected(_ day: String, now: Date = Date(), calendar: Calendar = .current) -> String? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let away = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: date).day
        else { return nil }
        let style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        switch away {
        case 0: return "Expected today"
        case 1: return "Expected tomorrow"
        case -1: return "Expected yesterday"
        case 2...6: return "Expected \(date.formatted(style.weekday(.wide)))"
        default: return "Expected \(date.formatted(style.day().month(.abbreviated)))"
        }
    }

    /// The row's second line (R12), the first that applies: delivered;
    /// out for delivery; the day it is expected — each followed by the
    /// host the Track button opens; else that host, "Shipped" when that
    /// much is known or the email's subject when not, and the email's
    /// time. The host is on every form of the line: the title and the
    /// subject are the mail's words, and the host is the one thing on
    /// the row the mail cannot dress up. It stands before the subject so
    /// a long subject cannot push it off the line. `updates` is the
    /// bundle's folded mail under this row (`AppModel.parcelUpdates`),
    /// named at the end.
    static func statusLine(_ parcel: ParcelItem, updates: Int = 0, now: Date = Date(), calendar: Calendar = .current) -> String {
        var line: String
        if parcel.progress == .delivered {
            line = "Delivered · \(parcel.host)"
        } else if parcel.progress == .outForDelivery {
            line = "Out for delivery · \(parcel.host)"
        } else if let phrase = parcel.expectedDay.flatMap({ expected($0, now: now, calendar: calendar) }) {
            line = "\(phrase) · \(parcel.host)"
        } else {
            let what = parcel.progress == .shipped ? "Shipped" : (parcel.subject.isEmpty ? nil : parcel.subject)
            line = [parcel.host, what, Formatters.rowTime(parcel.at, now: now)].compactMap { $0 }.joined(separator: " · ")
        }
        if updates > 0 { line += " · \(updates) updates" }
        return line
    }

    /// How much folded mail stands under a parcel's row: the quiet inbox
    /// mail of its bundle, counted on the bundle's first parcel in the
    /// card and on no other. Nothing where the inbox does not fold.
    static func updates(for parcel: ParcelItem, in shown: [ParcelItem], folds: [String: BundleFold], folding: Bool) -> Int {
        guard folding, shown.first(where: { $0.bundleId == parcel.bundleId })?.id == parcel.id else { return 0 }
        return folds[parcel.bundleId]?.rows.count ?? 0
    }

    /// The toast after a dismissal.
    static func dismissedToast(_ count: Int) -> String {
        count == 1 ? "Parcel dismissed" : "\(count) parcels dismissed"
    }
}

/// The card: "Parcels", the first parcel, and "+N more" for the rest;
/// expanded, every parcel and a footer with Show less and Dismiss all.
struct ParcelCardView: View {
    /// The card's surface: the list's card colour (the Mac window hands
    /// its own white group card).
    var surface: Color = Theme.card
    @Environment(AppModel.self) private var model

    var body: some View {
        let parcels = model.inboxParcels
        if let first = parcels.first {
            VStack(alignment: .leading, spacing: 0) {
                header
                ParcelRow(parcel: first)
                if model.parcelsExpanded {
                    ForEach(parcels.dropFirst()) { parcel in
                        divider
                        ParcelRow(parcel: parcel)
                    }
                }
                if parcels.count > 1 {
                    divider
                    footer(more: parcels.count - 1)
                }
            }
            .background(surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.separator))
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, 14)
    }

    private var header: some View {
        HStack {
            Text("Parcels")
                .font(Theme.display(13, relativeTo: .caption))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { model.dismissAllParcels() } label: {
                Image(systemName: "xmark")
                    .font(Theme.glyph(.caption, .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .tapArea(horizontal: 14, vertical: 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss all parcels")
            .help("Dismiss all")
        }
        .padding(.leading, 14).padding(.trailing, 14).padding(.top, 12).padding(.bottom, 2)
    }

    private func footer(more: Int) -> some View {
        HStack {
            Button {
                withAnimation(Motion.animation(.snappy(duration: 0.2))) { model.parcelsExpanded.toggle() }
            } label: {
                Label(model.parcelsExpanded ? "Show less" : "+\(more) more",
                      systemImage: model.parcelsExpanded ? "chevron.up" : "chevron.down")
                    .font(Theme.text(.bodySmall, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .tapArea(horizontal: 14, vertical: 12)
            }
            .buttonStyle(.plain)
            .accessibilityHint(model.parcelsExpanded ? "Shows only the first parcel" : "Shows every parcel")
            Spacer()
            if model.parcelsExpanded {
                Button { model.dismissAllParcels() } label: {
                    Text("Dismiss all")
                        .font(Theme.text(.bodySmall, .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .tapArea(horizontal: 14, vertical: 12)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

/// One parcel: the bundle's icon, what it is, where it stands, and its
/// three actions. The texts read as one element; Track parcel is a button
/// of its own, named with the host it opens.
private struct ParcelRow: View {
    let parcel: ParcelItem
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let bundle = model.bundle(id: parcel.bundleId)
        HStack(alignment: .top, spacing: 12) {
            BundleIcon(category: bundle?.category ?? .shopping, size: 40)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ParcelCard.title(parcel, bundle: bundle))
                        .font(Theme.sender(false))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Text(ParcelCard.statusLine(parcel, updates: model.parcelUpdates(parcel)))
                        .font(Theme.secondary)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityAction(named: "Track parcel") { track() }
                .accessibilityAction(named: "View details") { model.openParcelDetails(parcel) }
                .accessibilityAction(named: "Open email") { model.openThread(id: parcel.threadId) }
                .accessibilityAction(named: "Dismiss") { model.dismiss(parcel) }
                actions
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .contentShape(Rectangle())
        .contextMenu { ParcelMenu(parcel: parcel) }
    }

    /// Side by side; under each other at the accessibility text sizes,
    /// where the three no longer fit one line.
    @ViewBuilder private var actions: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                trackButton
                detailsButton
                moreMenu
            }
        } else {
            HStack(spacing: 18) {
                trackButton
                detailsButton
                Spacer(minLength: 0)
                moreMenu
            }
        }
    }

    private func track() {
        Haptics.light()
        Browser.open(parcel.url)
    }

    private var trackButton: some View {
        Button(action: track) {
            Text("Track parcel")
                .font(Theme.text(.bodySmall, .bold))
                .foregroundStyle(Theme.onPrimary)
                .padding(.horizontal, 6)
        }
        .pillButton(prominent: true)
        .tint(Theme.textPrimary)
        .accessibilityLabel(ParcelCard.trackLabel(parcel))
        .help("Opens \(parcel.host)")
    }

    private var detailsButton: some View {
        Button { model.openParcelDetails(parcel) } label: {
            Text("View details")
                .font(Theme.text(.bodySmall, .medium))
                .foregroundStyle(Theme.textSecondary)
                .tapArea(horizontal: 8, vertical: 12)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the bundle")
    }

    private var moreMenu: some View {
        Menu {
            ParcelMenu(parcel: parcel)
        } label: {
            Image(systemName: "ellipsis")
                .font(Theme.glyph(.bodySmall, .semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 32, height: 32)
                .tapArea(horizontal: 6, vertical: 6)
        }
        .labelOnlyMenu()
        .accessibilityLabel("More for this parcel")
    }
}

/// A parcel's menu, under "…" and on a long press or a right click. Its
/// first section says where the Track button leads: the host is the
/// link's own, not the email's word for it.
private struct ParcelMenu: View {
    let parcel: ParcelItem
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Opens \(parcel.host)") {
            Button {
                Browser.open(parcel.url)
            } label: { Label("Track parcel", systemImage: "arrow.up.right") }
        }
        Button { model.openBundles(at: parcel.bundleId) } label: { Label("Open bundle", systemImage: "square.stack") }
        Button { model.openThread(id: parcel.threadId) } label: { Label("Open email", systemImage: "envelope") }
        if let fold = model.parcelFolds[parcel.bundleId] {
            Button { model.markDone(fold) } label: { Label("Mark all done", systemImage: "checkmark") }
        }
        Button { model.dismiss(parcel) } label: { Label("Dismiss", systemImage: "xmark") }
    }
}
