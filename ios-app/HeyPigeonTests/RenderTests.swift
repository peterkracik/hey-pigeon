// What the core's sanitizer returns, loaded into a real web view the way
// the message view loads it (MailDocument.wrap, the mail's own scripts
// off): the text is there, the links keep their addresses, nothing the
// mail brought runs, and the page's helpers (the link warning) work on it.
// The sanitizer's own tests compare strings; this is the same HTML in
// WebKit. Every wait has a timeout: a web view that never answers fails
// the test instead of hanging the run.

import Foundation
import Testing
import WebKit
@testable import HeyPigeon

/// A web view that loads one page and says whether it finished in time.
@MainActor
private final class Page: NSObject, WKNavigationDelegate {
    let web: WKWebView
    private var waiting: CheckedContinuation<Bool, Never>?

    override init() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 800), configuration: config)
        super.init()
        web.navigationDelegate = self
    }

    func load(_ html: String, timeout: Duration = .seconds(20)) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            waiting = continuation
            web.loadHTMLString(html, baseURL: nil)
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                self.finish(false)
            }
        }
    }

    private func finish(_ loaded: Bool) {
        waiting?.resume(returning: loaded)
        waiting = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(false)
    }

    /// The script's result as a string. Every script here ends in a
    /// string, never null: the async evaluate does not take a null well.
    func string(_ script: String) async -> String {
        ((try? await web.evaluateJavaScript(script)) as? String) ?? ""
    }
}

@MainActor
struct SanitizedMailRenderTests {
    /// A newsletter-shaped message with everything a sender can put in one.
    static let newsletter = """
    <html><head><title>The Weekly</title>
    <style>@import url(http://cdn.example/a.css); .btn { color: #c00; } .hide { display: none; }</style>
    <script>window.__ran = 1;</script><meta http-equiv="refresh" content="0;url=https://evil.example/"></head>
    <body bgcolor="#eeeeee"><table width="600" cellpadding="0"><tr><td align="center">
    <h1 onclick="window.__ran = 2">Hello Peter</h1>
    <p style="color:#333;position:fixed;top:0">Sale ends <b>Friday</b>.</p>
    <a class="btn" href="https://shop.example/sale?utm=1&id=2#top" target="_blank" onclick="window.__ran = 3">Shop now</a>
    <a href="https://evil.example/login">paypal.com</a>
    <a href="javascript:window.__ran=4">Unsafe</a>
    <img src="https://track.example/open.gif" width="1" height="1">
    <img src="cid:logo@acme" width="120" height="40" alt="Acme">
    <form action="https://evil.example/post"><input name="q"><button>Go</button></form>
    <iframe src="https://evil.example/frame"></iframe>
    <div class="gmail_quote">On Monday Ana wrote:<blockquote>the older message</blockquote></div>
    </td></tr></table></body></html>
    """

    @Test func theSanitizedPageShowsTheMailAndRunsNothing() async throws {
        let clean = MailHTML.sanitize(Self.newsletter)
        #expect(MailDocument.trackerCount(in: clean) == 1)

        let page = Page()
        let loaded = await page.load(MailDocument.wrap(clean, allowRemoteImages: false, dark: false))
        try #require(loaded, "the page did not finish loading")

        // The text a reader sees, without the document's title.
        let text = await page.string("document.body.innerText")
        #expect(text.contains("Hello Peter"))
        #expect(text.contains("Sale ends Friday."))
        #expect(text.contains("the older message"))
        #expect(!text.contains("The Weekly"))

        // Links keep their exact address; the script URL is not one.
        let links = await page.string(
            "JSON.stringify(Array.from(document.querySelectorAll('a')).map(function (a) { return a.getAttribute('href') || ''; }))")
        #expect(links.contains(#""https://shop.example/sale?utm=1&id=2#top""#))
        #expect(links.contains(#""https://evil.example/login""#))
        #expect(!links.contains("javascript:"))

        // Nothing the mail brought is there to run, and nothing ran.
        let state = await page.string("""
        JSON.stringify([document.scripts.length, document.forms.length, document.querySelectorAll('iframe, meta[http-equiv=refresh], input, button').length,
          typeof window.__ran, document.querySelectorAll('[onclick]').length, document.querySelectorAll('.gmail_quote').length,
          document.querySelectorAll('img[src^="cid:"]').length, document.querySelectorAll('img[src^="http"]').length])
        """)
        #expect(state == #"[0,0,0,"undefined",0,1,1,0]"#)

        // The page's own helper still works on it: a link that says one
        // site and goes to another is counted and marked — once, however
        // often the script runs.
        let warned = await page.string(
            MailDocument.linkWarningScript + MailDocument.linkWarningScript + "String(window.__pigeonLinkWarnings)")
        #expect(warned == "1")
        let after = await page.string("document.body.innerText")
        #expect(after.components(separatedBy: "\u{2192} evil.example").count == 2)
    }

