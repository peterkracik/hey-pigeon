// The on-device provider's pure parts (no model needed): the prompt
// splitter the context-window handling rests on, the triage priority
// mapping, and the mock engine's provider resolution the Settings rows use.

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
}
