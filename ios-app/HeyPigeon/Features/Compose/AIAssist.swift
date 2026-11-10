// The composer's writing assistant, the part both platforms share: the
// modes, the presets and tones in one vocabulary, the requests the engine
// is asked, the runner that makes every request cancellable and gives up
// after a while, and the sentence that says what a request sends. The
// phone's sheet (AIEditSheet) and the Mac's panel (ComposeMac.swift
// MacAIPanel) are the two views over it. They used to be two
// implementations: the presets had drifted ("Fix grammar" on one, "Fix
// spelling and grammar" on the other), and only the Mac could cancel a
// request, timed one out, or showed the result before it replaced what
// was written.

import Foundation
import Observation

enum AIAssist {
    /// Write the message (from a brief, or as an answer to the thread) or
    /// edit what is there.
    enum Mode: String, CaseIterable, Identifiable {
        case write = "Write", edit = "Edit"
        var id: String { rawValue }
    }

    /// A one-tap instruction: what the chip or row says, and what the
    /// engine is told.
    struct Preset: Identifiable, Hashable {
        let title: String
        let instruction: String
        var id: String { title }
    }

    /// A one-tap reply: its notes steer the draft; nil takes what is typed.
    struct ReplyPreset: Identifiable, Hashable {
        let title: String
        let notes: String?
        var id: String { title }
    }

    /// A finished request, waiting to be looked at: nothing replaces what
    /// the user wrote until they say so.
    struct Outcome: Equatable {
        let text: String
        /// A whole message written (it replaces the body), not an edit.
        let written: Bool
        /// An edit of the selection, not of the whole message.
        let hasSelection: Bool
    }

    /// The edit presets; the first is the one Superhuman leads with.
    static let edits: [Preset] = [
        Preset(title: "Improve writing", instruction: "Improve the writing: clearer, smoother and better structured, keeping the meaning, the tone and roughly the length."),
        Preset(title: "Fix spelling and grammar", instruction: "Fix spelling, grammar and punctuation mistakes. Change nothing else."),
        Preset(title: "Shorten", instruction: "Make this more concise without losing the key points."),
        Preset(title: "Lengthen", instruction: "Expand this with a bit more detail and context, keeping the tone."),
        Preset(title: "Simplify", instruction: "Simplify the wording: shorter sentences and plain words, same meaning."),
        Preset(title: "More formal", instruction: "Rewrite this in a more formal, professional tone."),
        Preset(title: "More casual", instruction: "Rewrite this in a more casual, friendly tone."),
    ]

    /// Tone, to dial a result in (they chain: Warmer, then More concise).
    static let tones: [Preset] = [
        Preset(title: "Warmer", instruction: "Make the tone warmer and friendlier, without changing the meaning."),
        Preset(title: "More formal", instruction: "Make the tone more formal and professional, without changing the meaning."),
        Preset(title: "More casual", instruction: "Make the tone more casual and relaxed, without changing the meaning."),
        Preset(title: "More confident", instruction: "Make the tone more confident and direct, without changing the meaning."),
        Preset(title: "Softer", instruction: "Soften the tone — more polite and less blunt — without changing the meaning."),
        Preset(title: "More concise", instruction: "Make it more concise without losing the key points."),
    ]

    /// The tones the edit presets do not already offer by name, for a
    /// surface that lists both (the phone's Edit page).
    static var tonesBeyondEdits: [Preset] {
        let taken = Set(edits.map(\.title))
        return tones.filter { !taken.contains($0.title) }
    }

    /// Quick notes for a drafted reply.
    static let replies: [ReplyPreset] = [
        ReplyPreset(title: "Draft the reply", notes: nil),
        ReplyPreset(title: "Say yes", notes: "Agree and confirm."),
        ReplyPreset(title: "Decline politely", notes: "Decline politely, with a brief reason in a placeholder."),
        ReplyPreset(title: "Ask for details", notes: "Ask for the details needed before answering."),
    ]

    /// How long a request may take before it is given up on: the adapters
    /// time out around then too, and a spinner nobody can stop is what
    /// froze the first sheet.
    static let timeout: Duration = .seconds(90)