    /// What a sender can do to hide the warning, or to raise the tracker
    /// count: a planted note, a style sheet, hidden text in the link, the
    /// app's own class on an element of theirs.
    @Test func theMailCannotSwitchTheWarningOffOrForgeTheCount() async throws {
        let hostile = """
        <style>.hp-linkwarn, a + span { display: none !important; font-size: 0 !important; }</style>
        <p><a href="https://evil.example/a">paypal.com</a><span class="hp-linkwarn"></span></p>
        <p><a href="https://evil.example/b">paypal.com<span style="display:none">evil.example/</span></a></p>
        <p><a href="https://docs.example/c">Invoice.pdf</a></p>
        <p class="hp-tracker">class="hp-tracker" &lt;span class="hp-tracker" style="display:none"&gt;&lt;/span&gt;</p>
        <span class="hp-tracker" style="display:none"></span>
        """
        let clean = MailHTML.sanitize(hostile)
        #expect(MailDocument.trackerCount(in: clean) == 0)

        let page = Page()
        try #require(await page.load(MailDocument.wrap(clean, allowRemoteImages: false, dark: false)))
        #expect(await page.string(MailDocument.linkWarningScript + "String(window.__pigeonLinkWarnings)") == "2")
        // Both notes are there to be read, whatever the mail's styles say.
        let shown = await page.string("""
        String(Array.from(document.querySelectorAll('a')).filter(function (a) {
          var n = a.nextSibling;
          return n && n.nodeType === 1 && /evil\\.example/.test(n.textContent) && n.getBoundingClientRect().width > 0;
        }).length)
        """)
        #expect(shown == "2")
    }

    /// A received body on its way into a composer (the Mac's forward)
    /// leaves the app's own marks behind: they are for this app's view.
    @Test func aForwardedBodyCarriesNoMarkerAndNoSeal() {
        let clean = MailHTML.sanitize(Self.newsletter)
        #expect(clean.contains(MailDocument.trackerMarker))
        let outgoing = ComposerHTML.clean(clean)
        #expect(!outgoing.contains("hp-tracker"))
        #expect(!outgoing.contains("hp-seal"))
        #expect(outgoing.contains("Sale ends"))
    }

    @Test func theStatusLineShowsTheHostFirstAndNoUserPart() {
        #expect(MailDocument.hoverText(for: "https://shop.example/sale?id=2") == "shop.example/sale?id=2")
        #expect(MailDocument.hoverText(for: "https://accounts.google.com:signin@evil.example/x") == "evil.example/x")
        #expect(MailDocument.hoverText(for: "https://evil.example/") == "evil.example")
        #expect(MailDocument.hoverText(for: "mailto:ana@acme.test?subject=Hi") == "mailto:ana@acme.test")
        #expect(MailDocument.hoverText(for: "not a url") == nil)
        let long = MailDocument.hoverText(for: "https://evil.example/" + String(repeating: "a", count: 900))
        #expect(long?.hasPrefix("evil.example/") == true)
        #expect(long?.count == 300)
    }

    @Test func aPlainReplyComesThroughUntouchedInWhatMatters() async throws {
        let reply = #"<div dir="ltr">Sounds good, see you at 8.<br><br><a href="mailto:tomas@friends.test?subject=Ride">tomas@friends.test</a></div>"#
        let clean = MailHTML.sanitize(reply)
        let page = Page()
        try #require(await page.load(MailDocument.wrap(clean, allowRemoteImages: false, dark: true)))
        #expect(await page.string("document.body.innerText").contains("Sounds good, see you at 8."))
        #expect(await page.string("document.querySelector('a').getAttribute('href')") == "mailto:tomas@friends.test?subject=Ride")
        #expect(MailDocument.trackerCount(in: clean) == 0)
    }
}
