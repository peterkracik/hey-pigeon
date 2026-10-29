// The models the Foundation Models backend can run on (docs/ios-intelligence.md,
// "iOS 27 › One model layer"): Apple's on-device model, Apple's Private
// Cloud Compute model, and any third-party or local model that speaks the
// iOS 27 `LanguageModel` protocol (Anthropic's and Google's Swift packages
// once published, an MLX model for experiments). Every provider has the
// id the Rust core knows it by (`pref:ai.provider`), a Settings label, a
// prompt budget and an availability check; `FoundationModelsBackend` does
// the rest. Rust keeps its own OpenAI client for the desktop app.

import Foundation
import FoundationModels
import Synchronization

/// What a request is for. The cloud model picks its reasoning level from
/// it (light for drafts and summaries, deep for triage).
enum AiTask: Sendable {
    case completion
    case classification
}

/// Whether a provider can answer on this device now, and if not, why
/// (shown under its Settings row).
enum ProviderAvailability: Equatable, Sendable {
    case available
    case unavailable(String)

    var isAvailable: Bool { self == .available }
    var reason: String? {
        if case .unavailable(let r) = self { return r }
        return nil
    }
}

/// One `LanguageModel` the backend can address.
protocol ModelProvider: Sendable {
    /// Provider id the Rust core uses ("apple", "apple-cloud", "anthropic", …).
    var id: String { get }
    /// Settings row title.
    var label: String { get }
    /// What `ai_models` reports for the provider.
    var modelId: String { get }
    var modelLabel: String { get }
    /// Rough budget for one prompt in characters (~4 per token): the
    /// context window less room for the instruction and the answer.
    var promptBudget: Int { get }
    /// True when a request leaves the device (Settings says so).
    var leavesDevice: Bool { get }
    /// Whether this device can run the model right now.
    var availability: ProviderAvailability { get }
    /// A session on the model, with the instruction and tools.
    func session(instructions: String, task: AiTask, tools: [any Tool]) -> LanguageModelSession
}

extension ModelProvider {
    func session(instructions: String, task: AiTask = .completion) -> LanguageModelSession {
        session(instructions: instructions, task: task, tools: [])
    }
}

// MARK: - Apple, on device

/// Apple Intelligence on the device: AI with no key, no account and no
/// network. The window is short (4,096 tokens on iOS 26, same class on
/// iOS 27), so the backend chunks what does not fit.
struct SystemModelProvider: ModelProvider {
    let id = "apple"
    let label = "On this \(Device.name)"
    let modelId = "apple-on-device"
    let modelLabel = "On this \(Device.name)"
    let promptBudget = 9_000
    let leavesDevice = false

    var availability: ProviderAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .unavailable("This device can't run Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled): return .unavailable("Turn on Apple Intelligence in Settings.")
        case .unavailable(.modelNotReady): return .unavailable("The model is still downloading.")
        case .unavailable: return .unavailable("Apple Intelligence isn't available right now.")
        }
    }

    func session(instructions: String, task: AiTask, tools: [any Tool]) -> LanguageModelSession {
        LanguageModelSession(model: SystemLanguageModel.default, tools: tools, instructions: instructions)
    }
}

// MARK: - Apple, Private Cloud Compute

/// Apple's Private Cloud Compute model (iOS 27): a 32K-token context,
/// reasoning levels, no API key, prompts never stored, still Apple-private.
/// Needs the Private Cloud Compute entitlement on the App ID (project.yml
/// has the commented entry and the steps); without it `availability` says
/// so and the engine falls back to the on-device model.
struct PrivateCloudComputeProvider: ModelProvider {
    let id = "apple-cloud"
    let label = "Apple's cloud"
    let modelId = "apple-private-cloud-compute"
    let modelLabel = "Private Cloud Compute"
    /// 32K tokens; ~100K characters leaves room for instructions and a
    /// long answer, so almost every thread is summarized in one pass.
    let promptBudget = 100_000
    let leavesDevice = true

    private var model: PrivateCloudComputeLanguageModel { PrivateCloudComputeLanguageModel() }

