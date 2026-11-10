// The Mac half of the composer; the shared ComposeView keeps the draft's
// lifecycle (save, send, undo, Siri's copy) for both platforms and takes
// these parts on macOS. The body is an HTML editor in a web view, as the
// first desktop client's contenteditable was (desktop-app/src/lib/
// Composer.svelte): paragraphs with air between them, bullet and numbered
// lists, ⌘B · ⌘I · ⌘U · ⇧⌘X · ⌘K and ⇧⌘7 / ⇧⌘8 while typing, ⌘J for the
// AI, ⌘↩ to send. A reply shows the thread's messages above the draft, so
// the draft reads as the end of the conversation (Superhuman's shape;
// ComposeThreadHistory.swift, which the phone shows under its editor); a
// selection gets a floating toolbar; the footer's Aa opens a format bar
// with the same tools; and the AI is a panel under the text instead of a
// sheet — a line to describe the change, the presets as chips, the result
// to review before it replaces anything, and a Cancel that always works.
// The phone keeps its TextEditor and its AI sheet (ComposeView's iOS
// branches); this file compiles for macOS only.

#if os(macOS)
import AppKit
import SwiftUI
import WebKit

// MARK: - The editor's state

/// The body as the Mac editor holds it, and the composer's handle on the
/// web page: the html and text parts, the content's height, the selection
/// for the floating toolbar, the formats on at the caret, and the
/// commands the page runs. The page is the truth while the user types
/// (it reports every change); the composer writes to it only to replace
/// the body (a signature swap, an AI draft, Siri's edit).
@MainActor
@Observable
final class MacComposeEditor {
    /// The editor's document: the html part of the message.
    private(set) var html: String
    /// The same as plain text — paragraphs as blank lines, list items with
    /// their markers: the text part, what the AI reads, the draft check.
    private(set) var text: String
    /// The content's height, so the web view is as tall as the text and
    /// the composer's own scroll view does the scrolling.
    var height: CGFloat = MacComposeEditor.minHeight
    /// The selection while it is more than a caret: its text and its first
    /// line's rectangle in the editor's coordinates (the floating toolbar).
    /// Gone the moment the page loses the focus.
    var selection: Selection?
    /// The selection the AI works on: the last one the page reported,
    /// kept while the focus is in the AI panel's field or a toolbar (the
    /// page keeps the range too and restores it for the replacement);
    /// cleared when the caret is placed somewhere or the body is replaced.
    private(set) var savedSelection: Selection?
    /// The formats on at the caret or selection, by command name
    /// (`bold`, `insertUnorderedList`, …): the toolbars highlight them.
    var activeFormats: Set<String> = []
    /// The keys the page hands back to the composer: ⌘J (the AI panel),
    /// ⌘K (a link), ⌘↩ (send), Esc (close, keeping the draft).
    var onCommand: ((Command) -> Void)?
    /// Files dropped on the editor, or pasted into it from the Finder:
    /// the composer attaches them. Without it WebKit took the drop itself
    /// and wrote the file's path into the message.
    @ObservationIgnored var onFiles: (([URL]) -> Void)?
    /// A picture pasted with no text beside it (a screenshot, Copy Image),
    /// as PNG: the composer attaches it; the editor pastes only text.
    @ObservationIgnored var onPastedImage: ((Data) -> Void)?

    /// The web view's bridge, installed by `HTMLEditorView`.
    @ObservationIgnored fileprivate weak var bridge: EditorBridge?
    /// Scripts sent before the page was ready, run once it is.
    @ObservationIgnored fileprivate var pending: [String] = []
    /// Focus asked for before the page was ready.
    @ObservationIgnored fileprivate var wantsFocus = false

    static let minHeight: CGFloat = 280

    struct Selection: Equatable {
        let text: String
        let rect: CGRect
    }

    enum Command {
        case ai, link, send, escape
    }

    init(draft: SendDraft) {
        html = draft.bodyHTML ?? Self.html(fromText: draft.bodyText)
        text = draft.bodyText
    }

    // MARK: Content

    /// Plain text as the editor shows it: paragraphs (a blank line between
    /// them) become `<p>`s, single line breaks `<br>`; an empty paragraph
    /// keeps a `<br>` so it has a height to put the caret in.
    static func html(fromText text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { paragraph in
                let inner = paragraph.components(separatedBy: "\n").map(escape).joined(separator: "<br>")
                return inner.isEmpty ? "<p><br></p>" : "<p>\(inner)</p>"
            }
            .joined()
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The html part to send: nil while the body is empty, so an empty
    /// message goes out as text alone.
    var htmlPart: String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : html
    }

