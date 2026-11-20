// The parcel card (docs/specs/parcel-card.md): the parcels that are on
// their way, at the top of the plain inbox — what each one is, when it is
// expected, and a Track parcel button. One view for the phone, the iPad
// and the Mac window; each puts it at the head of its own list
// (`ThreadList`, macos-app `InboxPage`).
//
// A card in name only. In the paper look (docs/specs/marker-look.md) it
// is a section of the list like any other: the title "Parcels" with its
// rule, the dismiss button after the rule, and each parcel a ruled row.
// Nothing is filled or outlined around it.
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
// in its outlined box stands in the thumbnail's place.

import SwiftUI

/// The section's rules and words, apart from any view.
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

    /// The status line cut in three around the host its button opens, so
    /// the view can set the host in the mono: it is an address, read as
    /// data, where the words around it are the interface's. The line's
    /// parts are joined by " · " and the host is one whole part, the
    /// first that is exactly it (it stands before the mail's own
    /// subject, which may hold anything). Put back together the three
    /// are the line; a line without the host comes back whole.
    static func statusPieces(_ line: String, host: String) -> (before: String, host: String, after: String) {
        let separator = " · "
        let parts = line.components(separatedBy: separator)
        guard !host.isEmpty, let at = parts.firstIndex(of: host) else { return (line, "", "") }
        let before = parts[..<at].map { $0 + separator }.joined()
        let after = parts[(at + 1)...].map { separator + $0 }.joined()
        return (before, host, after)
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

/// The section: "Parcels", the first parcel, and "+N more" for the rest;
/// expanded, every parcel and a footer with Show less and Dismiss all.
/// It stands straight on the list's paper: the title with its rule (the
/// dismiss button after it), a hairline between two parcels and over the
/// footer, and no card around any of it.
struct ParcelCardView: View {
    /// The surface a card would have been drawn on. Nothing is filled in
    /// this look — the section stands on the list's own paper — and the
    /// name stays for the Mac window's call (`ParcelCardView(surface:)`).
    var surface: Color = Theme.card
    /// How far the section stands in from the row its host hands it. The
    /// phone's list hands the row over 12 pt from the screen's edges
    /// (`ThreadList`, from when this was a card with a margin of its
    /// own) and its mail rows and their titles start at 16: 4 pt more
    /// lines the section up with them. A host that hands the row over at
    /// its own titles' margin passes 0.
    var inset: CGFloat = 4
    @Environment(AppModel.self) private var model

    var body: some View {
        let parcels = model.inboxParcels
        if let first = parcels.first {
            VStack(alignment: .leading, spacing: 0) {
                header
                ParcelRow(parcel: first)
                if model.parcelsExpanded {
                    ForEach(parcels.dropFirst()) { parcel in
                        RowRule()
                        ParcelRow(parcel: parcel)
                    }
                }
                if parcels.count > 1 {
                    RowRule()
                    footer(more: parcels.count - 1)
                }
            }
            .padding(.horizontal, inset)
        }
    }

    /// The section's title, as every group of rows has one; dismissing
    /// all is the control after its rule.
    private var header: some View {
        SectionTitle(title: "Parcels") {
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
        .padding(.top, 6).padding(.bottom, 6)
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
        .padding(.vertical, 12)
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
                        .font(Theme.sans(.body, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    status
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
        .padding(.top, 10).padding(.bottom, 12)
        .contentShape(Rectangle())
        .contextMenu { ParcelMenu(parcel: parcel) }
    }

    /// Where the parcel stands, with the host its button opens in the
    /// mono: the same words, read as one line.
    private var status: Text {
        let line = ParcelCard.statusLine(parcel, updates: model.parcelUpdates(parcel))
        let pieces = ParcelCard.statusPieces(line, host: parcel.host)
        return Text("\(Text(pieces.before))\(Text(pieces.host).font(Theme.meta))\(Text(pieces.after))")
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

    /// An outlined capsule: the inbox's one ink action is Compose.
    private var trackButton: some View {
        Button(action: track) {
            Text("Track parcel").font(Theme.text(.bodySmall, .semibold))
        }
        .buttonStyle(OutlineButtonStyle())
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
                .frame(width: 32, height: 32, alignment: .trailing)
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
