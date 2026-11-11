// What a bundle's Info page works out from the tracking links and key
// facts the core hands over (docs/bundles.md), as pure functions: a name
// for a link's row, which links are the same shipment, and the facts
// kind by kind. The core gives a link its address, host, email and that
// email's subject, and nothing that says which parcel it tracks or when:
// so two links are one shipment only when that can be read off them (the
// same email, or the same tracking or order number in both addresses),
// never because they share a shop.

import Foundation

enum BundleTracking {
    /// One shipment's row: its newest email's link, and the earlier
    /// emails about it, newest first.
    struct Shipment: Identifiable, Hashable {
        let link: BundleLinkItem
        var earlier: [BundleLinkItem] = []
        var id: URL { link.url }
    }

    /// Hosts that only pass a click on to the carrier (mail services'
    /// and analytics' redirects): `unitedparcelservice.sc.omtrdc.net`
    /// says nothing a reader knows, so it is never a row's name.
    private static let redirects = [
        "omtrdc.net", "sendgrid.net", "list-manage.com", "mandrillapp.com", "mailgun.org", "sparkpostmail.com",
        "awstrack.me", "mjt.lu", "exacttarget.com", "klclick.com", "hubspotlinks.com", "doubleclick.net",
    ]

    /// Names whose spelling is not the host's label with a capital.
    private static let brands = [
        "ups": "UPS", "dhl": "DHL", "dpd": "DPD", "gls": "GLS", "tnt": "TNT", "usps": "USPS", "fedex": "FedEx",
        "royalmail": "Royal Mail", "postnl": "PostNL", "ebay": "eBay", "aliexpress": "AliExpress",
    ]

    /// The labels that sit between a name and a country (`amazon.co.uk`).
    private static let secondLevel: Set<String> = ["co", "com", "org", "net", "ac", "gov"]

    static func isRedirect(host: String) -> Bool {
        let h = host.lowercased()
        return redirects.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// The carrier or shop a host belongs to, as a reader would say it:
    /// `www.amazon.de` → "Amazon", `track.dpd.example` → "DPD". Nil for a
    /// redirect's host and for one with no name in it (an IP address);
    /// the row then takes its email's sender.
    static func name(host: String) -> String? {
        guard !isRedirect(host: host) else { return nil }
        var labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        labels.removeLast()
        if labels.count >= 2, let last = labels.last, secondLevel.contains(last) { labels.removeLast() }
        guard let label = labels.last, label.contains(where: \.isLetter) else { return nil }
        if let known = brands[label] { return known }
        return label.prefix(1).uppercased() + String(label.dropFirst())
    }

    /// The links (newest first, as the core gives them) as shipments, in
    /// the same order. Links are one shipment when they come from the
    /// same email, or when the same tracking or order number from the
    /// bundle's facts is in both addresses. Within one email a
    /// redirect's link gives way to the carrier's own.
    static func shipments(links: [BundleLinkItem], facts: [BundleFactItem]) -> [Shipment] {
        // Tracking numbers before order numbers; short ones are left out,
        // since "4545" is in many an address by chance.
        let numbers = (facts.filter { $0.category == .tracking } + facts.filter { $0.category == .order })
            .map { $0.value.uppercased() }
            .filter { $0.count >= 6 }
        var order: [String] = []
        var groups: [String: [BundleLinkItem]] = [:]
        for link in links {
            let address = link.url.absoluteString.uppercased()
            let key = numbers.first { address.contains($0) }.map { "number:" + $0 } ?? "thread:" + link.threadId
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(link)
        }
        return order.compactMap { key in
            // One link per email, the carrier's own where there is one.
            var perEmail: [BundleLinkItem] = []
            for link in groups[key] ?? [] {
                if let i = perEmail.firstIndex(where: { $0.threadId == link.threadId }) {
                    if isRedirect(host: perEmail[i].host) && !isRedirect(host: link.host) { perEmail[i] = link }
                } else {
                    perEmail.append(link)
                }
            }
            guard let newest = perEmail.first else { return nil }
            return Shipment(link: newest, earlier: Array(perEmail.dropFirst()))
        }
    }

    /// The facts with each kind's together, the kinds in the order they
    /// first appear, so a kind is named once over its run.
    static func byKind(_ facts: [BundleFactItem]) -> [BundleFactItem] {
        var kinds: [BundleFactCategory] = []
        for f in facts where !kinds.contains(f.category) { kinds.append(f.category) }
        return kinds.flatMap { kind in facts.filter { $0.category == kind } }
    }
}
