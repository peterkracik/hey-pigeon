// The composer's assistant (Features/Compose/AIAssist.swift): the one
// preset vocabulary, when a request may run, what the footer says a
// request sends, and the runner — a result waits for review, a request
// can be cancelled, and one that never answers is given up on.

import Foundation
import Testing
@testable import HeyPigeon

struct AIAssistTests {
    @Test func oneVocabularyOfPresets() {
        #expect(AIAssist.edits.map(\.title)
            == ["Improve writing", "Fix spelling and grammar", "Shorten", "Lengthen", "Simplify", "More formal", "More casual"])
        #expect(AIAssist.tones.map(\.title)
            == ["Warmer", "More formal", "More casual", "More confident", "Softer", "More concise"])
        // A page that lists both shows each name once.
        #expect(AIAssist.tonesBeyondEdits.map(\.title) == ["Warmer", "More confident", "Softer", "More concise"])
        #expect(AIAssist.replies.first?.notes == nil)
    }

    @Test func whenARequestMayRun() {
        #expect(AIAssist.startMode(text: "  \n") == .write)
        #expect(AIAssist.startMode(text: "Hello") == .edit)
        #expect(!AIAssist.canRun(mode: .edit, typed: " ", hasText: true, isReply: false))
        #expect(!AIAssist.canRun(mode: .edit, typed: "Shorter", hasText: false, isReply: false))
        #expect(AIAssist.canRun(mode: .edit, typed: "Shorter", hasText: true, isReply: false))
        // A reply can be drafted from the conversation alone; a new message needs a brief.
        #expect(AIAssist.canRun(mode: .write, typed: "", hasText: false, isReply: true))
        #expect(!AIAssist.canRun(mode: .write, typed: "", hasText: false, isReply: false))
    }

    @Test func reviewWordsFollowTheOutcome() {
        let written = AIAssist.Outcome(text: "Hi", written: true, hasSelection: false)
        let selection = AIAssist.Outcome(text: "Hi", written: false, hasSelection: true)
        let whole = AIAssist.Outcome(text: "Hi", written: false, hasSelection: false)
        #expect(AIAssist.applyTitle(written) == "Use it")
        #expect(AIAssist.applyTitle(selection) == "Replace selection")
        #expect(AIAssist.applyTitle(whole) == "Replace message")
        #expect(AIAssist.reviewTitle(selection).contains("selected text"))
        #expect(AIAssist.reviewTitle(written).contains("the message"))
    }

    /// Privacy copy: the pieces are what the engine's calls are handed.
    @Test func theFooterSaysWhatIsSentAndWhere() {
        let edit = AIAssist.footnote(mode: .edit, isReply: false, sendsWriter: false, destination: .provider)
        #expect(edit == "On a \(AIAssist.gesture), the text being edited and your instruction are sent to your AI provider.")
        let reply = AIAssist.footnote(mode: .edit, isReply: true, sendsWriter: true, destination: .provider)
        #expect(reply.contains("the conversation you are replying to") && reply.contains("who is writing to whom"))
        let draft = AIAssist.footnote(mode: .write, isReply: true, sendsWriter: false, destination: .appleCloud)
        #expect(draft.contains("the conversation you are replying to, its subject and your notes"))
        #expect(draft.contains("Private Cloud Compute"))
        let local = AIAssist.footnote(mode: .write, isReply: false, sendsWriter: false, destination: .device)
        #expect(local.contains("your brief and the subject") && local.contains("Nothing leaves the device"))
        #expect(AIAssist.Destination(nil) == .provider)
        // A tone on a result under review sends that result, not the brief.
        let tone = AIAssist.footnote(mode: .write, isReply: true, sendsWriter: false, destination: .provider, refining: true)
        #expect(tone == "On a \(AIAssist.gesture), the draft shown above, the tone you \(AIAssist.gesture) and the conversation you are replying to are sent to your AI provider.")
    }
}

@MainActor
struct AIAssistRunnerTests {
    @Test func aResultWaitsForReview() async throws {
        let runner = AIAssistRunner()
        runner.run { "Shorter." } done: { AIAssist.Outcome(text: $0, written: false, hasSelection: true) }
        #expect(runner.running)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!runner.running && runner.error == nil)
        #expect(runner.result == AIAssist.Outcome(text: "Shorter.", written: false, hasSelection: true))
        runner.discard()
        #expect(runner.result == nil)
    }

    @Test func aRequestCanBeCancelled() async throws {
        let runner = AIAssistRunner()
        runner.run {
            try await Task.sleep(for: .seconds(30))
            return "late"
        } done: { AIAssist.Outcome(text: $0, written: true, hasSelection: false) }
        runner.cancel()
        #expect(!runner.running)
        try await Task.sleep(for: .milliseconds(200))
        #expect(runner.result == nil && runner.error == nil)
    }

    @Test func aRequestThatNeverAnswersIsGivenUpOn() async throws {
        let runner = AIAssistRunner(timeout: .milliseconds(50))
        runner.run {
            try await Task.sleep(for: .seconds(30))
            return "late"
        } done: { AIAssist.Outcome(text: $0, written: true, hasSelection: false) }
        try await Task.sleep(for: .milliseconds(600))
        #expect(!runner.running && runner.result == nil)
        #expect(runner.error?.contains("too long") == true)
    }

