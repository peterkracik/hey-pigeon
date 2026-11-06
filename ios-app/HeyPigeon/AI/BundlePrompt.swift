// The bundling prompt for new mail, in one place (the core decides which
// emails to ask about and keeps the bundles: crates/ffi/src/bundles.rs).
// The model reads one email's sender, subject and preview with the active
// bundles and fills `BundleCall`: join a listed bundle by its exact name,
// start a new trip / shopping / project bundle, or none. Pure Foundation,
// so the mapping is tested without a model (BundleTests).

import Foundation

/// What the model decided for one email, in app terms (the backend turns
/// it into the core's `BundleChoice`).
enum BundleDecision: Equatable {
    case join(bundleId: String)
    case new(name: String, category: BundleCategory)
    case noBundle
}

/// The shipped bundling prompt and the rules around its answer.
enum BundlePrompt {
    static let instructions = """
    You sort a person's email into bundles. A bundle is one specific thing they are dealing with: \
    one trip, one purchase, or one project. Given one email and the bundles that already exist, \
    answer with exactly one action, and say how sure you are. \
    join: the email is clearly part of one listed bundle; give its name exactly as listed. The email \
    must be about the same specific thing: the same destination and dates for a trip, the same store \
    and order for a purchase, the same project and people for a project. Being the same kind of thing \
    is not enough: an order from another store is not part of this order, a hotel in another city is \
    not part of this trip. \
    new: the email is clearly about one specific trip, purchase or project that no listed bundle \
    covers; give a short name and its kind. \
    nothing: everything else, and whenever you are not sure. This includes newsletters, promotions, \
    social networks, personal chat, account and security notices, bills and subscriptions that repeat \
    every month, appointments and reservations at local shops, services, doctors and restaurants, \
    calendar invitations, and anything not tied to one trip, purchase or project. \
    trip: travel to one place on certain dates. Flights, trains, buses, hotels, rentals, tickets, \
    check-in, itineraries, and reservations in the destination during the trip. Name it after the \
    destination, like "Lisbon trip". An appointment, a reservation or an order that does not name the \
    destination is never part of a trip. \
    shopping: one order and everything after it: confirmation, invoice, shipping, delivery, returns. \
    Name it after the store, like "Zalando order", or after the occasion when the email says so, like \
    "Christmas shopping". \
    project: ongoing work on one topic with the same people or company. Name it after the project, \
    like "Acme website". \
    Never name a bundle just "Trip", "Shopping" or "Project". \
    confidence: high only when the subject or preview itself names the trip's destination, the store \
    or order, or the project. Otherwise medium or low. Only a high-confidence join or new counts; a \
    low-confidence answer is treated as nothing, so prefer nothing when the email could be about \
    something else. \
    kind: what the email itself is about (trip, shopping, project), or other.
    """

    /// One email with the bundles it may join, as the model sees it.
    static func prompt(subject: String, from: String, snippet: String,
                       bundles: [(name: String, category: BundleCategory, description: String, examples: [String], notExamples: [String])]) -> String {
        var lines: [String] = []
        if bundles.isEmpty {
            lines.append("Existing bundles: none yet.")
        } else {
            lines.append("Existing bundles:")
            for b in bundles {
                var line = "- \(b.name) (\(b.category.rawValue))"
                if !b.description.isEmpty { line += ": \(b.description)" }
                if !b.examples.isEmpty {
                    line += " — has: " + b.examples.prefix(3).map { "\"\($0)\"" }.joined(separator: ", ")
                }
                // What the user took out: mail like this does not belong.
                if !b.notExamples.isEmpty {
                    line += " — not: " + b.notExamples.prefix(3).map { "\"\($0)\"" }.joined(separator: ", ")
                }
                lines.append(line)
            }
        }
        lines.append("")
        lines.append("Email")
        lines.append("From: \(from)")
        lines.append("Subject: \(subject.isEmpty ? "(no subject)" : subject)")
        if !snippet.isEmpty { lines.append("Preview: \(snippet)") }
        return lines.joined(separator: "\n")
    }

    /// The model's answer against the bundles it was shown. Only a
    /// high-confidence answer counts: a wrong email in a bundle costs trust,
    /// a missing one costs a tap. A join names a listed bundle (matched
    /// without case) of the same kind as the email; a new bundle needs a
    /// name and a kind of trip, shopping or project.
    static func decision(action: String, bundle: String, name: String, kind: String, confidence: String,
                         candidates: [(id: String, name: String, category: BundleCategory)]) -> BundleDecision {
        guard confidence == "high" else { return .noBundle }
        let emailKind = BundleCategory(rawValue: kind) ?? .other
        switch action {
        case "join":
            let wanted = bundle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let match = candidates.first(where: { $0.name.lowercased() == wanted }) else { return .noBundle }
            // A shop appointment is not a trip, whatever the model picked.
            guard emailKind == match.category else { return .noBundle }
            return .join(bundleId: match.id)
        case "new":
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, emailKind != .other else { return .noBundle }
            // The model sometimes answers "new" with a listed name.
            if let match = candidates.first(where: { $0.name.lowercased() == trimmed.lowercased() }) {
                return match.category == emailKind ? .join(bundleId: match.id) : .noBundle
            }
            return .new(name: trimmed, category: emailKind)
        default:
            return .noBundle
        }
    }
}
