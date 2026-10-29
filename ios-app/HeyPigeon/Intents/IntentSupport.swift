// Shared plumbing for the intents: reaching the app's model, resolving a
// thread, a short freshness sync for the question intents, and the errors
// Siri reads out. Intents run inside the app process (iOS launches it in
// the background when needed), so they call AppModel like a swipe does —
// optimistic update, outbox, undo semantics and reminder rescheduling all
// stay in one place. Nothing here touches the engine directly.

import AppIntents
import Foundation

/// The failures Siri reads out, in the app's words.
enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case noSuchThread
    case noAccount
    case aiOff
    case noDate
    case wrongAccount(label: String)
    case draftGone
    case noRecipients
    case scheduledSendUnsupported
    case unsupportedMailbox(name: String)
    case askOff
    case askFailed(String)
    case triageOff
    case triageBusy

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .askOff: "Turn on \"Let Siri see your inbox\" in Hey Pigeon's settings to ask about your mail."
        case .askFailed(let why): "Hey Pigeon couldn't answer: \(why)"
        case .triageOff: "Triage needs Apple Intelligence on this \(Device.name) and a connected account."
        case .triageBusy: "Hey Pigeon is already triaging. Let it finish first."
        case .notReady: "Hey Pigeon isn't ready yet. Try again in a moment."
        case .noSuchThread: "That email isn't in Hey Pigeon any more."
        case .noAccount: "Connect a Google account in Hey Pigeon first."
        case .aiOff: "Connect an AI provider in Hey Pigeon's settings to summarize."
        case .noDate: "I need a date for the reminder."
        case .draftGone: "That draft isn't open any more. Open it from Drafts first."
        case .noRecipients: "The draft has no recipient yet."
        case .scheduledSendUnsupported: "Hey Pigeon can't schedule a send. It can send it now."
        case .unsupportedMailbox(let name): "Hey Pigeon can't move mail to \(name). It can archive, trash or mark as spam."
        case .wrongAccount(let label): "The label \(label) belongs to another account."
        }
    }
}

@MainActor
enum IntentSupport {
    /// The one AppModel of the process. HeyPigeonApp.init builds it before
    /// any intent can run; on a cold background launch this only waits for
    /// that init to finish.
    static func model() async throws -> AppModel {
        for _ in 0..<100 {
            if let m = AppModel.current { return m }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw IntentError.notReady
    }

    /// The thread's row as the store has it now (never the entity's copy,
    /// which may be minutes old by the time Siri hands it back).
    static func row(_ entity: MailThreadEntity, in model: AppModel) throws -> ThreadRow {
        try row(id: entity.id, in: model)
    }

    static func row(id: String, in model: AppModel) throws -> ThreadRow {
        guard let row = try? model.engine.threadRow(id: id) else { throw IntentError.noSuchThread }
        return row
    }

    /// A question ("what needs a reply") deserves fresh data, but Siri's
    /// patience is short: sync when the last one is older than two minutes,
    /// and answer from the store after ten seconds whatever happened. The
    /// sync itself is never cut short — it finishes in the background and
    /// the next question sees its result.
    static func syncIfStale(_ model: AppModel, maxAge: TimeInterval = 120, budget: Duration = .seconds(10)) async {
        if let last = model.lastSyncAt, Date().timeIntervalSince(last) < maxAge { return }
        guard !model.accounts.isEmpty else { return }
        let before = model.lastSyncAt
        Task { await model.sync() }
        let deadline = ContinuousClock.now + budget
        var started = false
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            if model.lastSyncAt != before { return }
            if model.isSyncing { started = true } else if started { return }
        }
    }

    static func entities(_ rows: [ThreadRow], in model: AppModel) -> [MailThreadEntity] {
        rows.map { MailThreadEntity($0, account: model.account(for: $0)) }
    }
}
