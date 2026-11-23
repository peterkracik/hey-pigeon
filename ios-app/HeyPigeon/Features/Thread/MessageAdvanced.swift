// A message's "Advanced" menu (docs/specs/message-advanced.md): Copy
// original HTML, Copy plain text and Show headers, in the ••• of an open
// message and on a long press (a right-click) of its header line — the
// same three, in the same words, on the phone, the iPad and the Mac,
// whose palette also runs them on the open email's latest message.
//
// What each one does is the model's (the extension below), over pure
// rules (`MessageAdvanced`) that are tested without a view:
// - the original HTML and the headers are asked from Gmail when the user
//   asks (`MailEngine.originalMessage`: one request, nothing stored). The
//   HTML is unsanitized — as its sender wrote it, scripts and trackers
//   included — and goes to the clipboard only: no view is ever handed it;
// - the plain text is what this device already holds: the message's
//   text part, or the text of its (sanitized) HTML as the core reads it.

import SwiftUI

/// The three actions, in the menu's order.
enum MessageAdvancedAction: String, CaseIterable, Identifiable, Sendable {
    case copyHTML, copyPlainText, showHeaders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copyHTML: "Copy original HTML"
        case .copyPlainText: "Copy plain text"
        case .showHeaders: "Show headers"
        }
    }

    /// The same words as the Mac's menu bar writes its items: in title
    /// case, like "Mark Done" and "Reply All" beside them.
    var menuBarTitle: String {
        switch self {
        case .copyHTML: "Copy Original HTML"
        case .copyPlainText: "Copy Plain Text"
        case .showHeaders: "Show Headers"
        }
    }

    var systemImage: String {
        switch self {
        case .copyHTML: "chevron.left.forwardslash.chevron.right"
        case .copyPlainText: "text.alignleft"
        case .showHeaders: "list.bullet.rectangle"
        }
    }
}

/// The menu's words and its rules.
enum MessageAdvanced {
    static let menuTitle = "Advanced"
    static let menuImage = "wrench.and.screwdriver"

    // What the toast says (R2–R6).
    static let htmlCopied = "HTML copied"
    static let htmlOffline = "You're offline. The original HTML is fetched from Gmail, so nothing was copied."
    static let htmlMissing = "This email has no HTML, only plain text. Nothing was copied."
    static let htmlTooLarge = "This email's HTML is too large to copy"
    static let fetching = "Fetching the original from Gmail…"
    static let textCopied = "Text copied"
    static let textMissing = "This email has no text to copy"
    static let noMessage = "Couldn't load this email"

    static func htmlFailed(_ why: String) -> String { "Couldn't fetch the original HTML: \(why)" }

    /// How long a fetch may run before the toast says it is running: a
    /// quick one ends in "HTML copied" and needs no word before it.
    static let patience: Duration = .milliseconds(700)

    // The headers sheet (R7–R9).
    static let headersTitle = "Headers"
    static let headersWorking = "Fetching from Gmail…"
    static let headersOffline = "You're offline. A message's original headers are fetched from Gmail."
    static let headersEmpty = "Gmail returned no headers for this message."
    static let mainTitle = "Main"
    static let otherTitle = "All other headers"
    static let copyAll = "Copy all"
    static let copied = "Copied"
    static var headersFooter: String {
        "As Gmail holds them, fetched just now. They are not saved on this \(Device.name)."
    }

    /// The headers a reader asks for first, in the order the sheet lists
    /// them; everything else follows as it was sent.
    static let mainHeaders = ["From", "To", "Cc", "Bcc", "Reply-To", "Subject", "Date",
                              "Message-ID", "In-Reply-To", "References"]

    /// The sheet's two groups (R8): the main headers in `mainHeaders`'
    /// order (a name is matched whatever its case; one sent twice stays
    /// twice, in the order sent), then every other header as it was sent.
    static func sections(_ headers: [HeaderLine]) -> (main: [HeaderLine], other: [HeaderLine]) {
        func rank(_ h: HeaderLine) -> Int? {
            mainHeaders.firstIndex { $0.caseInsensitiveCompare(h.name) == .orderedSame }
        }
        let main = headers.enumerated()
            .compactMap { item in rank(item.element).map { (rank: $0, at: item.offset, header: item.element) } }
            .sorted { ($0.rank, $0.at) < ($1.rank, $1.at) }
            .map(\.header)
        return (main, headers.filter { rank($0) == nil })
    }

    /// What Copy all copies (R9): every header, `Name: value`, one per
    /// line, in the order the message was sent with — not the sheet's.
    static func text(_ headers: [HeaderLine]) -> String {
        headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
    }

    /// What Copy plain text copies (R6): the message's text part as it is
    /// stored; for a message that came as HTML alone, the text of that
    /// HTML (`textOfHTML`: the core's `plain_text`); failing both, its
    /// snippet. Nil when the message has no text at all.
    static func plainText(of message: MessageItem,
                          textOfHTML: (String) -> String = { MailHTML.plainText($0) }) -> String? {
        func filled(_ s: String?) -> String? {
            guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }
        return filled(message.bodyText) ?? filled(message.bodyHTML.map(textOfHTML)) ?? filled(message.snippet)
    }
}

