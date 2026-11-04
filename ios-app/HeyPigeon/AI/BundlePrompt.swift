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
    a trip, a purchase, or a project. Given one email and the bundles that already exist, answer \
    with exactly one action. join: the email belongs to one listed bundle; give its name exactly as \
    listed. new: the email is clearly about one specific trip, purchase or project that no listed \
    bundle covers; give a short name and its kind. nothing: everything else — newsletters, promotions, \
    social networks, personal chat, account and security notices, bills and subscriptions that \
    repeat every month, anything not tied to one trip, purchase or project. \
    trip: travel to one place on certain dates — flights, trains, buses, hotels, rentals, tickets, \
    check-in, itineraries. Name it after the destination, like "Lisbon trip". \
    shopping: one order and everything after it — confirmation, invoice, shipping, delivery, \
    returns. Name it after the store, like "Zalando order", or after the occasion when the email \
    says so, like "Christmas shopping". \
    project: ongoing work on one topic with the same people or company. Name it after the project, \
    like "Acme website". \
    Prefer join when a listed bundle fits; a second order from the same store a few days later \
    joins its bundle. Never name a bundle just "Trip", "Shopping" or "Project". When unsure, \
    choose nothing.
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

    /// The model's answer against the bundles it was shown: a join names a
    /// listed bundle (matched without case, else no bundle); a new one needs
    /// a name and a kind of trip, shopping or project.
    static func decision(action: String, bundle: String, name: String, kind: String,
                         candidates: [(id: String, name: String)]) -> BundleDecision {
        switch action {
        case "join":
            let wanted = bundle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return candidates.first { $0.name.lowercased() == wanted }.map { .join(bundleId: $0.id) } ?? .noBundle
        case "new":
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let category = BundleCategory(rawValue: kind), category != .other else { return .noBundle }
            // The model sometimes answers "new" with a listed name.
            if let match = candidates.first(where: { $0.name.lowercased() == trimmed.lowercased() }) {
                return .join(bundleId: match.id)
            }
            return .new(name: trimmed, category: category)
        default:
            return .noBundle
        }
    }
}
