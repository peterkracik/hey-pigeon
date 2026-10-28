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
    @Environment(\.colorScheme) private var scheme

    private var imagesAllowed: Bool {
        allowedSendersRaw.split(separator: "\n").contains(Substring(senderAddress.lowercased()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let html, !html.isEmpty {
                if !imagesAllowed && html.localizedCaseInsensitiveContains("<img") {
                    HStack {
                        Label("Remote images blocked", systemImage: "photo").font(.caption).foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Button("Load from \(senderAddress)") {
                            allowedSendersRaw += "\n\(senderAddress.lowercased())"
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
                HTMLView(html: html, allowRemoteImages: imagesAllowed, dark: scheme == .dark, height: $height) { url in link = url }
                    .frame(height: height)
            } else {
                // A UITextView, not Text + .textSelection: on iOS that only
                // copies the whole body, with no range selection or the
                // system edit menu (Look Up, Translate, Share…).
                SelectableText(text: Self.linkified(text)) { url in link = url }
            }
        }
        .sheet(item: $link) { url in SafariView(url: url).ignoresSafeArea() }
    }

    /// Plain-text mail with every URL turned into a tappable, underlined link.
    private static func linkified(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor(Theme.textPrimary),
        ])
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return out }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, ["http", "https", "mailto"].contains(url.scheme ?? "") else { continue }
            out.addAttribute(.link, value: url, range: match.range)
        }
        return out
    }
}

extension URL: Identifiable { public var id: String { absoluteString } }

/// Read-only, selectable plain-text body: long-press or double-tap selects a
/// range and brings up the native edit menu. Link taps go to `onLink` (the
/// in-app Safari sheet, same as HTML mail), not the Safari app.
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
        let width = proposal.width ?? UIScreen.main.bounds.width
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

private struct HTMLView: UIViewRepresentable {
    let html: String
    let allowRemoteImages: Bool
    let dark: Bool
    @Binding var height: CGFloat
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
        let key = "\(allowRemoteImages)-\(dark)-\(html.hashValue)"
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
            // app-injected one still runs. Linkify first, then measure.
            webView.evaluateJavaScript(Self.linkifyScript + "document.documentElement.scrollHeight") { [weak self] result, _ in
                guard let self, let h = result as? CGFloat, h > 0 else { return }
                DispatchQueue.main.async { self.parent.height = h + 4 }
            }
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
