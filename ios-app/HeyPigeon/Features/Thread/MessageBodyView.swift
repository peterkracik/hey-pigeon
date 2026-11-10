// Untrusted mail HTML, rendered as safely as a WKWebView allows:
// JavaScript off, strict CSP, remote images blocked until the user allows
// one message or always for the sender (or turns on Settings › Load
// remote images), inline `cid:`
// pictures fetched from Gmail and inlined as data: URIs, every web link handed to the default browser and every
// mailto: link to the app's own composer. The HTML arrives sanitized by the core
// (desktop-app/crates/core/src/sanitize.rs: scripts, handlers, forms and frames removed;
// links, pictures and layout kept); this view is the second layer.
//
// Two native views back it: the plain-text body is a selectable text view
// (UITextView on iOS, NSTextView on the Mac) and the HTML a WKWebView, each
// wrapped for SwiftUI by the platform's representable. The rules — CSP, the
// link policy, the injected scripts — are the same on both and live in the
// platform-neutral parts of `HTMLView`.
//
// Both report the user's text selection (the native view through its
// delegate, the web view through an app user script, which runs with the
// mail's own scripts off): for a received message with an AI provider
// configured, a translate circle follows the selection and opens the
// translation beside it (TranslationPanel.swift).

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
    /// The message's parts with a Content-ID: the pictures its HTML shows
    /// as `cid:` (a signature logo). Fetched from Gmail and inlined as
    /// `data:` URIs, which the CSP allows; a web view cannot load `cid:`.
    var inlineImages: [AttachmentItem] = []
    /// Whether a selection offers the translate circle (received mail; the
    /// circle also needs an AI provider that can answer).
    var translatable = false
    /// The HTML with its `cid:` pictures inlined, once they are here.
    @State private var inlinedHTML: String?
    /// The selection in one of the body's views, while there is one.
    @State private var selection: PartSelection?
    /// The translation the panel shows, anchored where the selection was.
    @State private var translation: TranslationRequest?
    /// "Load": this message's web pictures, this time only.
    @State private var loadOnce = false
    @State private var height: CGFloat = 80
    /// The trailing quoted history ("On … wrote:") stays folded behind a
    /// ••• button, like the desktop's quote pill.
    @State private var showQuoted = false
    @State private var hasQuote = false
    /// What a render needs to know about the HTML, worked out once per body.
    @State private var facts = BodyFacts()
    @Environment(\.colorScheme) private var scheme
    @Environment(AppModel.self) private var model

    private var imagesAllowed: Bool {
        loadOnce || model.loadsImages(from: senderAddress)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let html, !html.isEmpty {
                // A plain case-insensitive scan: the locale-aware variant was
                // far slower on long newsletters, on every render.
                // Only remote pictures are held back: inline (cid:) ones are
                // part of the message and show without asking.
                let known = facts.of(html)
                if !imagesAllowed && known.hasRemoteImages {
                    HStack(spacing: 6) {
                        Text("Images hidden").font(.caption).foregroundStyle(Theme.textTertiary)
                        Spacer()
                        imageButton("Load") { loadOnce = true }
                            .accessibilityLabel("Load images in this message")
                        imageButton("Always for this sender") { model.alwaysLoadImages(from: senderAddress) }
                            .accessibilityLabel("Always load images from \(senderAddress)")
                    }
                }
                HTMLView(html: inlinedHTML ?? html, allowRemoteImages: imagesAllowed, dark: scheme == .dark, showQuoted: showQuoted,
                         height: $height, hasQuote: $hasQuote, onLink: { url in open(url) },
                         onSelection: { select($0, in: .html) })
                    .frame(height: height)
                    .translatable(.html, selection: selection, translation: $translation, enabled: offersTranslation)
                    .task(id: InlineImages.taskKey(hash: known.hash, images: inlineImages)) { await inlinePictures(html) }
                if hasQuote && !showQuoted { quoteButton }
            } else if let split = Self.splitQuoted(text) {
                SelectableText(text: Self.linkified(split.main), onLink: { url in open(url) },
                               onSelection: { select($0, in: .main) })
                    .translatable(.main, selection: selection, translation: $translation, enabled: offersTranslation)
                if showQuoted {
                    SelectableText(text: Self.linkified(split.quoted, style: .subheadline, color: Theme.textSecondary),
                                   onLink: { url in open(url) }, onSelection: { select($0, in: .quoted) })
                        .translatable(.quoted, selection: selection, translation: $translation, enabled: offersTranslation)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.separator).frame(width: 2) }
                } else {
                    quoteButton
                }
            } else {
                // A UITextView, not Text + .textSelection: on iOS that only
                // copies the whole body, with no range selection or the
                // system edit menu (Look Up, Translate, Share…).
                SelectableText(text: Self.linkified(text), onLink: { url in open(url) },
                               onSelection: { select($0, in: .main) })
                    .translatable(.main, selection: selection, translation: $translation, enabled: offersTranslation)
            }
        }
    }

    /// The translate circle needs received mail and a provider that answers
    /// (Settings › AI); without one the selection stays the system's alone.
    private var offersTranslation: Bool { translatable && model.aiConfigured }

    /// A view's selection changed. Only the view that holds the selection
    /// may clear it: the views report in no fixed order when the selection
    /// moves from one to another, and a late "nothing selected" from the
    /// old view must not take the new selection's circle away.
    private func select(_ s: BodySelection?, in part: BodyPart) {
        let next: PartSelection?
        if let s, s.isUsable { next = PartSelection(part: part, selection: s) }
        else if selection?.part == part { next = nil }
        else { return }
        guard next != selection else { return }
        withAnimation(.snappy(duration: 0.2)) { selection = next }
    }

    /// Fetch the pictures the HTML refers to by `cid:` (cached after the
    /// first time) and swap them in. A picture that cannot be fetched
    /// stays a broken image, as before; the rest still show.
    private func inlinePictures(_ html: String) async {
        let wanted = InlineImages.references(in: html)
        let parts = inlineImages.filter { a in
            a.isImage && a.size <= InlineImages.maxBytes
                && a.contentId.map { wanted.contains(InlineImages.normalize($0)) } == true
        }
        guard !parts.isEmpty else { return }
        var uris: [String: String] = [:]
        for a in parts {
            guard let id = a.contentId,
                  let file = try? await model.engine.attachmentFile(a),
                  let data = try? Data(contentsOf: file), data.count <= InlineImages.maxBytes
            else { continue }
            uris[InlineImages.normalize(id)] = "data:\(a.mimeType);base64,\(data.base64EncodedString())"
        }
        guard !Task.isCancelled, !uris.isEmpty else { return }
        inlinedHTML = InlineImages.inlined(html, dataURIs: uris)
    }

    /// Web links leave the app for the user's default browser. A mailto:
    /// link is a mail client's own job: it opens this app's composer, prefilled, never
    /// Apple Mail — and never bounces through the system, which, with Hey
    /// Pigeon as the default mail app, would only come straight back here.
    private func open(_ url: URL) {
        if url.scheme?.lowercased() == "mailto" {
            model.compose(SendDraft(mailto: url))
        } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            Browser.open(url)
        }
    }

    private func imageButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .buttonStyle(.plain)
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

    /// The plain-text fold: what was written and the trailing quote
    /// (QuotedText.split, which the thread transcript shares).
    nonisolated static func splitQuoted(_ text: String) -> (main: String, quoted: String)? {
        QuotedText.split(text)
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

/// Whether a body shows web pictures, and its hash for the inline-picture
/// task: both scan the whole HTML, and a body renders many times (a
/// selection moving, a picture arriving, the thread reloading) without
/// its HTML changing. Kept in view state, by reference: reading it is not
/// a change the view observes.
@MainActor
private final class BodyFacts {
    private var html: String?
    private var value: (hasRemoteImages: Bool, hash: Int) = (false, 0)

    func of(_ html: String) -> (hasRemoteImages: Bool, hash: Int) {
        // String equality answers at once for the same storage.
        if self.html != html {
            self.html = html
            value = (InlineImages.hasRemoteImages(html), html.hashValue)
        }
        return value
    }
}

// MARK: - Selection → translate

/// Which of the body's views a selection, or the translation it opened, is in.
private enum BodyPart: Hashable {
    case html, main, quoted
}

/// The selection and the view it is in.
private struct PartSelection: Equatable {
    let part: BodyPart
    let selection: BodySelection
}

/// What the translation panel shows and where it points.
private struct TranslationRequest: Identifiable {
    let id = UUID()
    let part: BodyPart
    let text: String
    /// The selection's rect in `part`'s coordinates: the popover's anchor.
    let anchor: CGRect
}

private extension View {
    /// The translate circle beside this view's selection, and the panel it
    /// opens, anchored to the selection. Every body view gets one; only the
    /// one whose part holds the selection (or the open request) shows
    /// anything, so a second view never presents the same panel again.
    func translatable(_ part: BodyPart, selection: PartSelection?, translation: Binding<TranslationRequest?>,
                      enabled: Bool) -> some View {
        modifier(SelectionTranslation(part: part, selection: selection?.part == part ? selection?.selection : nil,
                                      translation: translation, enabled: enabled))
    }
}

private struct SelectionTranslation: ViewModifier {
    let part: BodyPart
    let selection: BodySelection?
    @Binding var translation: TranslationRequest?
    let enabled: Bool

    /// This part's request, or nil: the popover of another part stays shut.
    private var shown: Binding<TranslationRequest?> {
        Binding(
            get: { translation?.part == part ? translation : nil },
            set: { if $0 == nil, translation?.part == part { translation = nil } }
        )
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                if enabled, let selection {
                    // The reader gives the view's width for the placement; it
                    // has no body of its own, so taps outside the circle still
                    // reach the text under it.
                    GeometryReader { geo in
                        TranslateBadge {
                            translation = TranslationRequest(part: part, text: selection.text, anchor: selection.rect)
                        }
                        .position(SelectionBadgeGeometry.center(for: selection, width: geo.size.width))
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .popover(item: shown, attachmentAnchor: .rect(.rect(translation?.anchor ?? .zero))) { request in
                TranslationPanel(text: request.text)
            }
    }
}

// MARK: - Selectable plain text

#if canImport(UIKit)
/// Read-only, selectable plain-text body: long-press or double-tap selects a
/// range and brings up the native edit menu. Link taps go to `onLink` (the
/// default browser, same as HTML mail); the selection, with where it ends,
/// to `onSelection` (nil once nothing is selected).
private struct SelectableText: UIViewRepresentable {
    let text: NSAttributedString
    let onLink: (URL) -> Void
    var onSelection: ((BodySelection?) -> Void)? = nil

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
        context.coordinator.onSelection = onSelection
        // Only on a real change: re-assigning drops the user's selection.
        guard context.coordinator.shown != text else { return }
        context.coordinator.shown = text
        // The reset's selection callback would write view state from inside
        // this update; nothing is selected after it anyway.
        context.coordinator.onSelection = nil
        view.attributedText = text
        context.coordinator.onSelection = onSelection
    }

    /// The selected range as `BodySelection`: the union of its line rects
    /// and the trailing edge of its last line (where the end handle sits),
    /// in the text view's coordinates — the view does not scroll, so those
    /// are the representable's. Nil when nothing is selected.
    static func selection(in view: UITextView) -> BodySelection? {
        guard let range = view.selectedTextRange, !range.isEmpty, let text = view.text(in: range) else { return nil }
        // Zero-size rects mark the handles' ends; the lines are the rest.
        let rects = view.selectionRects(for: range).map(\.rect).filter { $0.width > 0 && $0.height > 0 }
        guard var union = rects.first else { return nil }
        var last = union
        for r in rects.dropFirst() {
            union = union.union(r)
            if r.maxY > last.maxY || (r.maxY == last.maxY && r.maxX > last.maxX) { last = r }
        }
        return BodySelection(text: text, rect: union, end: CGPoint(x: last.maxX, y: last.midY), lineHeight: last.height)
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
        var onSelection: ((BodySelection?) -> Void)?
        var shown: NSAttributedString?
        init(onLink: @escaping (URL) -> Void) { self.onLink = onLink }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction?
        {
            guard case let .link(url) = textItem.content else { return defaultAction }
            return UIAction { [onLink] _ in onLink(url) }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            onSelection?(SelectableText.selection(in: textView))
        }
    }
}
#else
/// The Mac twin: an NSTextView that is as tall as its text, selectable,
/// with the system's Look Up / Translate / Share on the selection. Link
/// clicks go to `onLink`, like the HTML view's; the selection to
/// `onSelection`, as on iOS.
private struct SelectableText: NSViewRepresentable {
    let text: NSAttributedString
    let onLink: (URL) -> Void
    var onSelection: ((BodySelection?) -> Void)? = nil

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
        context.coordinator.onSelection = onSelection
        // Only on a real change: re-assigning drops the user's selection.
        guard context.coordinator.shown != text else { return }
        context.coordinator.shown = text
        // As on iOS: no selection callback from inside this update.
        context.coordinator.onSelection = nil
        view.textStorage?.setAttributedString(text)
        context.coordinator.onSelection = onSelection
    }

    /// The selected range as `BodySelection`, from the TextKit 1 layout
    /// manager the view was made with: the glyphs' bounding rect and the
    /// last glyph's trailing edge, moved by the container origin into the
    /// view's (flipped, top-left) coordinates. Nil when nothing is selected.
    static func selection(in view: NSTextView) -> BodySelection? {
        let range = view.selectedRange()
        guard range.length > 0, let manager = view.layoutManager, let container = view.textContainer else { return nil }
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let origin = view.textContainerOrigin
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
        let last = manager.boundingRect(forGlyphRange: NSRange(location: glyphs.upperBound - 1, length: 1), in: container)
            .offsetBy(dx: origin.x, dy: origin.y)
        let text = (view.string as NSString).substring(with: range)
        return BodySelection(text: text, rect: rect, end: CGPoint(x: last.maxX, y: last.midY), lineHeight: max(last.height, 1))
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
        var onSelection: ((BodySelection?) -> Void)?
        var shown: NSAttributedString?
        init(onLink: @escaping (URL) -> Void) { self.onLink = onLink }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
            guard let url else { return false }
            onLink(url)
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            onSelection?(SelectableText.selection(in: view))
        }
    }
}
#endif

