// The triage prompt, in one place: the backend classifies with it and the
// Evaluations harness (HeyPigeonTests/Evaluations) scores variants of it
// against a labeled set. Hill-climb `instructions` here; the test target
// says whether the change helped.

import Foundation
import HeyPigeonCore

/// The shipped triage prompt and the helpers both the backend and the
/// evaluation use.
enum TriagePrompt {
    /// The instruction the shipped classifier runs with.
    static var instructions: String { TriagePromptVariant.shipped.instructions }

    /// One email as the model sees it: sender, subject, preview, the
    /// user's label names. Never the body.
    static func prompt(from: String, subject: String, snippet: String, labels: [String]) -> String {
        """
        From: \(from)
        Subject: \(subject)
        Preview: \(snippet)
        Available labels: \(labels.isEmpty ? "(none)" : labels.joined(separator: ", "))
        """
    }

    /// The model answers with label *names*; only ids of labels it was
    /// given count, matched without case, each once.
    static func labelIds(for names: [String], in labels: [TriageLabel]) -> [String] {
        var ids: [String] = []
        for name in names {
            guard let id = labels.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.id else { continue }
            if !ids.contains(id) { ids.append(id) }
        }
        return ids
    }
}

/// A named version of the triage instruction. `shipped` is what the app
/// runs; the others are candidates the evaluation compares it with.
struct TriagePromptVariant: Identifiable, Hashable, Sendable {
    let id: String
    let instructions: String

    static let shipped = TriagePromptVariant(
        id: "shipped",
        instructions: """
        You sort one email for a busy person. Decide its priority — spam (junk, phishing, promotions), \
        low (informational, no action), medium (worth reading soon), high (needs prompt attention) — \
        and which of the person's own labels apply, if any. Only use labels from the list given. Judge \
        from the sender, subject and preview only.
        """
    )

    /// Spells out what each priority is for, with the common mistakes named.
    static let explicit = TriagePromptVariant(
        id: "explicit",
        instructions: """
        You sort one email for a busy person into a priority and the person's own labels.
        Priority: spam = junk, phishing, cold outreach, promotions and marketing; low = automated \
        notifications, receipts, newsletters, anything informational that needs no action; medium = \
        from a person or a service the recipient uses, worth reading soon, no deadline; high = a \
        person asking the recipient for something, a deadline, a payment due, travel the same week, \
        or a problem with an account. A newsletter is never high. A receipt is low even when it names \
        an amount. Labels: only names from the list given, only when the email clearly belongs; an \
        empty list is a fine answer. Judge from the sender, subject and preview only.
        """
    )

    /// Shorter, for the on-device model's window.
    static let terse = TriagePromptVariant(
        id: "terse",
        instructions: """
        Classify one email. priority: spam (junk, promotions), low (no action), medium (read soon), \
        high (needs action). labels: zero or more names from the given list only. Use sender, subject, preview.
        """
    )

    static let candidates: [TriagePromptVariant] = [shipped, explicit, terse]
}
