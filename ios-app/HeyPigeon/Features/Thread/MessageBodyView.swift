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
                Text(text).font(.body).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
            }
        }
        .sheet(item: $link) { url in SafariView(url: url).ignoresSafeArea() }
    }
}

extension URL: Identifiable { public var id: String { absoluteString } }

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
        config.dataDetectorTypes = [.link, .phoneNumber]
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
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { [weak self] result, _ in
                guard let self, let h = result as? CGFloat, h > 0 else { return }
                DispatchQueue.main.async { self.parent.height = h + 4 }
            }
        }
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
