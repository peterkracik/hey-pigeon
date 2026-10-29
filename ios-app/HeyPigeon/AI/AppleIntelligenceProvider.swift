// Apple's on-device model as the app's AI provider (docs/ios-intelligence.md,
// step 5): AI with no key, no account and no network on an Apple
// Intelligence device. The Rust core calls back into this through the
// UniFFI `AiBackend` trait (crates/ffi/src/ai.rs); the summary, draft, edit
// and triage paths never learn which provider answered.
//
// The model is small and its context window is short (4,096 tokens on
// iOS 26, instructions + prompt + answer). A prompt that does not fit is
// split on its blank lines, each part answered under the same instruction,
// and the parts' answers answered once more — a thread that does not fit
// degrades to a summary of summaries, never to an error.

import FoundationModels
import HeyPigeonCore

final class AppleIntelligenceProvider: AiBackend, @unchecked Sendable {
    static let providerId = "apple"
    static let modelId = "apple-on-device"

    /// Whether this device can run the model right now.
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Why not, for Settings copy ("Apple Intelligence is off", …).
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This device can't run Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in Settings."
        case .unavailable(.modelNotReady): return "The model is still downloading."
        case .unavailable: return "Apple Intelligence isn't available right now."
        }
    }

    /// Rough budget for one prompt, in characters (~4 per token): the window
    /// less room for the instruction and the answer.
    private let promptBudget = 9_000

    // MARK: AiBackend

    func id() -> String { Self.providerId }

    func models() -> [AiModel] {
        [AiModel(id: Self.modelId, label: "On this iPhone")]
    }

    func complete(system: String, user: String) async throws -> String {
        try await answer(system: system, prompt: user, depth: 0)
    }

    private func answer(system: String, prompt: String, depth: Int) async throws -> String {
        if prompt.count <= promptBudget || depth >= 2 {
            return try await respond(system: system, prompt: String(prompt.prefix(promptBudget)))
        }
        // Too long: answer the parts, then answer the answers.
        var parts: [String] = []
        for chunk in Self.chunks(prompt, budget: promptBudget) {
            parts.append(try await respond(system: system, prompt: chunk))
        }
        return try await answer(system: system, prompt: parts.joined(separator: "\n\n"), depth: depth + 1)
    }

    private func respond(system: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: system)
        do {
            return try await session.respond(to: prompt).content
        } catch let error as LanguageModelSession.GenerationError {
            throw EngineError.Ai(message: Self.describe(error))
        }
    }

    func classify(subject: String, snippet: String, from: String, labels: [TriageLabel]) async throws -> TriageVerdict {
        let names = labels.map(\.name)
        let instructions = """
        You sort one email for a busy person. Decide its priority — spam (junk, phishing, promotions), \
        low (informational, no action), medium (worth reading soon), high (needs prompt attention) — \
        and which of the person's own labels apply, if any. Only use labels from the list given. Judge \
        from the sender, subject and preview only.
        """
        let prompt = """
        From: \(from)
        Subject: \(subject)
        Preview: \(snippet)
        Available labels: \(names.isEmpty ? "(none)" : names.joined(separator: ", "))
        """
        let session = LanguageModelSession(instructions: instructions)
        let verdict: TriageCall
        do {
            verdict = try await session.respond(to: prompt, generating: TriageCall.self).content
        } catch let error as LanguageModelSession.GenerationError {
            throw EngineError.Ai(message: Self.describe(error))
        }
        let ids = verdict.labels.compactMap { name in
            labels.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
        }
        return TriageVerdict(priority: verdict.priority.ffi, labelIds: Array(Set(ids)))
    }

    // MARK: Helpers

    /// Split on blank lines (one message, one email), packing paragraphs up
    /// to the budget; a single paragraph longer than the budget is cut.
    static func chunks(_ text: String, budget: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n\n") {
            let p = paragraph.count > budget ? String(paragraph.prefix(budget)) : paragraph
            if current.isEmpty {
                current = p
            } else if current.count + 2 + p.count <= budget {
                current += "\n\n" + p
            } else {
                out.append(current)
                current = p
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize: "The text is too long for the on-device model."
        case .guardrailViolation: "The on-device model declined this content."
        case .unsupportedLanguageOrLocale: "The on-device model doesn't support this language."
        case .assetsUnavailable: "The on-device model isn't ready. Try again later."
        default: error.localizedDescription
        }
    }
}

/// The structured triage answer (guided generation: the model fills the
/// type, nothing is parsed).
@Generable
struct TriageCall {
    @Guide(description: "How urgent the email is for the recipient.")
    var priority: TriagePriority
    @Guide(description: "The labels from the available list that apply, by their exact names. Empty when none fits.", .count(0...3))
    var labels: [String]
}

@Generable
enum TriagePriority: String {
    case spam, low, medium, high

    var ffi: Priority {
        switch self {
        case .spam: .spam
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }
}
