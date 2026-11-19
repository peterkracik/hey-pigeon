// The one AI door on iOS (docs/ios-intelligence.md, "iOS 27 › One model
// layer"): the Rust core calls back into this through the UniFFI
// `AiBackend` trait (crates/ffi/src/ai.rs), one instance per
// `ModelProvider` the device can run, registered with
// `Engine.addAiBackend`. The summary, draft, edit, triage and new-mail
// suggestion paths in the
// core never learn which model answered; the core picks the provider
// (preferred, then the fallback order) and this class runs the request on
// its `LanguageModelSession`.
//
// Context windows differ per model (4K tokens on device, 32K in Apple's
// cloud). A summary whose prompt does not fit the provider's budget is
// split on its blank lines, each part answered under the same instruction,
// and the parts' answers answered once more — a thread that does not fit
// degrades to a summary of summaries, never to an error. Only a summary:
// an edit, a reply or a translation split that way lost its instruction
// after the first part and then had its own answers "answered" again, so
// those go whole (the core keeps them short enough) or fail with a
// sentence. Every answer's token usage lands in `AiUsageLedger`, which
// Settings › AI shows per provider.

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

    func complete(system: String, user: String, style: CompletionStyle) async throws -> String {
        switch style {
        case .digest:
            return try await answer(system: system, prompt: user, depth: 0)
        case .writing, .exact:
            guard user.count <= provider.promptBudget else {
                throw EngineError.Ai(message: "This text is too long for the model (\(provider.label)). "
                    + "Select a shorter part, or pick another provider in Settings › AI.")
            }
            return try await respond(system: system, prompt: user, options: Self.options(for: style), transforms: true)
        }
    }

    /// How an answer is decoded. A translation or a proofread is the text
    /// back, so the likeliest word every time: sampling is where a stray
    /// sentence in the wrong language came from. Writing keeps some
    /// variety but less than the default; a summary keeps the default.
    static func options(for style: CompletionStyle) -> GenerationOptions {
        var options = GenerationOptions()
        switch style {
        case .digest: break
        case .writing: options.temperature = 0.6
        case .exact: options.samplingMode = .greedy
        }
        return options
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
        } catch {
            throw Self.engineError(error)
        }
        return TriageVerdict(priority: verdict.priority.ffi, labelIds: TriagePrompt.labelIds(for: verdict.labels, in: labels))
    }

    func suggest(subject: String, from: String, body: String, receivedAt: Int64) async throws -> ThreadSuggestion? {
        let session = provider.session(instructions: SuggestionPrompt.instructions, task: .classification)
        // Leave room for the header lines and the answer; the core already
        // cut the body to a few thousand characters.
        let room = max(provider.promptBudget - 400, 500)
        let prompt = SuggestionPrompt.prompt(subject: subject, from: from, body: String(body.prefix(room)),
                                             received: Date(timeIntervalSince1970: Double(receivedAt) / 1000))
        let call: SuggestionCall
        do {
            let response = try await session.respond(to: prompt, generating: SuggestionCall.self)
            ledger.record(provider: provider.id, response.usage)
            call = response.content
        } catch {
            throw Self.engineError(error)
        }
        switch SuggestionPrompt.suggestion(action: call.action.rawValue, remindOn: call.remindOn, hour: call.hour) {
        case .needsReply: return .needsReply
        case .remind(let at): return .remind(at: Int64((at.timeIntervalSince1970 * 1000).rounded()))
        case nil: return nil
        }
    }

    func bundle(subject: String, from: String, snippet: String, bundles: [BundleCandidate]) async throws -> BundleChoice {
        let session = provider.session(instructions: BundlePrompt.instructions, task: .classification)
        let shown = bundles.map { b in
            (name: b.name, category: BundleCategory(b.kind), description: b.description, examples: b.examples,
             notExamples: b.notExamples)
        }
        let prompt = BundlePrompt.prompt(subject: subject, from: from, snippet: snippet, bundles: shown)
        let call: BundleCall
        do {
            let response = try await session.respond(to: String(prompt.prefix(provider.promptBudget)), generating: BundleCall.self)
            ledger.record(provider: provider.id, response.usage)
            call = response.content
        } catch {
            throw Self.engineError(error)
        }
        let decision = BundlePrompt.decision(
            action: call.action.rawValue, bundle: call.bundle, name: call.name, kind: call.kind.rawValue,
            confidence: call.confidence.rawValue,
            candidates: bundles.map { (id: $0.id, name: $0.name, category: BundleCategory($0.kind)) }
        )
        switch decision {
        case .join(let id): return .existing(bundleId: id)
        case .new(let name, let category): return .new(name: name, kind: category.ffi)
        case .noBundle: return .noBundle
        }
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

    private func respond(system: String, prompt: String, options: GenerationOptions = GenerationOptions(),
                         transforms: Bool = false) async throws -> String {
        // An edit or a translation hands the user's own text back changed:
        // the on-device model then runs under the guardrails Apple makes
        // for transforming text, which do not refuse a passage for what
        // it says (a registrar's notice was "unsafe content").
        let session = provider.session(instructions: system, task: transforms ? .transformation : .completion)
        do {
            let response = try await session.respond(to: prompt, options: options)
            ledger.record(provider: provider.id, response.usage)
            return response.content
        } catch {
            throw Self.engineError(error)
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

    /// Any failure of a session as the error the core expects. A request
    /// built against the iOS 27 SDK throws `LanguageModelError`, not the
    /// `GenerationError` this file used to catch alone: everything else
    /// crossed the bridge as "UnexpectedUniFFICallbackError(…)", raw, into
    /// the translation panel.
    static func engineError(_ error: any Error) -> EngineError {
        if let error = error as? EngineError { return error }
        if let error = error as? LanguageModelError { return .Ai(message: describe(error)) }
        if let error = error as? LanguageModelSession.GenerationError { return .Ai(message: describe(error)) }
        return .Ai(message: error.localizedDescription)
    }

    /// What the user reads when the model declines a text.
    static let declined = "The model declined this text as possibly unsafe. Try a shorter selection, or pick another provider in Settings › AI."

    static func describe(_ error: LanguageModelError) -> String {
        switch error {
        case .contextSizeExceeded: "The text is too long for this model."
        case .guardrailViolation, .refusal: declined
        case .unsupportedLanguageOrLocale: "The model doesn't support this language."
        case .rateLimited: "The model is busy. Try again in a moment."
        case .timeout: "The model took too long. Try again."
        default: error.localizedDescription
        }
    }

    static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize: "The text is too long for this model."
        case .guardrailViolation: declined
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

/// The structured new-mail suggestion (SuggestionPrompt says what each
/// field means; the instruction carries the rules, the guides the shape).
@Generable
struct SuggestionCall {
    @Guide(description: "reply, remind or nothing.")
    var action: SuggestedAction
    @Guide(description: "For remind: the day to bring the email back, YYYY-MM-DD. Empty otherwise.")
    var remindOn: String
    @Guide(description: "For remind: the hour of that day, 0 to 23. 8 otherwise.", .range(0...23))
    var hour: Int
}

@Generable
enum SuggestedAction: String {
    case reply, remind, nothing
}

/// The structured bundling answer (BundlePrompt says what each field means).
@Generable
struct BundleCall {
    @Guide(description: "join, new or nothing.")
    var action: BundleAction
    @Guide(description: "For join: the name of the listed bundle, exactly as listed. Empty otherwise.")
    var bundle: String
    @Guide(description: "For new: a short name for the bundle, like \"Lisbon trip\" or \"Zalando order\". Empty otherwise.")
    var name: String
    @Guide(description: "What the email itself is about: trip, shopping or project; other when none.")
    var kind: BundleKindAnswer
    @Guide(description: "high only when the email names the destination, the store or order, or the project; else medium or low.")
    var confidence: BundleConfidence
}

@Generable
enum BundleConfidence: String {
    case high, medium, low
}

@Generable
enum BundleAction: String {
    case join, new, nothing
}

@Generable
enum BundleKindAnswer: String {
    case trip, shopping, project, other
}

extension BundleCategory {
    /// The core's kind for this category (and back).
    var ffi: BundleKind {
        switch self {
        case .trip: .trip
        case .shopping: .shopping
        case .project: .project
        case .other: .other
        }
    }

    init(_ kind: BundleKind) {
        switch kind {
        case .trip: self = .trip
        case .shopping: self = .shopping
        case .project: self = .project
        case .other: self = .other
        }
    }
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