    var availability: ProviderAvailability {
        switch model.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .unavailable("This device can't use Private Cloud Compute.")
        case .unavailable(.systemNotReady): return .unavailable("Private Cloud Compute isn't ready yet.")
        case .unavailable: return .unavailable("Private Cloud Compute isn't reachable right now (offline, or this build lacks the entitlement).")
        }
    }

    /// The model's default reasoning level. The SDK sets the level per
    /// request (`respond(to:…, contextOptions:)`), not per session; picking
    /// light for drafts and deep for triage is a follow-up
    /// (docs/ios-intelligence.md, "Verify on the first build").
    func session(instructions: String, task: AiTask, tools: [any Tool]) -> LanguageModelSession {
        LanguageModelSession(model: model, tools: tools, instructions: instructions)
    }
}

// MARK: - Third-party and local models

/// A provider built on a `LanguageModel` from a Swift package — Anthropic's
/// or Google's once published, or a local MLX / Core AI model for an
/// experiment with a small fine-tuned classifier. The package's model is
/// made per session from `make`; the sign-in token it needs comes from
/// the Keychain (`ProviderTokenStore`), never from a string in the binary.
struct PackageModelProvider: ModelProvider {
    let id: String
    let label: String
    let modelId: String
    let modelLabel: String
    let promptBudget: Int
    let leavesDevice: Bool
    /// The Keychain account the provider's token sits under; nil for a
    /// local model that needs none.
    let tokenAccount: String?
    let make: @Sendable (_ token: String?) -> any LanguageModel

    var availability: ProviderAvailability {
        guard let tokenAccount else { return .available }
        return ProviderTokenStore.token(for: tokenAccount) == nil
            ? .unavailable("Sign in to \(label) in Settings › AI.")
            : .available
    }

    func session(instructions: String, task: AiTask, tools: [any Tool]) -> LanguageModelSession {
        let token = tokenAccount.flatMap(ProviderTokenStore.token(for:))
        return LanguageModelSession(model: make(token), tools: tools, instructions: instructions)
    }
}

// MARK: - Registry

/// Every model the app can offer, in fallback order. The two Apple models
/// are always listed; packages register theirs at launch
/// (`ModelProviderRegistry.register`) — when the Anthropic or Google
/// package lands, one `PackageModelProvider` line here is the whole
/// integration, and the Rust core accepts the new id through
/// `add_ai_backend`.
enum ModelProviderRegistry {
    /// Registered packages. Read from the main actor and from the engine's
    /// threads (the backends), so behind a lock rather than a bare global.
    private static let extra = Mutex<[any ModelProvider]>([])

    static var all: [any ModelProvider] {
        [SystemModelProvider(), PrivateCloudComputeProvider()] + extra.withLock { $0 }
    }

    static func register(_ provider: any ModelProvider) {
        extra.withLock { list in
            list.removeAll { $0.id == provider.id }
            list.append(provider)
        }
    }

    static func provider(id: String) -> (any ModelProvider)? {
        all.first { $0.id == id }
    }

    /// The providers this device can run right now.
    static var available: [any ModelProvider] {
        all.filter { $0.availability.isAvailable }
    }

    /// The ids the Rust core may name that the shell can serve.
    static var ids: [String] { all.map(\.id) }
}

/// The on-device provider's name in the rest of the app (Settings copy,
/// the classifier, the attachment and inbox tools): the registry's first
/// entry. Kept as a type so call sites read as before.
enum AppleIntelligenceProvider {
    static let providerId = SystemModelProvider().id
    static let modelId = SystemModelProvider().modelId

    /// Whether this device can run the on-device model right now.
    static var isAvailable: Bool { SystemModelProvider().availability.isAvailable }

    /// Why not, for Settings copy ("Apple Intelligence is off", …).
    static var unavailableReason: String? { SystemModelProvider().availability.reason }

    /// Split on blank lines, packing paragraphs up to the budget — the
    /// backend's context-window handling, exposed for the tests.
    static func chunks(_ text: String, budget: Int) -> [String] {
        FoundationModelsBackend.chunks(text, budget: budget)
    }
}