    @Test func anEmptyTextIsNotSent() {
        let runner = AIAssistRunner()
        runner.edit("Shorten", text: "  ", hasSelection: false, history: nil, context: nil,
                    shown: nil, in: AppModel(engine: MockEngine()))
        #expect(!runner.running && runner.error?.contains("Nothing to edit") == true)
    }

    /// Wait for the request that is out, for five seconds at most.
    private func settle(_ runner: AIAssistRunner) async throws {
        for _ in 0..<100 where runner.running {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func aRequestGoesToTheProviderTheFooterShowed() async throws {
        let engine = MockEngine()
        engine.onDeviceAI = true
        let model = AppModel(engine: engine)
        let shown = try engine.aiStatus()
        #expect(AIAssist.Destination(shown) == .device)
        #expect(AIAssist.expectedProvider(shown) == "apple")
        let runner = AIAssistRunner()
        runner.edit("Shorten", text: "A long text.", hasSelection: false, history: nil, context: nil,
                    shown: shown, in: model)
        try await settle(runner)
        #expect(runner.error == nil && runner.result?.written == false)
    }

    /// The provider changes between the footer and the tap (a sync drops
    /// the device model, the fallback reaches Apple's cloud): the request
    /// is not sent under "Nothing leaves the device", nor retried.
    @Test func aRequestIsNotSentWhenTheProviderChangedSinceTheFooter() async throws {
        let engine = MockEngine()
        engine.onDeviceAI = true
        engine.cloudAI = true
        let model = AppModel(engine: engine)
        let shown = try engine.aiStatus()
        #expect(AIAssist.Destination(shown) == .device)
        engine.onDeviceAI = false
        #expect(try engine.aiStatus().answersInAppleCloud)

        let runner = AIAssistRunner()
        let said = AIProviderChanged().errorDescription
        runner.edit("Shorten", text: "A long text.", hasSelection: false, history: nil, context: nil,
                    shown: shown, in: model)
        try await settle(runner)
        #expect(!runner.running && runner.result == nil && runner.error == said)
        #expect(runner.error?.contains("not sent") == true)

        runner.write(notes: "", subject: "Deck", history: "Priya: slides?", context: nil, shown: shown, in: model)
        try await settle(runner)
        #expect(runner.result == nil && runner.error == said)
        runner.write(notes: "Ask for the deck", subject: "Deck", history: nil, context: nil, shown: shown, in: model)
        try await settle(runner)
        #expect(runner.result == nil && runner.error == said)

        // The next tap is made under the redrawn footer and goes through;
        // a tone on its result is refused when the provider moves again.
        let redrawn = try engine.aiStatus()
        #expect(AIAssist.Destination(redrawn) == .appleCloud)
        runner.edit("Shorten", text: "A long text.", hasSelection: false, history: nil, context: nil,
                    shown: redrawn, in: model)
        try await settle(runner)
        let result = try #require(runner.result)
        #expect(runner.error == nil)
        engine.onDeviceAI = true
        runner.refine(result, with: "Warmer", history: nil, context: nil, shown: redrawn, in: model)
        try await settle(runner)
        #expect(runner.result == result && runner.error == said)
    }

    /// A footer drawn with no provider expects none: a provider that
    /// turned up since does not get the request.
    @Test func aFooterWithoutAProviderMatchesNone() async throws {
        let engine = MockEngine()
        let model = AppModel(engine: engine)
        let shown = try engine.aiStatus()
        #expect(shown.providerId == nil && AIAssist.expectedProvider(shown) == "")
        #expect(AIAssist.expectedProvider(nil) == "")
        engine.cloudAI = true
        let runner = AIAssistRunner()
        runner.edit("Shorten", text: "A long text.", hasSelection: false, history: nil, context: nil,
                    shown: shown, in: model)
        try await settle(runner)
        #expect(runner.result == nil && runner.error == AIProviderChanged().errorDescription)
    }

    /// The engine's rule, on the mock: an expected provider that no longer
    /// answers is refused; a call that names none goes to whoever answers.
    @Test func theEngineRefusesAnotherProviderThanTheExpectedOne() async throws {
        let engine = MockEngine()
        engine.cloudAI = true
        await #expect(throws: AIProviderChanged.self) {
            _ = try await engine.aiEditText(instruction: "Shorten", text: "Hello", history: nil, context: nil,
                                            expectedProvider: "apple")
        }
        await #expect(throws: AIProviderChanged.self) {
            _ = try await engine.aiDraftReply(subject: "Deck", history: "Priya: slides?", notes: nil, context: nil,
                                              expectedProvider: "apple")
        }
        let matched = try await engine.aiEditText(instruction: "Shorten", text: "Hello", history: nil, context: nil,
                                                  expectedProvider: "apple-cloud")
        let unchecked = try await engine.aiEditText(instruction: "Shorten", text: "Hello", history: nil)
        #expect(matched == unchecked)
        _ = try await engine.aiDraftReply(subject: "Deck", history: "Priya: slides?", notes: nil)
    }
}