/// The Show headers sheet's state, on the model while the sheet is open.
struct MessageHeadersPresentation: Identifiable, Equatable {
    enum State: Equatable {
        case loading
        case loaded([HeaderLine])
        /// No network: nothing was asked.
        case offline
        case failed(String)
    }

    /// The message's id.
    let id: String
    let threadId: String
    /// The thread's subject, under the sheet's title.
    let subject: String
    var state: State = .loading
}

extension AppModel {
    /// Run one of a message's Advanced actions: the menus' and the Mac
    /// palette's one way in.
    func advanced(_ action: MessageAdvancedAction, on message: MessageItem, in row: ThreadRow) {
        switch action {
        case .copyHTML: Task { await copyOriginalHTML(of: message, in: row) }
        case .copyPlainText: copyPlainText(of: message)
        case .showHeaders: showHeaders(of: message, in: row)
        }
    }

    /// The same on an email's latest message, for an entry point that
    /// names an email and not one of its messages (the Mac's palette):
    /// the stored thread says which that is, Gmail's when the store has
    /// no messages for it yet.
    func advanced(_ action: MessageAdvancedAction, onLatestOf row: ThreadRow) async {
        let id = row.id
        var detail = try? await engine.readInBackground { try $0.threadLocal(id: id) }
        if detail?.mail.last == nil { detail = try? await engine.thread(id: id) }
        guard let message = detail?.mail.last else {
            show(MessageAdvanced.noMessage)
            return
        }
        advanced(action, on: message, in: row)
    }

    /// R1–R5: the message's HTML as it was sent, to the clipboard. Asked
    /// from Gmail now; offline nothing is asked. Whatever goes wrong,
    /// the clipboard keeps what it held and the toast says why.
    func copyOriginalHTML(of message: MessageItem, in row: ThreadRow,
                          online: Bool = Connectivity.shared.isOnline) async {
        guard online else {
            show(MessageAdvanced.htmlOffline)
            return
        }
        // A second tap while the first is on its way adds nothing.
        guard originalsInFlight.insert(message.id).inserted else { return }
        defer { originalsInFlight.remove(message.id) }
        // A slow line: say that something is happening.
        let waiting = Task { [weak self] in
            try? await Task.sleep(for: MessageAdvanced.patience)
            guard !Task.isCancelled else { return }
            self?.show(MessageAdvanced.fetching)
        }
        defer { waiting.cancel() }
        do {
            let original = try await engine.originalMessage(threadId: row.id, messageId: message.id)
            waiting.cancel()
            switch original.html {
            case .sent(let html):
                copyText(html)
                show(MessageAdvanced.htmlCopied)
            case .missing: show(MessageAdvanced.htmlMissing)
            case .tooLarge: show(MessageAdvanced.htmlTooLarge)
            }
        } catch {
            waiting.cancel()
            show(MessageAdvanced.htmlFailed(errorText(error)))
        }
    }

    /// R6: the message's text, from what this device holds. No network.
    func copyPlainText(of message: MessageItem) {
        guard let text = MessageAdvanced.plainText(of: message) else {
            show(MessageAdvanced.textMissing)
            return
        }
        copyText(text)
        show(MessageAdvanced.textCopied)
    }

    /// R7: open the headers sheet on a message and fetch its headers. The
    /// task is handed back for a test to wait on.
    @discardableResult
    func showHeaders(of message: MessageItem, in row: ThreadRow,
                     online: Bool = Connectivity.shared.isOnline) -> Task<Void, Never> {
        headersSheet = MessageHeadersPresentation(id: message.id, threadId: row.id, subject: row.subject)
        return Task { await loadHeaders(online: online) }
    }

    /// Fetch the open sheet's headers (when it opens, and on Try again).
    /// An answer for a sheet that was closed meanwhile, or that shows
    /// another message by now, is dropped.
    func loadHeaders(online: Bool = Connectivity.shared.isOnline) async {
        guard let sheet = headersSheet else { return }
        guard online else {
            headersSheet?.state = .offline
            return
        }
        headersSheet?.state = .loading
        let state: MessageHeadersPresentation.State
        do {
            let original = try await engine.originalMessage(threadId: sheet.threadId, messageId: sheet.id)
            state = .loaded(original.headers)
        } catch {
            state = .failed(errorText(error))
        }
        guard headersSheet?.id == sheet.id else { return }
        headersSheet?.state = state
    }

    /// R9: every header of the open sheet to the clipboard; false when
    /// there is none to copy. The sheet says "Copied" itself: a toast
    /// would be under it.
    @discardableResult
    func copyHeaders() -> Bool {
        guard case .loaded(let headers)? = headersSheet?.state, !headers.isEmpty else { return false }
        copyText(MessageAdvanced.text(headers))
        VoiceOver.announce("Headers copied")
        return true
    }
}

/// The Advanced submenu, for a message's ••• and its context menu.
struct MessageAdvancedMenu: View {
    let run: (MessageAdvancedAction) -> Void

    var body: some View {
        Menu {
            ForEach(MessageAdvancedAction.allCases) { action in
                Button { run(action) } label: { Label(action.title, systemImage: action.systemImage) }
            }
        } label: {
            Label(MessageAdvanced.menuTitle, systemImage: MessageAdvanced.menuImage)
        }
    }
}