    /// Replace the whole body with plain text (a signature swap, an AI
    /// draft, Siri's edit).
    func setText(_ text: String) {
        set(html: Self.html(fromText: text), text: text)
    }

    /// Take a draft changed outside the editor (Siri's "update draft"):
    /// its text when that changed — the html beside it is the composer's
    /// own mirror from before the change — else its html.
    func set(draft: SendDraft) {
        if draft.bodyText != text {
            setText(draft.bodyText)
        } else if let h = draft.bodyHTML, h != html {
            set(html: h, text: draft.bodyText)
        }
    }

    private func set(html: String, text: String) {
        self.html = html
        self.text = text
        selection = nil
        savedSelection = nil
        run("pigeon.setHTML(\(Self.json(html)))")
    }

    /// The AI's result in place of the selection — as typing would, so ⌘Z
    /// takes it back.
    func replaceSelection(with text: String) {
        run("pigeon.insertText(\(Self.json(text)))")
    }

    /// A formatting command (`bold`, `insertUnorderedList`, `removeFormat`…)
    /// on the selection, or at the caret for what is typed next.
    func exec(_ command: String) {
        run("pigeon.exec(\(Self.json(command)))")
    }

    /// The selection becomes a link; with no selection the address is
    /// inserted as one.
    func createLink(_ url: URL) {
        run("pigeon.link(\(Self.json(url.absoluteString)))")
    }

    /// The caret into the editor (the page becomes the first responder).
    func focus() {
        if let bridge { bridge.focus() } else { wantsFocus = true }
    }

    fileprivate func run(_ script: String) {
        if let bridge, bridge.ready { bridge.evaluate(script) } else { pending.append(script) }
    }

    /// A message from the page (EditorBridge): a change, the height, the
    /// selection, a lost focus, or one of the keys the composer handles.
    func receive(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "change":
            if let h = message["html"] as? String { html = h }
            if let t = message["text"] as? String { text = t }
        case "height":
            if let h = message["value"] as? Double { height = max(Self.minHeight, CGFloat(h)) }
        case "selection":
            activeFormats = Set(message["formats"] as? [String] ?? [])
            if let text = message["text"] as? String, !text.isEmpty,
               let r = message["rect"] as? [String: Double],
               let x = r["x"], let y = r["y"], let w = r["w"], let h = r["h"] {
                selection = Selection(text: text, rect: CGRect(x: x, y: y, width: w, height: h))
                savedSelection = selection
            } else {
                selection = nil
                savedSelection = nil
            }
        case "blur":
            selection = nil
        case "command":
            switch message["name"] as? String {
            case "ai": onCommand?(.ai)
            case "link": onCommand?(.link)
            case "send": onCommand?(.send)
            case "escape": onCommand?(.escape)
            default: break
            }
        default:
            break
        }
    }

    /// A JavaScript string literal for `s` (JSON is one; the two line
    /// separators JSON allows raw are escaped for older parsers).
    static func json(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed),
              let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
        return literal.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}

// MARK: - The web view

/// The editor's web view for SwiftUI: as tall as `MacComposeEditor.height`
/// says, transparent, scrolled by the composer's scroll view. JavaScript is
/// on for the page's own script alone: the CSP names it by a nonce, so a
/// handler inside the content (a saved draft's html is loaded here, and
/// the core's sanitizer is the only other thing in its way) does not run.
/// The CSP also keeps everything but inline pictures out.
struct HTMLEditorView: NSViewRepresentable {
    let editor: MacComposeEditor
    let placeholder: String

