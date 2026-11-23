// A message's Advanced menu (docs/specs/message-advanced.md) on the Swift
// side: the words, the pure rules (what the plain text is, how the sheet
// groups the headers, what Copy all copies), and the three actions
// through AppModel over the mock engine — what reaches the clipboard and
// what the toast says, online, offline and when Gmail fails. What the
// original is and how HTML becomes text are the core's, tested in Rust
// (crates/core/src/source.rs, crates/adapter-gmail).

import Foundation
import Testing
@testable import HeyPigeon

/// What the model copied, in place of the simulator's clipboard.
@MainActor
private final class CopyBox {
    var text: String?
}

private func header(_ id: Int, _ name: String, _ value: String = "v") -> HeaderLine {
    HeaderLine(id: id, name: name, value: value)
}

private func htmlMessage(_ id: String, html: String?, text: String?, snippet: String = "") -> MessageItem {
    MessageItem(id: id, fromName: "Ana", fromAddress: "ana@acme.test", to: ["me"], date: Date(), snippet: snippet,
                bodyHTML: html, bodyText: text, isRead: true, isMine: false)
}

struct MessageAdvancedRuleTests {
    /// The three actions in the menu's order, in the words every app
    /// shows; the Mac's menu bar writes the same words in title case.
    @Test func theMenuHasThreeActionsInOneWording() {
        #expect(MessageAdvancedAction.allCases.map(\.title) == ["Copy original HTML", "Copy plain text", "Show headers"])
        #expect(MessageAdvancedAction.allCases.map { $0.menuBarTitle.lowercased() }
            == MessageAdvancedAction.allCases.map { $0.title.lowercased() })
        #expect(MessageAdvanced.menuTitle == "Advanced")
    }

    /// R6: the stored text part as it is; without one the text of the
    /// HTML, by the core; without either the snippet; nil for nothing.
    @Test func plainTextIsTheTextPartThenTheHTMLsTextThenTheSnippet() {
        let both = htmlMessage("m1", html: "<p>From the HTML</p>", text: "From the text part\n")
        #expect(MessageAdvanced.plainText(of: both) == "From the text part\n")
        let htmlOnly = htmlMessage("m2", html: "<p>Hi <b>there</b></p><div>Bye</div>", text: nil, snippet: "Hi there")
        #expect(MessageAdvanced.plainText(of: htmlOnly) == "Hi there\n\nBye")
        // A text part of white space alone is no text.
        let blank = htmlMessage("m3", html: "<p>Real</p>", text: "  \n")
        #expect(MessageAdvanced.plainText(of: blank) == "Real")
        let listed = htmlMessage("m4", html: nil, text: nil, snippet: "Only a snippet")
        #expect(MessageAdvanced.plainText(of: listed) == "Only a snippet")
        #expect(MessageAdvanced.plainText(of: htmlMessage("m5", html: "<p> </p>", text: nil)) == nil)
    }

    /// R8: the main headers first, in the sheet's order whatever their
    /// case and wherever they stood; the rest as they were sent.
    @Test func theSheetListsTheMainHeadersFirstAndTheRestAsSent() {
        let sent = [header(0, "Received", "one"), header(1, "DKIM-Signature"), header(2, "to"), header(3, "Received", "two"),
                    header(4, "Message-Id"), header(5, "From"), header(6, "X-Mailer"), header(7, "Subject")]
        let sections = MessageAdvanced.sections(sent)
        #expect(sections.main.map(\.name) == ["From", "to", "Subject", "Message-Id"])
        #expect(sections.other.map(\.id) == [0, 1, 3, 6])
        #expect(MessageAdvanced.sections([]).main.isEmpty)
    }

    /// R9: Copy all is every header as it was sent, one per line.
    @Test func copyAllIsEveryHeaderInTheOrderSent() {
        let sent = [header(0, "Received", "by mx"), header(1, "From", "Ana <ana@acme.test>"), header(2, "Subject", "Hi: there")]
        #expect(MessageAdvanced.text(sent) == "Received: by mx\nFrom: Ana <ana@acme.test>\nSubject: Hi: there")
    }
}

@MainActor
struct MessageAdvancedModelTests {
    let model: AppModel
    let engine: MockEngine
    private let copied = CopyBox()

    init() {
        engine = MockEngine()
        model = AppModel(engine: engine)
        let box = copied
        model.copyText = { box.text = $0 }
    }

    /// The sample inbox's first thread and its latest message.
    private func sample() async throws -> (ThreadRow, MessageItem) {
        let found = try await engine.thread(id: "t1")
        let detail = try #require(found)
        let last = try #require(detail.mail.last)
        return (detail.thread, last)
    }

    /// R1–R3: the HTML as it was sent — not the sanitized body the app
    /// stores and shows — is on the clipboard, and the toast says so.
    @Test func copyOriginalHTMLCopiesWhatWasSentNotWhatIsStored() async throws {
        let (row, message) = try await sample()
        await model.copyOriginalHTML(of: message, in: row, online: true)
        let html = try #require(copied.text)
        #expect(html.contains("<script>") && html.contains("onclick"))
        #expect(html != message.bodyHTML)
        #expect(model.toast?.text == "HTML copied")
        #expect(engine.originalRequests == [message.id])
    }

