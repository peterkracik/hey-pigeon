// Untrusted mail HTML, rendered as safely as a WKWebView allows:
// JavaScript off, strict CSP, remote images blocked until the user allows
// the sender, every link handed to Safari. The HTML arrives already
// sanitized by the core (ammonia); this is the second layer.

import SafariServices
import SwiftUI
import WebKit

struct MessageBodyView: View {
    let html: String?
    let text: String
    let senderAddress: String
    @AppStorage("allowedImageSenders") private var allowedSendersRaw = ""
    @State private var height: CGFloat = 80
    @State private var link: URL?
    /// The trailing quoted history ("On … wrote:") stays folded behind a
    /// ••• button, like the desktop's quote pill.
    @State private var showQuoted = false
    @State private var hasQuote = false
    @Environment(\.colorScheme) private var scheme

    private var imagesAllowed: Bool {
        allowedSendersRaw.split(separator: "\n").contains(Substring(senderAddress.lowercased()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let html, !html.isEmpty {
                if !imagesAllowed && html.localizedCaseInsensitiveContains("<img") {
                    HStack(spacing: 6) {
                        Text("Remote images hidden").font(.caption).foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Button("Load") { allowedSendersRaw += "\n\(senderAddress.lowercased())" }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .buttonStyle(.plain)
                            .accessibilityLabel("Load images from \(senderAddress)")
                    }
                }
                HTMLView(html: html, allowRemoteImages: imagesAllowed, dark: scheme == .dark, showQuoted: showQuoted,
                         height: $height, hasQuote: $hasQuote) { url in link = url }
                    .frame(height: height)
                if hasQuote && !showQuoted { quoteButton }
            } else if let split = Self.splitQuoted(text) {
                Text(Self.linkified(split.main)).font(.body).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                if showQuoted {
                    Text(Self.linkified(split.quoted)).font(.subheadline).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.separator).frame(width: 2) }
                } else {
                    quoteButton
                }
            } else {
                Text(Self.linkified(text)).font(.body).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
            }
        }
        // Links in the plain-text body open the same in-app Safari sheet as
        // links in HTML mail, not the Safari app.
        .environment(\.openURL, OpenURLAction { url in
            link = url
            return .handled
        })
        .sheet(item: $link) { url in SafariView(url: url).ignoresSafeArea() }
    }

    private var quoteButton: some View {
        Button { showQuoted = true } label: {
            Text("•••").font(.callout.weight(.bold)).kerning(2).foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10).padding(.bottom, 4).padding(.top, 1)
                .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show quoted text")
    }

    /// Splits a plain-text body into what was written and the trailing
    /// quote: a run of "> " lines (blank lines allowed), optionally after an
    /// "On … wrote:" line. Nil when there is no trailing quote or nothing
    /// before it, so non-quoted text is never hidden. Same rules as
    /// desktop-app/src/lib/EmailBody.svelte.
    static func splitQuoted(_ text: String) -> (main: String, quoted: String)? {
        let lines = text.components(separatedBy: "\n")
        var i = lines.count
        var hasQuote = false
        while i > 0 {
            let l = lines[i - 1]
            if l.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix(">") { hasQuote = true; i -= 1 }
            else if l.trimmingCharacters(in: .whitespaces).isEmpty { i -= 1 }
            else { break }
        }
        guard hasQuote, i < lines.count else { return nil }
        if i > 0, lines[i - 1].range(of: #"^On\s.+wrote:\s*$"#, options: .regularExpression) != nil { i -= 1 }
        let main = lines[..<i].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !main.isEmpty else { return nil }
        return (main, lines[i...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Plain-text mail with every URL turned into a tappable, underlined link.
    private static func linkified(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return out }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, ["http", "https", "mailto"].contains(url.scheme ?? ""),
                  let r = Range(match.range, in: text), let ar = Range(r, in: out) else { continue }
            out[ar].link = url
            out[ar].underlineStyle = .single
        }
        return out
    }
}

extension URL: Identifiable { public var id: String { absoluteString } }

private struct HTMLView: UIViewRepresentable {
    let html: String
    let allowRemoteImages: Bool
    let dark: Bool
    let showQuoted: Bool
    @Binding var height: CGFloat
    @Binding var hasQuote: Bool
    let onLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        // URLs written as plain text are linkified in didFinish instead of by
        // the .link detector: its taps arrive as x-apple-data-detectors: URLs,
        // which the navigation policy below cancels, so they never opened.
        config.dataDetectorTypes = [.phoneNumber]
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.scrollView.isScrollEnabled = false
        web.isOpaque = false
        web.backgroundColor = .clear
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        let key = "\(allowRemoteImages)-\(dark)-\(showQuoted)-\(html.hashValue)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        web.loadHTMLString(wrapped, baseURL: nil)
    }

    /// CSP: no scripts, no frames, no forms; images only from data:/cid:
    /// unless allowed. Base styles keep the mail's own layout but set a
    /// readable measure and the app's text colour in both themes.
    private var wrapped: String {
        let img = allowRemoteImages ? "img-src * data: cid:" : "img-src data: cid:"
        let fg = dark ? "#F7F7F8" : "#0D0D10"
        let link = dark ? "#9A9CA2" : "#33363E"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; \(img); style-src 'unsafe-inline'; font-src data:; frame-src 'none'; form-action 'none'; base-uri 'none'">
        <style>
          :root { color-scheme: \(dark ? "dark" : "light"); }
          body { margin: 0; font: -apple-system-body; font-family: -apple-system, system-ui; color: \(fg); word-wrap: break-word; -webkit-text-size-adjust: 100%; }
          img, table { max-width: 100% !important; height: auto; }
          a { color: \(link); }
          blockquote { border-left: 3px solid #9A9CA2; margin: 0; padding-left: 12px; color: #75787F; }
        </style></head><body>\(html)</body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: HTMLView
        var loadedKey: String?
        init(_ parent: HTMLView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void)
        {
            // Only the initial loadHTMLString navigates in place. Every click
            // leaves through Safari — never in-app navigation (DESIGN.md).
            if action.navigationType == .other, action.request.url?.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme ?? "") {
                parent.onLink(url)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // allowsContentJavaScript only blocks the mail's own scripts; this
            // app-injected one still runs. Linkify, fold the quote, then measure.
            let script = Self.linkifyScript + Self.quoteScript(hide: !parent.showQuoted)
                + "[document.documentElement.scrollHeight, window.__pigeonQuote === true]"
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self, let r = result as? [Any], let h = r.first as? CGFloat, h > 0 else { return }
                let quote = r.last as? Bool ?? false
                DispatchQueue.main.async {
                    self.parent.height = h + 4
                    if quote { self.parent.hasQuote = true }
                }
            }
        }

        /// Finds the outermost trailing quote container (Outlook's reference
        /// container, div.gmail_quote, or a trailing <blockquote>) and hides
        /// it; sets window.__pigeonQuote when one exists. Never hides the
        /// whole mail: the quote must leave visible text before it. Same
        /// rules as desktop-app/src/lib/HtmlEmailFrame.svelte.
        static func quoteScript(hide: Bool) -> String {
            #"""
            (function () {
              var body = document.body;
              if (!body) return;
              function trailing(el) {
                var node = el;
                while (node && node !== body) {
                  for (var sib = node.nextSibling; sib; sib = sib.nextSibling) {
                    if (sib.textContent && sib.textContent.trim()) return false;
                    if (sib.nodeType === 1 && (/^(img|svg|hr)$/i.test(sib.tagName) || sib.querySelector("img,svg,hr"))) return false;
                  }
                  node = node.parentNode;
                }
                return node === body;
              }
              var c = [], bqs = body.querySelectorAll("blockquote");
              var o = body.querySelector('div[id="mail-editor-reference-message-container"]'); if (o) c.push(o);
              var g = body.querySelector("div.gmail_quote"); if (g) c.push(g);
              if (bqs.length) c.push(bqs[bqs.length - 1]);
              var q = null;
              for (var i = 0; i < c.length; i++) { if (trailing(c[i])) { q = c[i]; break; } }
              if (!q) return;
              var qt = q.innerText.trim(), bt = body.innerText.trim();
              if (!qt || bt.length <= qt.length) return;
              window.__pigeonQuote = true;
              // Gmail puts "On … wrote:" in .gmail_attr just before a bare blockquote.
              var attr = q.previousElementSibling;
              if (\#(hide ? "true" : "false")) {
                q.style.display = "none";
                if (attr && attr.classList.contains("gmail_attr")) attr.style.display = "none";
              }
            })();
            """#
        }

        /// Wraps URLs that the mail only wrote as text (outside any <a>) in
        /// links, so taps reach decidePolicyFor like any other link. Same
        /// rules as desktop-app/src/lib/linkify.ts: trailing sentence
        /// punctuation and an unbalanced ")" stay outside the link.
        static let linkifyScript = #"""
        (function () {
          var re = /\b(?:https?:\/\/|www\.)[^\s<>"'`]+/gi;
          function trim(u) {
            for (;;) {
              var c = u.charAt(u.length - 1);
              if (c && ".,;:!?*_~]}".indexOf(c) >= 0) u = u.slice(0, -1);
              else if (c === ")" && u.split("(").length <= u.split(")").length - 1) u = u.slice(0, -1);
              else return u;
            }
          }
          if (!document.body) return;
          var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), nodes = [], n;
          while ((n = w.nextNode())) {
            if (/https?:\/\/|www\./i.test(n.nodeValue) && !(n.parentElement && n.parentElement.closest("a,style,title,textarea"))) nodes.push(n);
          }
          nodes.forEach(function (node) {
            var text = node.nodeValue, frag = document.createDocumentFragment(), pos = 0, m, found = false;
            re.lastIndex = 0;
            while ((m = re.exec(text))) {
              var url = trim(m[0]);
              if (url.length < 5 || url.toLowerCase() === "www.") continue;
              if (m.index > pos) frag.appendChild(document.createTextNode(text.slice(pos, m.index)));
              var a = document.createElement("a");
              a.href = /^www\./i.test(url) ? "https://" + url : url;
              a.textContent = url;
              frag.appendChild(a);
              pos = m.index + url.length;
              re.lastIndex = pos;
              found = true;
            }
            if (!found) return;
            if (pos < text.length) frag.appendChild(document.createTextNode(text.slice(pos)));
            node.parentNode.replaceChild(frag, node);
          });
        })();
        """#
    }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        // mailto: can't open in Safari VC; hand it to the system instead.
        if url.scheme == "mailto" {
            UIApplication.shared.open(url)
            return SFSafariViewController(url: URL(string: "about:blank")!)
        }
        return SFSafariViewController(url: url)
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