    func makeCoordinator() -> EditorBridge { EditorBridge(editor) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "pigeon")
        let web = EditorWebView(frame: .zero, configuration: config)
        web.editor = editor
        web.navigationDelegate = context.coordinator
        // Transparent, so the composer's canvas shows through.
        web.setValue(false, forKey: "drawsBackground")
        context.coordinator.web = web
        editor.bridge = context.coordinator
        web.loadHTMLString(Self.document(placeholder: placeholder), baseURL: nil)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}

    static func dismantleNSView(_ web: WKWebView, coordinator: EditorBridge) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "pigeon")
        web.navigationDelegate = nil
    }

    /// The page: one contenteditable block with the app's type, the
    /// paragraph and list spacing the message gets in a mail client, and
    /// the script that talks to `EditorBridge`.
    static func document(placeholder: String) -> String {
        // A fresh nonce per page: `'unsafe-inline'` let any inline handler
        // in the content run next to the bridge that can send the mail.
        // What Swift evaluates is not subject to the page's policy.
        let nonce = UUID().uuidString
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-\(nonce)'; img-src data:; frame-src 'none'; form-action 'none'; base-uri 'none'">
        <style>\(style)</style></head>
        <body><div id="editor" contenteditable="true" spellcheck="true" data-placeholder="\(MacComposeEditor.escape(placeholder))"></div>
        <script nonce="\(nonce)">\(script)</script></body></html>
        """
    }

    private static let style = """
    :root { color-scheme: light dark; }
    html, body { margin: 0; padding: 0; background: transparent; }
    body { font: 14px/1.45 -apple-system, system-ui, sans-serif; color: #0D0D10; -webkit-font-smoothing: antialiased; }
    #editor { position: relative; min-height: 236px; padding: 14px 16px 30px; outline: none; word-wrap: break-word; }
    #editor.blank::before { content: attr(data-placeholder); position: absolute; left: 16px; top: 14px; color: #8E9096; pointer-events: none; }
    /* Two sizes of break: Return starts a paragraph, half a line of air
       under the one before; Shift-Return breaks the line inside it, with
       none. (A 1.6 line height and 0.75em of air put the next line a
       whole line and a half down.) */
    #editor p { margin: 0 0 0.5em; }
    #editor p:last-child { margin-bottom: 0; }
    #editor ul, #editor ol { margin: 0 0 0.5em; padding-left: 1.6em; }
    #editor li { margin: 0.1em 0; }
    #editor blockquote { border-left: 3px solid #9A9CA2; margin: 0 0 0.5em; padding-left: 12px; color: #75787F; }
    a { color: #33363E; }
    @media (prefers-color-scheme: dark) {
      body { color: #F7F7F8; }
      #editor.blank::before { color: #75787F; }
      a { color: #9A9CA2; }
    }
    """

    /// Paragraphs on Return (`<p>`, not `<div>`), a line break (`<br>`) on
    /// Shift-Return, tags for formatting (not
    /// styles), plain text on paste — the clipboard's html would ride into
    /// the message with its styles and trackers — and the keys: WebKit
    /// binds none of the editing shortcuts in a contenteditable, so ⌘B
    /// and the rest are wired here (the first desktop client did the
    /// same). Every change reports the html and a text rendering; every
    /// selection change the selection's rectangle and the formats on.
    private static let script = #"""
    (function () {
      var editor = document.getElementById('editor');
      function post(m) { try { window.webkit.messageHandlers.pigeon.postMessage(m); } catch (e) {} }
      document.execCommand('defaultParagraphSeparator', false, 'p');
      document.execCommand('styleWithCSS', false, 'false');
      var savedRange = null, lastHeight = 0;

      // The text part: paragraphs as blank lines, lists with their markers.
      function toText(root) {
        var out = '';
        function walk(n, prefix) {
          if (n.nodeType === 3) { out += n.nodeValue.replace(/\u00a0/g, ' '); return; }
          if (n.nodeType !== 1) return;
          var tag = n.tagName.toLowerCase(), k;
          if (tag === 'br') { out += '\n'; return; }
          if (tag === 'ul' || tag === 'ol') {
            var i = 0;
            for (var c = n.firstElementChild; c; c = c.nextElementSibling) {
              if (c.tagName.toLowerCase() !== 'li') continue;
              i++;
              out += prefix + (tag === 'ol' ? i + '. ' : '• ');
              for (k = c.firstChild; k; k = k.nextSibling) walk(k, prefix + '  ');
              if (!/\n$/.test(out)) out += '\n';
            }
            out += '\n';
            return;
          }
          for (k = n.firstChild; k; k = k.nextSibling) walk(k, prefix);
          if (tag === 'p') out += '\n\n';
          else if (tag === 'div' || tag === 'blockquote') out += '\n';
        }
        walk(root, '');
        return out.replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').replace(/\s+$/, '');
      }
      function placeholder() { editor.classList.toggle('blank', toText(editor).trim() === ''); }
      function reportHeight() {
        var h = Math.ceil(editor.getBoundingClientRect().height);
        if (h !== lastHeight) { lastHeight = h; post({ type: 'height', value: h }); }
      }
      function changed() {
        placeholder();
        post({ type: 'change', html: editor.innerHTML, text: toText(editor) });
        reportHeight();
      }
      function formats() {
        var names = ['bold', 'italic', 'underline', 'strikeThrough', 'insertUnorderedList', 'insertOrderedList'], on = [];
        for (var i = 0; i < names.length; i++) { try { if (document.queryCommandState(names[i])) on.push(names[i]); } catch (e) {} }
        return on;
      }
      function reportSelection() {
        var sel = window.getSelection();
        if (!sel || sel.rangeCount === 0 || !editor.contains(sel.anchorNode)) { post({ type: 'selection', text: '', formats: [] }); return; }
        var range = sel.getRangeAt(0);
        savedRange = range.cloneRange();
        if (sel.isCollapsed) { post({ type: 'selection', text: '', formats: formats() }); return; }
        var rects = range.getClientRects();
        var first = rects.length ? rects[0] : range.getBoundingClientRect();
        var box = range.getBoundingClientRect();
        post({ type: 'selection', text: sel.toString(), formats: formats(),
               rect: { x: first.left, y: first.top, w: box.width, h: first.height } });
      }
      // The toolbars and the AI panel take the focus for a moment: the
      // selection they act on is the one saved last.
      function restore() {
        editor.focus();
        if (savedRange) { var sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(savedRange); }
      }
      function run(cmd, value) {
        restore();
        document.execCommand(cmd, false, value === undefined ? null : value);
        changed();
        reportSelection();
      }
      window.pigeon = {
        setHTML: function (html) { editor.innerHTML = html; savedRange = null; placeholder(); reportHeight(); },
        // Blank lines would become empty paragraphs with air of their own;
        // one break per paragraph reads as the rest of the body does.
        insertText: function (text) { run('insertText', text.replace(/\r\n/g, '\n').replace(/\n{2,}/g, '\n')); },
        exec: function (cmd) { run(cmd); },
        link: function (url) {
          restore();
          var sel = window.getSelection();
          if (!sel || sel.isCollapsed) {
            var a = document.createElement('a');
            a.href = url; a.textContent = url;
            document.execCommand('insertHTML', false, a.outerHTML);
          } else {
            document.execCommand('createLink', false, url);
          }
          changed();
        },
        focus: function () { if (savedRange) restore(); else editor.focus(); }
      };
      editor.addEventListener('input', changed);
      document.addEventListener('selectionchange', reportSelection);
      editor.addEventListener('blur', function () { post({ type: 'blur' }); });
      editor.addEventListener('paste', function (ev) {
        ev.preventDefault();
        var text = ev.clipboardData ? ev.clipboardData.getData('text/plain') : '';
        if (text) document.execCommand('insertText', false, text);
      });
      editor.addEventListener('keydown', function (ev) {
        if (ev.key === 'Escape') { ev.preventDefault(); post({ type: 'command', name: 'escape' }); return; }
        // Shift-Return: a line break inside the paragraph, never a new
        // one (left to WebKit it depends on where the caret is).
        if (ev.key === 'Enter' && ev.shiftKey && !ev.metaKey && !ev.ctrlKey && !ev.altKey) {
          ev.preventDefault();
          document.execCommand('insertLineBreak', false, null);
          changed();
          return;
        }
        if (!ev.metaKey || ev.ctrlKey || ev.altKey) return;
        var k = ev.key.toLowerCase(), cmd = null;
        if (!ev.shiftKey) {
          if (k === 'b') cmd = 'bold';
          else if (k === 'i') cmd = 'italic';
          else if (k === 'u') cmd = 'underline';
          else if (k === 'k') { ev.preventDefault(); reportSelection(); post({ type: 'command', name: 'link' }); return; }
          else if (k === 'j') { ev.preventDefault(); reportSelection(); post({ type: 'command', name: 'ai' }); return; }
          else if (ev.key === 'Enter') { ev.preventDefault(); post({ type: 'command', name: 'send' }); return; }
        } else {
          if (k === 'x') cmd = 'strikeThrough';
          else if (ev.code === 'Digit8') cmd = 'insertUnorderedList';
          else if (ev.code === 'Digit7') cmd = 'insertOrderedList';
        }
        if (!cmd) return;
        ev.preventDefault();
        document.execCommand(cmd, false, null);
        changed();
        reportSelection();
      });
      if (window.ResizeObserver) new ResizeObserver(reportHeight).observe(editor);
      placeholder();
      reportHeight();
    })();
    """#
}

/// The page's bridge: scripts in, messages out. Holds the web view weakly
/// (the page's message handler holds this object).
@MainActor
final class EditorBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let editor: MacComposeEditor
    weak var web: WKWebView?
    private(set) var ready = false

    init(_ editor: MacComposeEditor) {
        self.editor = editor
    }

    func evaluate(_ script: String) {
        web?.evaluateJavaScript(script) { _, _ in }
    }

    func focus() {
        guard let web, ready else { editor.wantsFocus = true; return }
        web.window?.makeFirstResponder(web)
        evaluate("pigeon.focus()")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        editor.receive(body)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        // The content first, then whatever the composer asked for while
        // the page was loading.
        evaluate("pigeon.setHTML(\(MacComposeEditor.json(editor.html)))")
        for script in editor.pending { evaluate(script) }
        editor.pending = []
        if editor.wantsFocus {
            editor.wantsFocus = false
            focus()
        }
    }

    /// Only the page itself loads; a link clicked inside the editor goes
    /// nowhere (the composer is for writing it, not following it).
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.navigationType == .other && action.request.url?.scheme == "about" ? .allow : .cancel
    }
}

/// A web view that never scrolls itself: it is as tall as its content and
/// the wheel belongs to the composer's scroll view (MessageBodyView's
/// PassthroughWebView, for the same reason). Not private: the Mac
/// window's key map asks whether the first responder is this editor
/// (WindowState.isTyping).
final class EditorWebView: WKWebView {
    /// The composer's editor: what is dropped or pasted here as a file
    /// goes to it as an attachment.
    weak var editor: MacComposeEditor?

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    /// The files on a pasteboard (a drag from the Finder, a copied file).
    private static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    // A file dragged over the editor is an attachment, not content: the
    // editor's page would write its path (or load it in place of itself).
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        editor?.onFiles != nil && !Self.fileURLs(on: sender.draggingPasteboard).isEmpty ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        editor?.onFiles != nil && !Self.fileURLs(on: sender.draggingPasteboard).isEmpty ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(on: sender.draggingPasteboard)
        guard !urls.isEmpty, let onFiles = editor?.onFiles else { return super.performDragOperation(sender) }
        onFiles(urls)
        return true
    }

    /// ⌘V with a file or a bare picture on the clipboard attaches it; any
    /// other paste is the page's (plain text). Key equivalents reach every
    /// view of the window, so only while the editor is being typed in.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "v", window?.firstResponder === self, attachFromClipboard() {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func attachFromClipboard() -> Bool {
        guard let editor else { return false }
        let pasteboard = NSPasteboard.general
        let urls = Self.fileURLs(on: pasteboard)
        if !urls.isEmpty, let onFiles = editor.onFiles {
            onFiles(urls)
            return true
        }
        // A picture alone: with text beside it (a copy from a web page) the
        // text is what the user means to paste.
        guard pasteboard.string(forType: .string) == nil, let onPastedImage = editor.onPastedImage,
              let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return false }
        onPastedImage(png)
        return true
    }
}

extension View {
    /// Files dropped anywhere on the composer (the fields, the chips, the
    /// footer; the editor takes its own drops, above) become attachments.
    func droppingFiles(_ attach: @escaping ([URL]) -> Void) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            attach(files)
            return true
        }
    }
}

// MARK: - The toolbars

/// The formatting tools: bold, italic, underline, strikethrough, link,
/// the two lists, clear formatting and the AI. `floating` is the dark bar
/// over a selection; otherwise the format bar under the footer's Aa.
struct EditorTools: View {
    let editor: MacComposeEditor
    let floating: Bool
    let showsAI: Bool
    let onLink: () -> Void
    let onAI: () -> Void

    private var foreground: Color { floating ? Theme.onPrimary : Theme.textPrimary }

    var body: some View {
        HStack(spacing: 2) {
            tool("Bold", "bold", command: "bold", key: "⌘B")
            tool("Italic", "italic", command: "italic", key: "⌘I")
            tool("Underline", "underline", command: "underline", key: "⌘U")
            tool("Strikethrough", "strikethrough", command: "strikeThrough", key: "⇧⌘X")
            divider
            button("Link", "link", key: "⌘K", action: onLink)
            tool("Bulleted list", "list.bullet", command: "insertUnorderedList", key: "⇧⌘8")
            tool("Numbered list", "list.number", command: "insertOrderedList", key: "⇧⌘7")
            if !floating {
                button("Clear formatting", "textformat", key: nil) { editor.exec("removeFormat") }
            }
            if showsAI {
                divider
                button("Edit with AI", "sparkles", key: "⌘J", tint: Theme.accent, action: onAI)
            }
        }
        .padding(floating ? 4 : 2)
        .background(floating ? Theme.textPrimary : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var divider: some View {
        Rectangle().fill(foreground.opacity(0.25)).frame(width: 1, height: 16).padding(.horizontal, 3)
    }

    /// A toggle: lit while its format is on at the selection.
    private func tool(_ label: String, _ systemImage: String, command: String, key: String) -> some View {
        let on = editor.activeFormats.contains(command)
        return button(label, systemImage, key: key, tint: on ? Theme.accent : nil) { editor.exec(command) }
    }

    private func button(_ label: String, _ systemImage: String, key: String?, tint: Color? = nil,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint ?? foreground)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(key.map { "\(label) (\($0))" } ?? label)
        .accessibilityLabel(label)
    }
}

/// The bar over a selection, placed by the composer from the selection's
/// rectangle: above its first line, below it when there is no room.
struct SelectionToolbar: View {
    let editor: MacComposeEditor
    let selection: MacComposeEditor.Selection
    /// The editor's width, to keep the bar inside it.
    let width: CGFloat
    let showsAI: Bool
    let onLink: () -> Void
    let onAI: () -> Void
    @State private var size = CGSize(width: 300, height: 36)

    private var origin: CGPoint {
        let x = min(max(selection.rect.minX - 6, 0), max(width - size.width, 0))
        let above = selection.rect.minY - size.height - 8
        let y = above >= -2 ? above : selection.rect.maxY + 8
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        EditorTools(editor: editor, floating: true, showsAI: showsAI, onLink: onLink, onAI: onAI)
            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .offset(x: origin.x, y: origin.y)
            .transition(.opacity)
    }
}

/// The format bar the footer's Aa shows: the same tools on the sunken
/// capsule the phone's glass bar has.
struct MacFormatBar: View {
    let editor: MacComposeEditor
    let onLink: () -> Void

    var body: some View {
        HStack {
            EditorTools(editor: editor, floating: false, showsAI: false, onLink: onLink, onAI: {})
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(Theme.sunken, in: Capsule())
        .padding(.horizontal, 16)
    }
}

// MARK: - The AI panel

/// The writing assistant as a panel under the text (the phone's
/// AIEditSheet, in Superhuman's shape): one line to describe the change
/// and the presets as chips, Write or Edit; while it runs, Cancel is
/// always a click away and the request gives up after `timeout`; the
/// result is reviewed, refined (tone chips chain on it) and only then
/// replaces the selection or the message. Content leaves the device on
/// an explicit click only.
struct MacAIPanel: View {
    let subject: String
    let history: String?
    /// Who writes to whom, for the prompt.
    let context: AIWriteContext
    /// The text to edit and whether it is a selection, read when a run
    /// starts: the selection or the body without the signature.
    let target: () -> (text: String, hasSelection: Bool)
    /// An edit result: replaces the selection or the body.
    let onApply: (String) -> Void
    /// A written draft: replaces the body (the signature stays).
    let onWrite: (String) -> Void
    let onClose: () -> Void
    @Environment(AppModel.self) private var model
    @State private var mode: Mode
    @State private var instruction = ""
    @State private var running = false
    @State private var error: String?
    /// The pending output and whether it is an edit (of a selection or the
    /// body) or a written message; applied only when the user says so.
    @State private var result: Outcome?
    @State private var task: Task<Void, Never>?
    @State private var watchdog: Task<Void, Never>?
    @FocusState private var focused: Bool

    enum Mode: String, CaseIterable, Identifiable {
        case write = "Write", edit = "Edit"
        var id: String { rawValue }
    }

    struct Outcome: Equatable {
        let text: String
        let written: Bool
        let hasSelection: Bool
    }

    /// How long a request may take before the panel gives up on it: the
    /// adapters time out around then too, and a spinner nobody can stop
    /// is what froze the old sheet.
    static let timeout: Duration = .seconds(90)

    init(subject: String, history: String?, context: AIWriteContext,
         target: @escaping () -> (text: String, hasSelection: Bool),
         onApply: @escaping (String) -> Void, onWrite: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.subject = subject
        self.history = history
        self.context = context
        self.target = target
        self.onApply = onApply
        self.onWrite = onWrite
        self.onClose = onClose
        _mode = State(initialValue: Self.isBlank(target().text) ? .write : .edit)
    }

    /// The edit presets, as chips; the first is the one Superhuman leads with.
    static let edits: [(String, String)] = [
        ("Improve writing", "Improve the writing: clearer, smoother and better structured, keeping the meaning, the tone and roughly the length."),
        ("Fix spelling and grammar", "Fix spelling, grammar and punctuation mistakes. Change nothing else."),
        ("Shorten", "Make this more concise without losing the key points."),
        ("Lengthen", "Expand this with a bit more detail and context, keeping the tone."),
        ("Simplify", "Simplify the wording: shorter sentences and plain words, same meaning."),
        ("More formal", "Rewrite this in a more formal, professional tone."),
        ("More casual", "Rewrite this in a more casual, friendly tone."),
    ]
    /// Shown with a result, to refine it: tone is what is left to dial in.
    static let tones: [(String, String)] = [
        ("Warmer", "Make the tone warmer and friendlier, without changing the meaning."),
        ("More formal", "Make the tone more formal and professional, without changing the meaning."),
        ("More casual", "Make the tone more casual and relaxed, without changing the meaning."),
        ("More confident", "Make the tone more confident and direct, without changing the meaning."),
        ("Softer", "Soften the tone — more polite and less blunt — without changing the meaning."),
        ("More concise", "Make it more concise without losing the key points."),
    ]
    /// Quick notes for a drafted reply.
    static let replies: [(String, String?)] = [
        ("Draft the reply", nil),
        ("Say yes", "Agree and confirm."),
        ("Decline politely", "Decline politely, with a brief reason in a placeholder."),
        ("Ask for details", "Ask for the details needed before answering."),
    ]

    private static func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var isReply: Bool { !Self.isBlank(history ?? "") }
    private var hasText: Bool { !Self.isBlank(target().text) }
    private var typed: String { instruction.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let result {
                review(result)
            } else {
                prompt
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(Color(hex: 0xB34E2E))
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .onAppear { focused = true }
        .onDisappear { cancel() }
    }

    // MARK: Asking

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField(placeholder, text: $instruction)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { go() }
                    .onExitCommand { onClose() }
                    .disabled(running)
                if running {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { cancel() }
                        .buttonStyle(.plain)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Button(action: go) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(canGo ? Theme.onPrimary : Theme.textTertiary)
                            .frame(width: 26, height: 26)
                            .background(canGo ? Theme.accent : Theme.sunken, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canGo)
                    .help(mode == .write ? "Write it (↩)" : "Apply (↩)")
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
            }
            chips
            HStack(spacing: 10) {
                Text(hint).font(.caption).foregroundStyle(Theme.textTertiary)
                Spacer()
                if hasText {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 130)
                    .disabled(running)
                }
            }
        }
    }

    private var placeholder: String {
        switch mode {
        case .edit: "Describe how to edit the text"
        case .write: isReply ? "What should the reply say? (optional)" : "What should the email say?"
        }
    }

    private var hint: String {
        switch mode {
        case .edit: target().hasSelection ? "Applies to the selected text." : "Applies to the whole message."
        case .write: isReply ? "Drafts an answer to the conversation; replaces the message." : "Writes the message from your brief."
        }
    }

    private var canGo: Bool {
        guard !running else { return false }
        switch mode {
        case .edit: return !typed.isEmpty && hasText
        case .write: return !typed.isEmpty || isReply
        }
    }

    @ViewBuilder private var chips: some View {
        switch mode {
        case .edit:
            FlowLayout(spacing: 6) {
                ForEach(Array(Self.edits.enumerated()), id: \.element.0) { index, preset in
                    chip(preset.0, primary: index == 0) { edit(preset.1) }
                }
            }
        case .write:
            if isReply {
                FlowLayout(spacing: 6) {
                    ForEach(Array(Self.replies.enumerated()), id: \.element.0) { index, preset in
                        chip(preset.0, primary: index == 0) { write(notes: preset.1 ?? typed) }
                    }
                }
            }
        }
    }

    private func chip(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(primary ? Theme.onPrimary : Theme.textPrimary)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(primary ? Theme.accent : Theme.sunken, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(running)
        .opacity(running ? 0.5 : 1)
    }

    // MARK: Reviewing

    private func review(_ r: Outcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(r.written ? "Review before it replaces the message" :
                        r.hasSelection ? "Review before it replaces the selected text" : "Review before it replaces the message")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
                Spacer()
                if running {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { cancel() }
                        .buttonStyle(.plain)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            ScrollView {
                Text(r.text)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 220)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            FlowLayout(spacing: 6) {
                ForEach(Self.tones, id: \.0) { tone in
                    chip(tone.0) { refine(r, with: tone.1) }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Discard") { result = nil; error = nil }
                    .pillButton()
                    .disabled(running)
                Button(r.written ? "Use it" : r.hasSelection ? "Replace selection" : "Replace message") { apply(r) }
                    .pillButton(prominent: true)
                    .disabled(running)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Requests

    /// Return or the arrow: the typed line, as an edit or as the brief.
    private func go() {
        guard canGo else { return }
        switch mode {
        case .edit: edit(typed)
        case .write: write(notes: typed)
        }
    }

    private func edit(_ instruction: String) {
        let t = target()
        guard !Self.isBlank(t.text) else { error = "Nothing to edit — write something first."; return }
        let (history, context) = (self.history, self.context)
        run {
            try await model.engine.aiEditText(instruction: instruction, text: t.text, history: history, context: context)
        } done: { out in
            result = Outcome(text: out, written: false, hasSelection: t.hasSelection)
        }
    }

    /// A tone chip on a result: applied to the result, not the original,
    /// so chips chain (Warmer, then More concise).
    private func refine(_ r: Outcome, with instruction: String) {
        let (history, context) = (self.history, self.context)
        run {
            try await model.engine.aiEditText(instruction: instruction, text: r.text, history: history, context: context)
        } done: { out in
            result = Outcome(text: out, written: r.written, hasSelection: r.hasSelection)
        }
    }

    /// A reply from the transcript (the notes steer it), or a new message
    /// from the brief through the edit endpoint, as the phone does.
    private func write(notes: String) {
        let (subject, history, context) = (self.subject, self.history, self.context)
        let reply = isReply
        run {
            if reply, let history {
                return try await model.engine.aiDraftReply(subject: subject, history: history,
                                                           notes: notes.isEmpty ? nil : notes, context: context)
            }
            guard !notes.isEmpty else { throw AIPanelError.nothingToWrite }
            return try await model.engine.aiEditText(instruction: AIEditSheet.writeInstruction(subject: subject),
                                                     text: notes, history: nil, context: context)
        } done: { out in
            result = Outcome(text: out, written: true, hasSelection: false)
        }
    }

    /// `work` is main-actor like the engine it calls: a non-isolated async
    /// closure taking the engine was a send of a non-Sendable value, which
    /// Swift 6 refuses (the phone's sheet calls the engine inline, same thing).
    private func run(_ work: @escaping @MainActor () async throws -> String, done: @escaping (String) -> Void) {
        cancel()
        running = true
        error = nil
        task = Task {
            do {
                let out = try await work()
                guard !Task.isCancelled else { return }
                done(out)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            finish()
        }
        watchdog = Task {
            try? await Task.sleep(for: Self.timeout)
            guard !Task.isCancelled else { return }
            task?.cancel()
            error = "The AI took too long. Try again, or pick another provider in Settings."
            finish()
        }
    }

    private func finish() {
        running = false
        watchdog?.cancel()
        watchdog = nil
        task = nil
    }

    private func cancel() {
        task?.cancel()
        finish()
    }

    private func apply(_ r: Outcome) {
        if r.written { onWrite(r.text) } else { onApply(r.text) }
        result = nil
        onClose()
    }
}

private enum AIPanelError: LocalizedError {
    case nothingToWrite
    var errorDescription: String? { "Say what the email should say first." }
}
#endif
