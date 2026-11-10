// File › Print… (⌘P): the open thread on paper, or as a PDF from the print
// panel's PDF menu. The thread is laid out as one plain document — the
// subject, then each message under who sent it, to whom and when — in a
// web view of its own, with the reader's rules: no scripts, and no
// pictures from the web (a printout must not fetch a tracking pixel).
// The stored bodies are used; a thread never opened is fetched first
// (WindowState.run(.print)).

import AppKit
import WebKit

@MainActor
final class ThreadPrinter: NSObject, WKNavigationDelegate {
    /// The printer at work: the web view must outlive the print sheet,
    /// which returns before the user has answered it. Replaced by the
    /// next print.
    private static var current: ThreadPrinter?

    private let web: WKWebView
    private weak var window: NSWindow?

    static func print(_ detail: ThreadDetail, in window: NSWindow?) {
        let printer = ThreadPrinter(window: window)
        current = printer
        printer.web.loadHTMLString(document(detail), baseURL: nil)
    }

    private init(window: NSWindow?) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 960), configuration: config)
        self.window = window
        super.init()
        web.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.topMargin = 36
        info.bottomMargin = 36
        info.leftMargin = 36
        info.rightMargin = 36
        let operation = webView.printOperation(with: info)
        operation.view?.frame = webView.bounds
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    // MARK: The document

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The thread as one HTML page. Pure, for the tests.
    static func document(_ detail: ThreadDetail) -> String {
        let subject = detail.thread.subject.isEmpty ? "(no subject)" : detail.thread.subject
        let messages = detail.mail.map { m -> String in
            let to = m.to.map { $0 == "me" ? detail.thread.accountId : $0 }
            let cc = m.cc.map { $0 == "me" ? detail.thread.accountId : $0 }
            var head = "<div class=\"from\">\(escape(m.isMine ? "Me" : m.fromName)) &lt;\(escape(m.isMine ? detail.thread.accountId : m.fromAddress))&gt;</div>"
            if !to.isEmpty { head += "<div class=\"meta\">To: \(escape(to.joined(separator: ", ")))</div>" }
            if !cc.isEmpty { head += "<div class=\"meta\">Cc: \(escape(cc.joined(separator: ", ")))</div>" }
            head += "<div class=\"meta\">\(escape(Formatters.fullDate(m.date)))</div>"
            let body = m.bodyHTML.flatMap { $0.isEmpty ? nil : $0 } ?? "<pre>\(escape(m.bodyText ?? m.snippet))</pre>"
            return "<section>\(head)<div class=\"body\">\(body)</div></section>"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: cid:; style-src 'unsafe-inline'; font-src data:">
        <style>
          body { font: 12px -apple-system, system-ui; color: #000; margin: 0; }
          h1 { font-size: 18px; margin: 0 0 14px; }
          section { border-top: 1px solid #bbb; padding: 10px 0 16px; }
          .from { font-weight: 600; }
          .meta { color: #555; font-size: 11px; }
          .body { margin-top: 10px; }
          pre { font: inherit; white-space: pre-wrap; word-wrap: break-word; margin: 0; }
          img, table { max-width: 100% !important; height: auto; }
        </style></head><body><h1>\(escape(subject))</h1>\(messages.joined())</body></html>
        """
    }
}