// MARK: - Inline pictures

/// The `cid:` pictures of an HTML body: which ones it refers to, and the
/// body with them swapped for `data:` URIs. Pure, so it is tested.
enum InlineImages {
    /// Bigger inline parts are left alone: a data URI that size makes the
    /// web view crawl, and no signature is that big.
    static let maxBytes = 5_000_000

    // NSRegularExpression is immutable and safe to share across threads.
    nonisolated(unsafe) private static let cid = try? NSRegularExpression(pattern: #"cid:([^"'\s)>]+)"#, options: .caseInsensitive)
    nonisolated(unsafe) private static let remote = try? NSRegularExpression(
        pattern: #"<img\b[^>]*\bsrc\s*=\s*["']?\s*(https?:|//)"#, options: .caseInsensitive)

    /// Content-IDs compare case-insensitively and may be percent-encoded
    /// in the src (`image001.png%4001DB…`).
    static func normalize(_ id: String) -> String {
        (id.removingPercentEncoding ?? id).lowercased()
    }

    static func references(in html: String) -> Set<String> {
        guard let cid else { return [] }
        let ns = html as NSString
        return Set(cid.matches(in: html, range: NSRange(location: 0, length: ns.length)).map {
            normalize(ns.substring(with: $0.range(at: 1)))
        })
    }

    /// Each `cid:<id>` with a picture in `dataURIs` (keyed by the
    /// normalized id) becomes that URI; the others stay as they were.
    static func inlined(_ html: String, dataURIs: [String: String]) -> String {
        guard let cid, !dataURIs.isEmpty else { return html }
        let out = NSMutableString(string: html)
        for m in cid.matches(in: html, range: NSRange(location: 0, length: out.length)).reversed() {
            let id = normalize(out.substring(with: m.range(at: 1)))
            if let uri = dataURIs[id] { out.replaceCharacters(in: m.range, with: uri) }
        }
        return out as String
    }

    /// Whether the body shows a picture from the web (what "Load" is for).
    static func hasRemoteImages(_ html: String) -> Bool {
        guard let remote else { return false }
        return remote.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length)) != nil
    }

