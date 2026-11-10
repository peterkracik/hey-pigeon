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
                    in: AppModel(engine: MockEngine()))
        #expect(!runner.running && runner.error?.contains("Nothing to edit") == true)
    }
}
