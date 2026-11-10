// The composer's editor page in a real web view: its own script runs, and
// script inside the content does not. A saved draft's html is loaded into
// this page next to the bridge that can send the mail; the core's
// sanitizer removes handlers, and the page's policy is the second layer.

import Foundation
import Testing
import WebKit
@testable import HeyPigeon

@MainActor
struct EditorPageTests {
    /// Resumes once the page has loaded (or failed to).
    private final class Loaded: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?

        private func finish() {
            done?.resume()
            done = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: any Error) { finish() }
    }

    @Test func thePagesOwnScriptRunsAndHandlersInTheContentDoNot() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 480, height: 320))
        let loaded = Loaded()
        web.navigationDelegate = loaded
        await withCheckedContinuation { continuation in
            loaded.done = continuation
            web.loadHTMLString(HTMLEditorView.document(placeholder: "Write"), baseURL: nil)
        }
        // The nonce lets the page's script in: the bridge's object is there.
        let kind = try await web.evaluateJavaScript("typeof window.pigeon") as? String
        #expect(kind == "object")
        // Content with handlers, as a draft that slipped past the
        // sanitizer would carry them: a picture that fails to load (the
        // policy blocks it) and a click.
        let html = #"<img src="https://x.invalid/a.png" onerror="window.ran = 1"><p id="p" onclick="window.ran = 1">hi</p>"#
        _ = try await web.evaluateJavaScript("pigeon.setHTML(\(MacComposeEditor.json(html))); document.getElementById('p').click(); 0")
        try await Task.sleep(for: .milliseconds(400))
        let untouched = try await web.evaluateJavaScript("window.ran === undefined") as? Bool
        #expect(untouched == true)
        // And the content itself went in.
        let text = try await web.evaluateJavaScript("document.getElementById('p').textContent") as? String
        #expect(text == "hi")
    }
}