    /// Re-run the fetch when the body or its parts change, not on every render.
    static func taskKey(hash: Int, images: [AttachmentItem]) -> String {
        "\(hash)|" + images.map(\.id).joined(separator: ",")
    }

    /// Whether the body shows this part inline, so its chip is redundant.
    static func isShownInline(_ a: AttachmentItem, in html: String?) -> Bool {
        guard let html, let id = a.contentId else { return false }
        return references(in: html).contains(normalize(id))
    }
}

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
    /// The selection in the page, with where it ends, as the user script
    /// reports it; nil once nothing is selected.
    var onSelection: ((BodySelection?) -> Void)? = nil

    /// The message handler the selection script posts to.
    fileprivate static let selectionHandler = "pigeonSelection"
    /// The message handler the height script posts to.
    fileprivate static let heightHandler = "pigeonHeight"

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// JavaScript off for the mail's own scripts (the app's measuring
    /// script still runs: `didFinish` injects it, and the selection user
    /// script below is the app's too — `allowsContentJavaScript` only turns
    /// off what the page brought).
    fileprivate func configuration(coordinator: Coordinator) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        #if canImport(UIKit)
        // URLs written as plain text are linkified in didFinish instead of by
        // the .link detector: its taps arrive as x-apple-data-detectors: URLs,
        // which the navigation policy below cancels, so they never opened.
        config.dataDetectorTypes = [.phoneNumber]
        #endif
        config.userContentController.add(coordinator, name: Self.selectionHandler)
        config.userContentController.addUserScript(
            WKUserScript(source: Coordinator.selectionScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.add(coordinator, name: Self.heightHandler)
        config.userContentController.addUserScript(
            WKUserScript(source: Coordinator.heightScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        return config
    }

    /// The content controller keeps a strong reference to its handlers;
    /// let it go with the view.
    fileprivate static func tearDown(_ web: WKWebView) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: selectionHandler)
        web.configuration.userContentController.removeScriptMessageHandler(forName: heightHandler)
    }

    /// Load the wrapped document when something it depends on changed.
    fileprivate func update(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.parent = self
        // Compared as strings (the same storage answers at once): the key
        // used to hash the whole HTML on every update of the view.
        let loaded = coordinator.loaded
        if let loaded, loaded.images == allowRemoteImages, loaded.dark == dark, loaded.html == html {
            // Only the quote's fold moved: shown or hidden in the page that
            // is already there (a reload redrew the message and lost the
            // selection); the height script reports the new height.
            if coordinator.quoteShown != showQuoted {
                coordinator.quoteShown = showQuoted
                web.evaluateJavaScript(Coordinator.quoteToggleScript(show: showQuoted), completionHandler: nil)
            }
            return
        }
        let reload = loaded != nil
        coordinator.loaded = (html, allowRemoteImages, dark)
        coordinator.quoteShown = showQuoted
        web.loadHTMLString(wrapped, baseURL: nil)
        // A reloaded document has no selection, and its script only reports
        // changes, so say so here. Deferred: the callback writes view state,
        // and this runs inside an update.
        if reload, onSelection != nil {
            DispatchQueue.main.async { coordinator.parent.onSelection?(nil) }
        }
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

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: HTMLView
        /// What the page on screen was loaded from.
        var loaded: (html: String, images: Bool, dark: Bool)?
        /// Whether that page shows its trailing quote.
        var quoteShown = false
        init(_ parent: HTMLView) { self.parent = parent }

        /// The selection script's report (a dictionary while something is
        /// selected, null once nothing is), or the height script's: how
        /// tall the view must be to show the whole message.
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case HTMLView.selectionHandler:
                parent.onSelection?(BodySelection(message: message.body as? [String: Any]))
            case HTMLView.heightHandler:
                guard let value = message.body as? NSNumber else { return }
                let height = CGFloat(truncating: value)
                guard height > 0, abs(height - parent.height) >= 1 else { return }
                // Deferred: the callback writes view state.
                DispatchQueue.main.async { self.parent.height = height }
            default:
                break
            }
        }

        /// Reports how tall the message is whenever that changes: when the
        /// view gets wider or narrower (a Mac window resized, the sidebar
        /// shown, an iPad turned), when a picture arrives, when the quote
        /// is unfolded. The height used to be read once, when the page had
        /// finished loading: until its last picture was in, a message sat
        /// in a strip 80 points tall, and after a resize it was cut off or
        /// left a blank under itself. `window.__pigeonFrameHeight` is the
        /// same measure for `didFinish`. The fit is `fitScript`'s, run
        /// again before each measure.
        static let heightScript = #"""
        (function () {
          var d = document.documentElement, b = document.body;
          if (!b || window.__pigeonFrameHeight) return;
          var w = window.webkit, h = w && w.messageHandlers && w.messageHandlers.pigeonHeight;
          var PAD = 4;
          // A zero-height mark after the body, outside it: where the content ends,
          // whatever the body's zoom, and unlike scrollHeight not at least as tall
          // as the view, so a message can get shorter when the view gets wider.
          var end = document.createElement("div");
          end.style.cssText = "height:0;margin:0;padding:0;border:0;clear:both";
          d.appendChild(end);
          var width = -1, need = 0;
          function fit() {
            b.style.zoom = "";
            var cw = d.clientWidth, sw = Math.max(b.scrollWidth, d.scrollWidth);
            if (cw > 0 && sw > cw + 1) b.style.zoom = String(Math.max(cw / sw, 0.25));
          }
          window.__pigeonFrameHeight = function () {
            if (d.clientWidth !== width) { width = d.clientWidth; need = 0; }
            fit();
            var view = d.clientHeight, mark = Math.ceil(end.getBoundingClientRect().top + window.scrollY);
            // Content that overflows the view: scrollHeight is its real extent.
            if (d.scrollHeight > view + 1) need = Math.max(need, d.scrollHeight);
            // A body as tall as the view (height: 100%) follows the view: keep it.
            if (need <= view && Math.abs(mark - view) <= 1) return view;
            return Math.max(mark, need) + PAD;
          };
          if (!h) return;
          var last = -1, pending = false, sent = 0, sentWidth = -1;
          function report() {
            pending = false;
            var v = window.__pigeonFrameHeight();
            if (d.clientWidth !== sentWidth) { sentWidth = d.clientWidth; sent = 0; }
            if (v <= 0 || Math.abs(v - last) < 1 || sent >= 12) return;
            last = v; sent++;
            h.postMessage(v);
          }
          function schedule() { if (!pending) { pending = true; setTimeout(report, 30); } }
          if (window.ResizeObserver) new ResizeObserver(schedule).observe(b);
          window.addEventListener("resize", schedule);
          window.addEventListener("load", function () { sent = 0; schedule(); });
          schedule();
        })();
        """#

        /// Show or hide what `quoteScript` folded, in place.
        static func quoteToggleScript(show: Bool) -> String {
            let display = show ? "" : "none"
            return #"""
            (function () {
              var list = window.__pigeonFolded || [];
              for (var i = 0; i < list.length; i++) list[i].style.display = "\#(display)";
            })();
            """#
        }

        /// Posts the selection (its text, rect and the end of its last line,
        /// in page coordinates — the page is as tall as its content and never
        /// scrolls, so those are the view's) a moment after it settles, and
        /// null when it is gone. Only a change is posted: the event fires
        /// for every handle move.
        static let selectionScript = #"""
        (function () {
          var w = window.webkit, h = w && w.messageHandlers && w.messageHandlers.pigeonSelection;
          if (!h) return;
          var timer = null, last = "";
          function report() {
            timer = null;
            var sel = window.getSelection(), msg = null;
            if (sel && sel.rangeCount > 0 && !sel.isCollapsed) {
              var text = sel.toString();
              if (text.trim()) {
                var range = sel.getRangeAt(sel.rangeCount - 1), rect = range.getBoundingClientRect();
                var rects = range.getClientRects(), end = null;
                for (var i = rects.length - 1; i >= 0; i--) {
                  if (rects[i].width > 0 && rects[i].height > 0) { end = rects[i]; break; }
                }
                if (!end) end = rect;
                msg = { text: text, x: rect.left + window.scrollX, y: rect.top + window.scrollY, width: rect.width, height: rect.height,
                        endX: end.right + window.scrollX, endY: end.top + end.height / 2 + window.scrollY, lineHeight: end.height };
              }
            }
            var key = JSON.stringify(msg);
            if (key === last) return;
            last = key;
            h.postMessage(msg);
          }
          document.addEventListener("selectionchange", function () {
            if (timer) clearTimeout(timer);
            timer = setTimeout(report, 120);
          });
        })();
        """#

        /// The async form on purpose: the completion-handler one written
        /// without the SDK's `@MainActor @Sendable` on the handler only
        /// nearly matched the protocol (a warning, not an error), so WebKit
        /// never saw it and followed every link inside the message.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // Only the initial loadHTMLString navigates in place. Every click
            // leaves for the default browser — never in-app navigation (DESIGN.md).
            if action.navigationType == .other, action.request.url?.scheme == "about" {
                return .allow
            }
            if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                parent.onLink(url)
            }
            return .cancel
        }

        /// target="_blank" links ask for a new web view instead of
        /// navigating; without this they did nothing. Never a new view:
        /// the link goes the same way as any other tap.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView?
        {
            if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                parent.onLink(url)
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // allowsContentJavaScript only blocks the mail's own scripts; this
            // app-injected one still runs. Linkify, fold the quote, shrink a
            // too-wide layout to fit, then measure.
            let script = Self.linkifyScript + Self.quoteScript(hide: !parent.showQuoted) + Self.fitScript
                + "[window.__pigeonFrameHeight ? window.__pigeonFrameHeight() : document.documentElement.scrollHeight + 4,"
                + " window.__pigeonQuote === true]"
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self, let r = result as? [Any], let h = (r.first as? NSNumber).map({ CGFloat(truncating: $0) }), h > 0
                else { return }
                let quote = r.last as? Bool ?? false
                DispatchQueue.main.async {
                    self.parent.height = h
                    if quote { self.parent.hasQuote = true }
                }
            }
        }

        /// Newsletters and receipts are often laid out for a fixed 600–700 px
        /// column (table width attributes, inline px widths), which
        /// `max-width: 100%` cannot undo; the web view does not scroll, so the
        /// right side was cut off on a phone. Like Apple Mail, scale the whole
        /// body down until it fits the view's width. CSS zoom (not a
        /// transform) so the measured height shrinks with it.
        static let fitScript = #"""
        (function () {
          var b = document.body, d = document.documentElement;
          if (!b) return;
          b.style.zoom = "";
          var w = d.clientWidth, sw = Math.max(b.scrollWidth, d.scrollWidth);
          if (w > 0 && sw > w + 1) b.style.zoom = String(Math.max(w / sw, 0.25));
        })();
        """#

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
              // What folds, kept so the fold can be undone in place
              // (quoteToggleScript) instead of by loading the page again.
              var folded = window.__pigeonFolded = [q];
              var hide = \#(hide ? "true" : "false");
              if (hide) q.style.display = "none";
              // The "On … wrote:" line just before the quote (.gmail_attr, a
              // <div>, or bare text with <br>s) folds with it.
              for (var p = q.previousSibling; p; p = p.previousSibling) {
                var t = (p.textContent || "").trim();
                if (p.nodeType === 1 && /^br$/i.test(p.tagName)) continue;
                if (!t) continue;
                if (t.length < 400 && /wrote:$|napísal\(a\):$|napísal:$|schrieb:$|a écrit :$/i.test(t)) {
                  var line = p;
                  if (p.nodeType !== 1) { line = document.createElement("span"); p.parentNode.replaceChild(line, p); line.appendChild(p); }
                  if (hide) line.style.display = "none";
                  folded.push(line);
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
        let web = WKWebView(frame: .zero, configuration: configuration(coordinator: context.coordinator))
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        // A long press's preview, once tapped, loaded the page in place of
        // the message. The press still offers the system's link menu.
        web.allowsLinkPreview = false
        web.scrollView.isScrollEnabled = false
        web.isOpaque = false
        web.backgroundColor = .clear
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        update(web, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        tearDown(web)
    }
}
#else
extension HTMLView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let web = PassthroughWebView(frame: .zero, configuration: configuration(coordinator: context.coordinator))
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        // Transparent, so the message card's colour shows through as on iOS.
        web.setValue(false, forKey: "drawsBackground")
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        update(web, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        tearDown(web)
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
