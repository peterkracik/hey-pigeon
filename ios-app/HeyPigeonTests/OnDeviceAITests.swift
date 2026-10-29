// The on-device provider's pure parts (no model needed): the prompt
// splitter the context-window handling rests on, the triage priority
// mapping, and the mock engine's provider resolution the Settings rows use.

import HeyPigeonCore
import Testing
@testable import HeyPigeon

struct OnDeviceAITests {
    @Test func chunksPackParagraphsUpToTheBudget() {
        let text = ["aaaa", "bbbb", "cccc", "dddd"].joined(separator: "\n\n")
        // 4 + 2 + 4 = 10 fits; a third paragraph would not.
        #expect(AppleIntelligenceProvider.chunks(text, budget: 10) == ["aaaa\n\nbbbb", "cccc\n\ndddd"])
        #expect(AppleIntelligenceProvider.chunks(text, budget: 100) == [text])
        #expect(AppleIntelligenceProvider.chunks("", budget: 10).isEmpty)
    }

    @Test func chunksCutAParagraphLongerThanTheBudget() {
        let long = String(repeating: "x", count: 25)
        let chunks = AppleIntelligenceProvider.chunks(long + "\n\nshort", budget: 10)
        #expect(chunks.count == 2)
        #expect(chunks[0].count == 10)
        #expect(chunks[1] == "short")
    }

    @Test func triagePriorityMapsOntoTheEngineEnum() {
        #expect(TriagePriority.spam.ffi == .spam)
        #expect(TriagePriority.high.ffi == .high)
    }

    @MainActor
    @Test func mockResolvesTheProviderLikeTheEngine() async throws {
        let engine = MockEngine()
        // No model, no key: nothing answers.
        var s = try engine.aiStatus()
        #expect(!s.configured && s.preferredProviderId == "openai")
        // The on-device model alone answers, and is the default preference.
        engine.onDeviceAI = true
        s = try engine.aiStatus()
        #expect(s.configured && s.answersOnDevice && s.preferredProviderId == "apple")
        // Preferring the key without one still answers on device.
        try engine.setAIProvider(.openai)
        s = try engine.aiStatus()
        #expect(s.preferredProviderId == "openai" && s.answersOnDevice)
        // With a key, the preference wins.
        try await engine.setAIKey("sk-test")
        s = try engine.aiStatus()
        #expect(s.providerId == "openai" && s.openaiConfigured)
        // Triage: on device is enough, Jev stays selectable.
        var t = try engine.triageStatus()
        #expect(t.configured && t.classifierId == "apple" && !t.jevConfigured)
        try engine.setTriageClassifier(.jev)
        t = try engine.triageStatus()
        #expect(t.classifierId == "jev" && t.configured)
    }

    /// Apple's cloud is the third provider: preferred when it is the only
    /// Apple model, second to the device by default, and the fallback order
    /// decides when the preferred one cannot answer.
    @MainActor
    @Test func mockResolvesAppleCloudAndTheFallbackOrder() async throws {
        let engine = MockEngine()
        engine.cloudAI = true
        var s = try engine.aiStatus()
        #expect(s.configured && s.answersInAppleCloud && s.preferredProviderId == "apple-cloud")
        #expect(s.availableProviderIds == ["apple-cloud"])
        #expect(s.fallbackOrder == ["apple", "apple-cloud", "openai"])
        engine.onDeviceAI = true
        s = try engine.aiStatus()
        #expect(s.preferredProviderId == "apple" && s.answersOnDevice)
        #expect(s.isAvailable(.appleCloud) && s.isAvailable(.apple) && !s.isAvailable(.openai))
        // Prefer the cloud; lose it; the order falls back to the device.
        try engine.setAIProvider(.appleCloud)
        #expect(try engine.aiStatus().answersInAppleCloud)
        engine.cloudAI = false
        #expect(try engine.aiStatus().answersOnDevice)
        // "Stay on this iPhone": OpenAI is never the fallback.
        try engine.setAIFallback(AIFallbackPreset.onDeviceOnly.order)
        try await engine.setAIKey("sk-test")
        engine.onDeviceAI = false
        s = try engine.aiStatus()
        #expect(s.fallbackOrder == ["apple"])
        #expect(!s.configured)
        // Classifiers follow: the cloud is a classifier too.
        engine.cloudAI = true
        let t = try engine.triageStatus()
        #expect(t.isAvailable(.appleCloud) && !t.isAvailable(.apple) && t.classifierId == "apple-cloud")
    }

    @Test func fallbackPresetsRoundTripThroughTheSyncedOrder() {
        #expect(AIFallbackPreset(order: []) == .privateFirst)
        #expect(AIFallbackPreset(order: ["apple", "apple-cloud", "openai"]) == .privateFirst)
        #expect(AIFallbackPreset(order: ["apple-cloud", "apple", "openai"]) == .cloudFirst)
        #expect(AIFallbackPreset(order: ["apple"]) == .onDeviceOnly)
        #expect(AIFallbackPreset(order: ["openai"]) == .privateFirst) // unknown shape → default
        #expect(AIProvider(rawValue: "anthropic") == .other("anthropic"))
        #expect(AIProvider.appleCloud.rawValue == "apple-cloud")
    }

    @Test func triagePromptMapsNamesToKnownIdsOnce() {
        let labels = [TriageLabel(id: "a", name: "Invoices"), TriageLabel(id: "b", name: "Travel")]
        #expect(TriagePrompt.labelIds(for: ["invoices", "Travel", "Invoices", "Nope"], in: labels) == ["a", "b"])
        #expect(TriagePrompt.prompt(from: "x@y", subject: "S", snippet: "P", labels: []).contains("Available labels: (none)"))
        #expect(TriagePromptVariant.candidates.map(\.id) == ["shipped", "explicit", "terse"])
        #expect(TriagePrompt.instructions == TriagePromptVariant.shipped.instructions)
    }

    @Test func usageLedgerCountsPerProviderAndFormats() {
        let defaults = UserDefaults(suiteName: "test.ai.usage.\(UUID().uuidString)")!
        let ledger = AiUsageLedger(defaults: defaults)
        ledger.record(provider: "apple", input: 1_200, output: 300)
        ledger.record(provider: "apple", input: 12_000, output: 10)
        ledger.record(provider: "apple-cloud", input: 5, output: 5)
        let apple = ledger.byProvider["apple"]!
        #expect(apple.requests == 2 && apple.inputTokens == 13_200 && apple.outputTokens == 310)
        #expect(AiUsageLedger.line(apple, price: nil) == "2 requests · 13K in / 310 out")
        #expect(AiUsageLedger.line(ledger.byProvider["apple-cloud"]!, price: nil) == "1 request · 5 in / 5 out")
        #expect(AiUsageLedger.line(apple, price: TokenPrice(inputPerMillion: 1_000, outputPerMillion: 1_000)) == "2 requests · 13K in / 310 out · $13.51")
        // Persisted: a second ledger over the same defaults sees it.
        #expect(AiUsageLedger(defaults: defaults).byProvider["apple"] == apple)
        ledger.reset()
        #expect(ledger.byProvider.isEmpty)
    }
}