    /// R2: offline nothing is asked of Gmail and nothing is copied.
    @Test func offlineNothingIsAskedAndNothingCopied() async throws {
        let (row, message) = try await sample()
        await model.copyOriginalHTML(of: message, in: row, online: false)
        #expect(copied.text == nil)
        #expect(engine.originalRequests.isEmpty)
        #expect(model.toast?.text == MessageAdvanced.htmlOffline)
    }

    /// R5: a fetch that fails copies nothing and says why.
    @Test func aFailedFetchCopiesNothingAndSaysWhy() async throws {
        let (row, message) = try await sample()
        engine.originalFailure = MockEngine.MockError.invalid("network: timed out")
        await model.copyOriginalHTML(of: message, in: row, online: true)
        #expect(copied.text == nil)
        #expect(model.toast?.text == "Couldn't fetch the original HTML: network: timed out")
        // The message can be asked for again afterwards.
        engine.originalFailure = nil
        await model.copyOriginalHTML(of: message, in: row, online: true)
        #expect(copied.text != nil)
    }

    /// R4: plain-text mail and an oversized part each say so; neither
    /// puts anything on the clipboard.
    @Test func noHTMLAndTooLargeAreSaidAndCopyNothing() async throws {
        let (row, message) = try await sample()
        engine.originals[message.id] = OriginalMessage(headers: [], html: .missing)
        await model.copyOriginalHTML(of: message, in: row, online: true)
        #expect(copied.text == nil && model.toast?.text == MessageAdvanced.htmlMissing)
        engine.originals[message.id] = OriginalMessage(headers: [], html: .tooLarge)
        await model.copyOriginalHTML(of: message, in: row, online: true)
        #expect(copied.text == nil && model.toast?.text == MessageAdvanced.htmlTooLarge)
    }

    /// R6: the text is copied from what the device holds; Gmail is not
    /// asked, so it works offline.
    @Test func copyPlainTextIsLocal() async throws {
        let (_, message) = try await sample()
        model.copyPlainText(of: message)
        #expect(copied.text == message.bodyText)
        #expect(model.toast?.text == "Text copied")
        #expect(engine.originalRequests.isEmpty)
        copied.text = nil
        model.copyPlainText(of: htmlMessage("m9", html: nil, text: nil))
        #expect(copied.text == nil && model.toast?.text == MessageAdvanced.textMissing)
    }

    /// R7–R9: the sheet opens at once, its headers arrive from Gmail, and
    /// Copy all copies them as they were sent.
    @Test func showHeadersFetchesThemAndCopyAllCopiesThem() async throws {
        let (row, message) = try await sample()
        #expect(!model.copyHeaders())
        let load = model.showHeaders(of: message, in: row, online: true)
        #expect(model.headersSheet?.id == message.id && model.headersSheet?.state == .loading)
        await load.value
        guard case .loaded(let headers)? = model.headersSheet?.state else {
            Issue.record("the headers did not load")
            return
        }
        #expect(headers.first?.name == "Delivered-To")
        #expect(headers.contains { $0.name == "Subject" && $0.value == row.subject })
        #expect(model.copyHeaders())
        #expect(copied.text == MessageAdvanced.text(headers))
        #expect(copied.text?.hasPrefix("Delivered-To: ") == true)
    }

    /// R7: offline the sheet says so and asks nothing; a failure is
    /// shown, and Try again fetches.
    @Test func theSheetSaysOfflineAndFailureAndTriesAgain() async throws {
        let (row, message) = try await sample()
        await model.showHeaders(of: message, in: row, online: false).value
        #expect(model.headersSheet?.state == .offline && engine.originalRequests.isEmpty)
        engine.originalFailure = MockEngine.MockError.invalid("network: timed out")
        await model.loadHeaders(online: true)
        #expect(model.headersSheet?.state == .failed("network: timed out"))
        #expect(!model.copyHeaders() && copied.text == nil)
        engine.originalFailure = nil
        await model.loadHeaders(online: true)
        guard case .loaded? = model.headersSheet?.state else {
            Issue.record("Try again did not load the headers")
            return
        }
    }

    /// The headers are held only while the sheet is open: a sheet closed
    /// before its fetch ran stays closed, and holds nothing.
    @Test func aSheetClosedBeforeItsHeadersCameStaysClosed() async throws {
        let (row, message) = try await sample()
        let load = model.showHeaders(of: message, in: row, online: true)
        model.headersSheet = nil
        await load.value
        #expect(model.headersSheet == nil)
    }

    /// The entry point that names an email (the Mac's palette and menu
    /// bar) runs the same action on its latest message.
    @Test func anEmailsActionRunsOnItsLatestMessage() async throws {
        let (row, message) = try await sample()
        await model.advanced(.copyPlainText, onLatestOf: row)
        #expect(copied.text == message.bodyText)
        await model.advanced(.showHeaders, onLatestOf: row)
        #expect(model.headersSheet?.id == message.id)
    }
}
