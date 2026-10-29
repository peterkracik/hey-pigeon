// The one AI door on iOS (docs/ios-intelligence.md, "iOS 27 › One model
// layer"): the Rust core calls back into this through the UniFFI
// `AiBackend` trait (crates/ffi/src/ai.rs), one instance per
// `ModelProvider` the device can run, registered with
// `Engine.addAiBackend`. The summary, draft, edit and triage paths in the
// core never learn which model answered; the core picks the provider
// (preferred, then the fallback order) and this class runs the request on
// its `LanguageModelSession`.
//
// Context windows differ per model (4K tokens on device, 32K in Apple's
// cloud). A prompt that does not fit the provider's budget is split on its
// blank lines, each part answered under the same instruction, and the
// parts' answers answered once more — a thread that does not fit degrades
// to a summary of summaries, never to an error. Every answer's token usage
// lands in `AiUsageLedger`, which Settings › AI shows per provider.

import Foundation
import FoundationModels
import HeyPigeonCore

final class FoundationModelsBackend: AiBackend, @unchecked Sendable {
    let provider: any ModelProvider
    private let ledger: AiUsageLedger

    init(provider: any ModelProvider, ledger: AiUsageLedger = .shared) {
        self.provider = provider
        self.ledger = ledger
    }

    // MARK: AiBackend

    func id() -> String { provider.id }

    func models() -> [AiModel] {
        [AiModel(id: provider.modelId, label: provider.modelLabel)]
    }

    func complete(system: String, user: String) async throws -> String {
        try await answer(system: system, prompt: user, depth: 0)
    }

    func classify(subject: String, snippet: String, from: String, labels: [TriageLabel]) async throws -> TriageVerdict {
        let names = labels.map(\.name)
        let session = provider.session(instructions: TriagePrompt.instructions, task: .classification)
        let verdict: TriageCall
        do {
            let response = try await session.respond(
                to: TriagePrompt.prompt(from: from, subject: subject, snippet: snippet, labels: names),
                generating: TriageCall.self
            )
            ledger.record(provider: provider.id, response.usage)
            verdict = response.content
        } catch let error as LanguageModelSession.GenerationError {
            throw EngineError.Ai(message: Self.describe(error))
        }
        return TriageVerdict(priority: verdict.priority.ffi, labelIds: TriagePrompt.labelIds(for: verdict.labels, in: labels))
    }

    // MARK: Completion with chunking

    private func answer(system: String, prompt: String, depth: Int) async throws -> String {
        let budget = provider.promptBudget
        if prompt.count <= budget || depth >= 2 {
            return try await respond(system: system, prompt: String(prompt.prefix(budget)))
        }
        // Too long: answer the parts, then answer the answers.
        var parts: [String] = []
        for chunk in Self.chunks(prompt, budget: budget) {
            parts.append(try await respond(system: system, prompt: chunk))
        }
        return try await answer(system: system, prompt: parts.joined(separator: "\n\n"), depth: depth + 1)
    }

    private func respond(system: String, prompt: String) async throws -> String {
        let session = provider.session(instructions: system, task: .completion)
        do {
            let response = try await session.respond(to: prompt)
            ledger.record(provider: provider.id, response.usage)
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            throw EngineError.Ai(message: Self.describe(error))
        }
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

    static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize: "The text is too long for this model."
        case .guardrailViolation: "The model declined this content."
        case .unsupportedLanguageOrLocale: "The model doesn't support this language."
        case .assetsUnavailable: "The model isn't ready. Try again later."
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
