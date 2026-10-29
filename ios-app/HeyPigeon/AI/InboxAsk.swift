// "Ask my inbox" (docs/ios-intelligence.md, "iOS 27 › Ask my inbox"): chat
// with your own mail, entirely on this device. iOS 27's `SpotlightSearchTool`
// lets a LanguageModelSession run natural-language searches against the
// app's own Spotlight index — the one SpotlightIndexer keeps, with the
// Communications content domain built for mail-like data and a
// ContactResolver so "mail from me" and "from Ana" resolve to addresses.
// The on-device model only: the answer never leaves the device, and the
// whole feature is off while Settings › Siri & Search has the index off.

import CoreSpotlight
import Foundation
import FoundationModels

/// The structured answer: the text, and the threads it rests on so the
/// sheet can list them under it, tappable.
@Generable
struct InboxAnswer {
    @Guide(description: "The answer, in one to four short sentences or bullets. Say plainly when the mail does not say.")
    var answer: String
    @Guide(description: "The unique identifiers of the search results the answer is based on, as returned by the search tool. Empty when none was used.", .count(0...5))
    var citedThreadIds: [String]
}

/// One asked question with its streamed answer and the threads it cites.
@MainActor
@Observable
final class InboxAskConversation {
    let question: String
    private(set) var answer = ""
    private(set) var citations: [ThreadRow] = []
    private(set) var isAnswering = true
    private(set) var error: String?

    init(question: String) { self.question = question }

    fileprivate func stream(_ partial: InboxAnswer.PartiallyGenerated) {
        if let a = partial.answer { answer = a }
    }

    fileprivate func finish(_ final: InboxAnswer, model: AppModel) {
        answer = final.answer
        citations = InboxAsk.validCitations(final.citedThreadIds, in: model)
        isAnswering = false
    }

    fileprivate func fail(_ message: String) {
        error = message
        isAnswering = false
    }
}

@MainActor
enum InboxAsk {
    /// On when the index is on and this device runs the on-device model.
    static func isAvailable(_ model: AppModel) -> Bool {
        model.siriIndexEnabled && AppleIntelligenceProvider.isAvailable
    }

    static let instructions = """
    You answer questions about the user's own email, using only what the search tool returns. \
    Search first; search again with other words when the first results do not answer. Keep answers \
    short and factual, name who said what and when, and quote amounts, dates and flight or order \
    numbers exactly as the mail has them. When the mail does not say, say so — never guess. \
    "Me" and the user's own addresses mean the user.
    """

    /// Ask one question; the conversation streams the answer as it comes.
    static func ask(_ question: String, model: AppModel) -> InboxAskConversation {
        let conversation = InboxAskConversation(question: question)
        guard isAvailable(model) else {
            conversation.fail("Turn on \"Let Siri see your inbox\" in Settings to ask about your mail.")
            return conversation
        }
        let session = makeSession(model: model)
        Task { @MainActor in
            do {
                let stream = session.streamResponse(to: question, generating: InboxAnswer.self)
                for try await partial in stream {
                    conversation.stream(partial.content)
                }
                let final = try await stream.collect()
                conversation.finish(final.content, model: model)
                AiUsageLedger.shared.record(provider: AppleIntelligenceProvider.providerId, final.usage)
            } catch let error as LanguageModelSession.GenerationError {
                conversation.fail(FoundationModelsBackend.describe(error))
            } catch {
                conversation.fail(error.localizedDescription)
            }
        }
        return conversation
    }

    /// One answer, whole — for the App Intent.
    static func answer(_ question: String, model: AppModel) async throws -> InboxAnswer {
        guard isAvailable(model) else { throw IntentError.askOff }
        let session = makeSession(model: model)
        do {
            let response = try await session.respond(to: question, generating: InboxAnswer.self)
            AiUsageLedger.shared.record(provider: AppleIntelligenceProvider.providerId, response.usage)
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            throw IntentError.askFailed(FoundationModelsBackend.describe(error))
        }
    }

    /// A session on the on-device model with the Spotlight search tool
    /// over this app's index: the Communications domain (mail-shaped
    /// results — sender, recipients, subject, dates) and a contact resolver
    /// made of the user's own account addresses.
    private static func makeSession(model: AppModel) -> LanguageModelSession {
        var configuration = SpotlightSearchTool.Configuration()
        configuration.contentDomain = .communications
        configuration.contactResolver = AccountContactResolver(accounts: model.accounts)
        let tool = SpotlightSearchTool(configuration: configuration)
        return SystemModelProvider().session(instructions: instructions, task: .completion, tools: [tool])
    }

    /// Only ids the store knows, in the order given, each once; the tool
    /// can return a trashed thread the index has not dropped yet, and the
    /// model can echo an id it made up.
    static func validCitations(_ ids: [String], in model: AppModel) -> [ThreadRow] {
        var seen = Set<String>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted, let row = try? model.engine.threadRow(id: id),
                  !row.labels.contains("TRASH") else { return nil }
            return row
        }
    }
}

/// "Mail from me", "what did I send Ana": the user is every connected
/// account; everyone else is resolved by Spotlight from the index's
/// participant attributes.
struct AccountContactResolver: ContactResolver {
    let accounts: [MailAccount]

    func contacts(matching query: String) async -> [ResolvedContact] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let me = ["me", "myself", "i"].contains(q)
        return accounts
            .filter { me || $0.email.lowercased().contains(q) || $0.displayName.lowercased().contains(q) }
            .map { ResolvedContact(displayName: $0.displayName, handles: [$0.email], isMe: true) }
    }
}
