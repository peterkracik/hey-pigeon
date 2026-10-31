// Untrusted mail HTML, rendered as safely as a WKWebView allows:
// JavaScript off, strict CSP, remote images blocked until the user allows
// the sender, every web link handed to the default browser and every
// mailto: link to the app's own composer. The HTML arrives already sanitized by the core
// (ammonia); this is the second layer.
//
// Two native views back it: the plain-text body is a selectable text view
// (UITextView on iOS, NSTextView on the Mac) and the HTML a WKWebView, each
// wrapped for SwiftUI by the platform's representable. The rules — CSP, the
// link policy, the injected scripts — are the same on both and live in the
// platform-neutral parts of `HTMLView`.

import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct MessageBodyView: View {
    let html: String?
    let text: String
    let senderAddress: String
    @AppStorage("allowedImageSenders") private var allowedSendersRaw = ""
    @State private var height: CGFloat = 80
    /// The trailing quoted history ("On … wrote:") stays folded behind a
    /// ••• button, like the desktop's quote pill.
    @State private var showQuoted = false
    @State private var hasQuote = false
    @Environment(\.colorScheme) private var scheme
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    private var imagesAllowed: Bool {
        allowedSendersRaw.split(separator: "\n").contains(Substring(senderAddress.lowercased()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let html, !html.isEmpty {
                // A plain case-insensitive scan: the locale-aware variant was
                // far slower on long newsletters, on every render.
                if !imagesAllowed && html.range(of: "<img", options: .caseInsensitive) != nil {
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
                         height: $height, hasQuote: $hasQuote) { url in open(url) }
                    .frame(height: height)
                if hasQuote && !showQuoted { quoteButton }
            } else if let split = Self.splitQuoted(text) {
                SelectableText(text: Self.linkified(split.main)) { url in open(url) }
                if showQuoted {
                    SelectableText(text: Self.linkified(split.quoted, style: .subheadline, color: Theme.textSecondary)) { url in open(url) }
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.separator).frame(width: 2) }
                } else {
                    quoteButton
                }
            } else {
                // A UITextView, not Text + .textSelection: on iOS that only
                // copies the whole body, with no range selection or the
                // system edit menu (Look Up, Translate, Share…).
                SelectableText(text: Self.linkified(text)) { url in open(url) }
            }
        }
    }

    /// Web links leave the app for the user's default browser. A mailto:
    /// link is a mail client's own job: it opens this app's composer, prefilled, never
    /// Apple Mail — and never bounces through the system, which, with Hey
    /// Pigeon as the default mail app, would only come straight back here.
    private func open(_ url: URL) {
        if url.scheme?.lowercased() == "mailto" {
            model.compose(SendDraft(mailto: url))
        } else {
            openURL(url)
        }
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
    nonisolated static func splitQuoted(_ text: String) -> (main: String, quoted: String)? {
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
    private static func linkified(_ text: String, style: PlatformFont.TextStyle = .body,
                                  color: Color = Theme.textPrimary) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: [
            .font: PlatformFont.preferredFont(forTextStyle: style),
            .foregroundColor: PlatformColor(color),
        ])
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return out }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, ["http", "https", "mailto"].contains(url.scheme ?? "") else { continue }
            out.addAttribute(.link, value: url, range: match.range)
        }
        return out
    }
}

// MARK: - Selectable plain text