    static func isBlank(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Where the assistant opens: on Write while there is nothing to edit.
    static func startMode(text: String) -> Mode {
        isBlank(text) ? .write : .edit
    }

    /// Whether the typed line can be sent: an edit needs an instruction
    /// and something to edit; a new message needs a brief; a reply can be
    /// drafted from the conversation alone.
    static func canRun(mode: Mode, typed: String, hasText: Bool, isReply: Bool) -> Bool {
        switch mode {
        case .edit: !isBlank(typed) && hasText
        case .write: !isBlank(typed) || isReply
        }
    }

    /// What applying an outcome is called.
    static func applyTitle(_ outcome: Outcome) -> String {
        outcome.written ? "Use it" : outcome.hasSelection ? "Replace selection" : "Replace message"
    }

    /// The line over an outcome under review.
    static func reviewTitle(_ outcome: Outcome) -> String {
        !outcome.written && outcome.hasSelection
            ? "Review before it replaces the selected text"
            : "Review before it replaces the message"
    }

    /// Opening words of the compose instruction (MockEngine keys on them).
    static let writePrefix = "Write a complete email from the brief below"

    /// The edit endpoint doubles as the writer for a new message: the brief
    /// is the "text", and the instruction asks for a whole email built from
    /// it, with the same guardrails as the desktop's draft-reply prompt.
    static func writeInstruction(subject: String) -> String {
        var s = writePrefix + ", in the first person as the sender. "
        let subj = subject.trimmingCharacters(in: .whitespaces)
        if !subj.isEmpty { s += "The subject line is \"\(subj)\". " }
        s += "Be concise and natural. Never invent facts, dates, or commitments the brief does not support — put a short placeholder in square brackets where the sender must fill something in. Return ONLY the email body as plain text: no subject line, no markdown, and no signature block (the sender's signature is added separately)."
        return s
    }

    // MARK: What a request sends

    /// Who answers a request (Settings › AI): the model on this device,
    /// Apple's cloud, or a provider reached with the user's key.
    enum Destination: Equatable {
        case device, appleCloud, provider

        init(_ status: AIStatus?) {
            if status?.answersOnDevice == true {
                self = .device
            } else if status?.answersInAppleCloud == true {
                self = .appleCloud
            } else {
                self = .provider
            }
        }
    }

    /// The privacy line under the assistant: what a tap sends, and to
    /// whom. It must stay literally true (ios-app/CLAUDE.md): the pieces
    /// are the arguments of the engine's `aiEditText` / `aiDraftReply`
    /// (crates/ffi/src/settings.rs `build_edit_prompt`,
    /// `build_draft_reply_prompt`). `sendsWriter` is the Mac's
    /// `AIWriteContext` — the sender's and recipients' names and
    /// addresses.
    static func footnote(mode: Mode, isReply: Bool, sendsWriter: Bool, destination: Destination) -> String {
        var parts: [String]
        switch (mode, isReply) {
        case (.edit, true): parts = ["the text being edited", "your instruction", "the conversation you are replying to"]
        case (.edit, false): parts = ["the text being edited", "your instruction"]
        case (.write, true): parts = ["the conversation you are replying to", "its subject", "your notes"]
        case (.write, false): parts = ["your brief", "the subject"]
        }
        if sendsWriter { parts.append("who is writing to whom") }
        let what = parts.count > 1
            ? parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
            : parts.first ?? ""
        switch destination {
        case .device:
            return "On a tap, Apple Intelligence on this \(Device.name) reads \(what). Nothing leaves the device."
        case .appleCloud:
            return "On a tap, \(what) go to Apple's Private Cloud Compute, which does not store them."
        case .provider:
            return "On a tap, \(what) are sent to the AI provider picked in Settings."
        }
    }
}

/// One assistant's requests: at most one at a time, each cancellable and
/// given up on after `timeout`; a result waits in `result` to be reviewed.
/// The views hold one in their state and draw from it.
@MainActor
@Observable
final class AIAssistRunner {
    /// A request is out.
    private(set) var running = false
    /// What went wrong with the last request, in words for the user.
    var error: String?
    /// The pending output; applied only when the user says so.
    var result: AIAssist.Outcome?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    private let timeout: Duration

    init(timeout: Duration = AIAssist.timeout) {
        self.timeout = timeout
    }

    /// Start `work`, dropping whatever ran before; `done` turns its text
    /// into the outcome to review. `work` is main-actor like the engine it
    /// calls: a non-isolated async closure taking the engine was a send of
    /// a non-Sendable value, which Swift 6 refuses.
    func run(_ work: @escaping @MainActor () async throws -> String,
             done: @escaping @MainActor (String) -> AIAssist.Outcome) {
        cancel()
        running = true
        error = nil
        task = Task { [weak self] in
            do {
                let out = try await work()
                guard !Task.isCancelled else { return }
                self?.result = done(out)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.error = error.localizedDescription
            }
            self?.finish()
        }
        watchdog = Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            self.task?.cancel()
            self.error = "The AI took too long. Try again, or pick another provider in Settings."
            self.finish()
        }
    }

    /// Stop the request that is out, if any; a result already here stays.
    func cancel() {
        task?.cancel()
        finish()
    }

    /// Drop the result under review (and any error beside it).
    func discard() {
        result = nil
        error = nil
    }

    private func finish() {
        running = false
        watchdog?.cancel()
        watchdog = nil
        task = nil
    }

    // MARK: The requests

    /// An instruction applied to the selection or the whole message.
    func edit(_ instruction: String, text: String, hasSelection: Bool, history: String?, context: AIWriteContext?,
              in model: AppModel) {
        guard !AIAssist.isBlank(text) else {
            error = "Nothing to edit — write something first."
            return
        }
        run {
            try await model.engine.aiEditText(instruction: instruction, text: text, history: history, context: context)
        } done: { out in
            AIAssist.Outcome(text: out, written: false, hasSelection: hasSelection)
        }
    }

    /// A tone on a result under review: applied to the result, not to the
    /// original, so tones chain.
    func refine(_ outcome: AIAssist.Outcome, with instruction: String, history: String?, context: AIWriteContext?,
                in model: AppModel) {
        run {
            try await model.engine.aiEditText(instruction: instruction, text: outcome.text, history: history, context: context)
        } done: { out in
            AIAssist.Outcome(text: out, written: outcome.written, hasSelection: outcome.hasSelection)
        }
    }

    /// A reply from the transcript (the notes steer it), or a new message
    /// from the brief through the edit endpoint.
    func write(notes: String, subject: String, history: String?, context: AIWriteContext?, in model: AppModel) {
        if let history, !AIAssist.isBlank(history) {
            run {
                try await model.engine.aiDraftReply(subject: subject, history: history,
                                                    notes: notes.isEmpty ? nil : notes, context: context)
            } done: { out in
                AIAssist.Outcome(text: out, written: true, hasSelection: false)
            }
        } else {
            guard !AIAssist.isBlank(notes) else {
                error = "Say what the email should say first."
                return
            }
            run {
                try await model.engine.aiEditText(instruction: AIAssist.writeInstruction(subject: subject),
                                                  text: notes, history: nil, context: context)
            } done: { out in
                AIAssist.Outcome(text: out, written: true, hasSelection: false)
            }
        }
    }
}