#if canImport(UIKit)
/// Read-only, selectable plain-text body: long-press or double-tap selects a
/// range and brings up the native edit menu. Link taps go to `onLink` (the
/// default browser, same as HTML mail).
private struct SelectableText: UIViewRepresentable {
    let text: NSAttributedString
    let onLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLink: onLink) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.dataDetectorTypes = []
        view.linkTextAttributes = [
            .foregroundColor: UIColor(Theme.textPrimary),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onLink = onLink
        // Only on a real change: re-assigning drops the user's selection.
        guard context.coordinator.shown != text else { return }
        context.coordinator.shown = text
        view.attributedText = text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        // UIScreen.main is deprecated (and meaningless with several
        // windows on iPad); the view's own window is the fallback width.
        // A width is almost always proposed; 320 pt is the narrowest phone.
        let width = proposal.width ?? uiView.window?.bounds.width ?? 320
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fit.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onLink: (URL) -> Void
        var shown: NSAttributedString?
        init(onLink: @escaping (URL) -> Void) { self.onLink = onLink }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction?
        {
            guard case let .link(url) = textItem.content else { return defaultAction }
            return UIAction { [onLink] _ in onLink(url) }
        }
    }
}
#else
/// The Mac twin: an NSTextView that is as tall as its text, selectable,
/// with the system's Look Up / Translate / Share on the selection. Link
/// clicks go to `onLink`, like the HTML view's.
private struct SelectableText: NSViewRepresentable {
    let text: NSAttributedString
    let onLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLink: onLink) }

    func makeNSView(context: Context) -> NSTextView {
        // TextKit 1 on purpose: the height measurement below reads the
        // layout manager, which a TextKit 2 view only has after a fallback.
        let view = NSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isAutomaticLinkDetectionEnabled = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.linkTextAttributes = [
            .foregroundColor: NSColor(Theme.textPrimary),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.onLink = onLink
        // Only on a real change: re-assigning drops the user's selection.
        guard context.coordinator.shown != text else { return }
        context.coordinator.shown = text
        view.textStorage?.setAttributedString(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.window?.frame.width ?? 480
        guard let container = nsView.textContainer, let manager = nsView.layoutManager else { return nil }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        return CGSize(width: width, height: ceil(used.height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onLink: (URL) -> Void
        var shown: NSAttributedString?
        init(onLink: @escaping (URL) -> Void) { self.onLink = onLink }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
            guard let url else { return false }
            onLink(url)
            return true
        }
    }
}
#endif

// MARK: - HTML

/// The HTML body in a WKWebView. The representable conformance is per
/// platform (below); the configuration, the wrapping document, the
/// navigation policy and the injected scripts are shared. Main-actor
/// like a representable declared with its conformance: the nested
/// Coordinator inherits it, and its completion closures may then touch
/// the bindings on the main queue (Swift 6 refused the hop otherwise).
@MainActor
private struct HTMLView {
    let html: String
    let allowRemoteImages: Bool
    let dark: Bool
    let showQuoted: Bool
    @Binding var height: CGFloat
    @Binding var hasQuote: Bool
    let onLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// JavaScript off for the mail's own scripts (the app's measuring
    /// script still runs: `didFinish` injects it).
    fileprivate func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        #if canImport(UIKit)
        // URLs written as plain text are linkified in didFinish instead of by
        // the .link detector: its taps arrive as x-apple-data-detectors: URLs,
        // which the navigation policy below cancels, so they never opened.
        config.dataDetectorTypes = [.phoneNumber]
        #endif
        return config
    }

    /// Load the wrapped document when something it depends on changed.
    fileprivate func update(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.parent = self
        let key = "\(allowRemoteImages)-\(dark)-\(showQuoted)-\(html.hashValue)"
        guard coordinator.loadedKey != key else { return }
        coordinator.loadedKey = key
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
          /* Some mail turns selection off; the user can always select and copy. */
          body, body * { -webkit-user-select: text !important; user-select: text !important; -webkit-touch-callout: default !important; }
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
            // leaves for the default browser — never in-app navigation (DESIGN.md).
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
              if (bqs.length) {
                // The last blockquote is the innermost of a nested history;
                // fold from the outermost one around it.
                var bq = bqs[bqs.length - 1], up;
                while ((up = bq.parentElement && bq.parentElement.closest("blockquote"))) bq = up;
                c.push(bq);
              }
              var q = null;
              for (var i = 0; i < c.length; i++) { if (trailing(c[i])) { q = c[i]; break; } }
              if (!q) return;
              var qt = q.innerText.trim(), bt = body.innerText.trim();
              if (!qt || bt.length <= qt.length) return;
              window.__pigeonQuote = true;
              if (!\#(hide ? "true" : "false")) return;
              q.style.display = "none";
              // The "On … wrote:" line just before the quote (.gmail_attr, a
              // <div>, or bare text with <br>s) folds with it.
              for (var p = q.previousSibling; p; p = p.previousSibling) {
                var t = (p.textContent || "").trim();
                if (p.nodeType === 1 && /^br$/i.test(p.tagName)) continue;
                if (!t) continue;
                if (t.length < 400 && /wrote:$|napísal\(a\):$|napísal:$|schrieb:$|a écrit :$/i.test(t)) {
                  if (p.nodeType === 1) p.style.display = "none";
                  else { var s = document.createElement("span"); s.style.display = "none"; p.parentNode.replaceChild(s, p); s.appendChild(p); }
                }
                break;
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

#if canImport(UIKit)
extension HTMLView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: configuration())
        web.navigationDelegate = context.coordinator
        web.scrollView.isScrollEnabled = false
        web.isOpaque = false
        web.backgroundColor = .clear
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        update(web, coordinator: context.coordinator)
    }
}
#else
extension HTMLView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let web = PassthroughWebView(frame: .zero, configuration: configuration())
        web.navigationDelegate = context.coordinator
        // Transparent, so the message card's colour shows through as on iOS.
        web.setValue(false, forKey: "drawsBackground")
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        update(web, coordinator: context.coordinator)
    }
}

/// A web view that never scrolls itself: it is as tall as its content, and
/// the wheel belongs to the thread's scroll view around it — a plain
/// WKWebView swallows scroll events over the message and the thread stops
/// moving wherever the pointer rests on a body.
private final class PassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}
#endif
