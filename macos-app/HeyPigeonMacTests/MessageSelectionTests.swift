// Selecting in a message with the mouse, in the window's own pages: the
// full thread (ThreadPage) and a row opened in place in the list
// (InboxPage). The pages are put in a real window and get real mouse
// events through the application's queue, as a pointer's would arrive —
// past the list's table, SwiftUI's gestures and the pages' focus — and the
// selection is then read from the message's web view. A drag over text, a
// drag that starts on a link and a double click must each leave a
// selection, and the web view must still hold the keyboard afterwards
// (without it the selection is grey and ⌘C copies nothing).
// Every wait has a timeout.

import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import HeyPigeon

@MainActor
struct MessageSelectionTests {
    let model: AppModel
    let engine: MockEngine
    let state = WindowState()

    init() {
        engine = MockEngine()
        model = AppModel(engine: engine)
    }

    @Test(.timeLimit(.minutes(2))) func aMessageInTheFullThreadCanBeSelected() async throws {
        let row = try #require(try engine.threadRow(id: "t1"))
        let stage = Stage(NavigationStack { ThreadPage(row: row, state: state) }.environment(model))
        defer { stage.close() }
        try await selects(on: stage)
    }

    @Test(.timeLimit(.minutes(2))) func aMessageOpenedInPlaceInTheListCanBeSelected() async throws {
        let row = try #require(try engine.threadRow(id: "t1"))
        let stage = Stage(InboxPage(state: state).environment(model))
        defer { stage.close() }
        try await Task.sleep(for: .milliseconds(300))
        state.expand(row, in: model)
        try await selects(on: stage)
    }

    /// The three ways a selection starts, each from nothing selected.
    private func selects(on stage: Stage) async throws {
        let found = await stage.messageView()
        let web = try #require(found, "no message came up in the window")
        // Where the second paragraph's words and its link are.
        let textRect = await stage.rect(of: "document.querySelectorAll('p')[1]", in: web)
        let linkRect = await stage.rect(of: "document.querySelector('a')", in: web)
        let text = try #require(textRect)
        let link = try #require(linkRect)
        let from = CGPoint(x: text.minX + 4, y: text.minY + min(text.height, 18) / 2)
        #expect(stage.reaches(web, at: from), "a click on the text lands on \(stage.hit(web, at: from))")

        // A drag over plain text.
        await stage.clear(web)
        await stage.drag(in: web, from: from, to: CGPoint(x: from.x + 120, y: from.y))
        let dragged = await stage.selection(web)
        #expect(!dragged.isEmpty, "a drag over text selected nothing")
        try await Task.sleep(for: .milliseconds(700))
        let kept = await stage.selection(web)
        #expect(!kept.isEmpty, "the dragged selection did not last")
        #expect(stage.holdsKeyboard(web), "after a drag the keyboard is with \(stage.responder)")

        // A drag that starts on a link.
        await stage.clear(web)
        let onLink = CGPoint(x: link.midX, y: link.midY)
        await stage.drag(in: web, from: onLink, to: CGPoint(x: max(onLink.x - 150, text.minX + 2), y: onLink.y))
        let fromLink = await stage.selection(web)
        #expect(!fromLink.isEmpty, "a drag from a link selected nothing")

        // A double click on a word.
        await stage.clear(web)
        await stage.doubleClick(in: web, at: from)
        let word = await stage.selection(web)
        #expect(!word.isEmpty, "a double click selected nothing")
        try await Task.sleep(for: .milliseconds(700))
        let wordKept = await stage.selection(web)
        #expect(!wordKept.isEmpty, "the double-clicked word did not stay selected")
        #expect(stage.holdsKeyboard(web), "after a double click the keyboard is with \(stage.responder)")
    }
}

/// A window with one of the app's pages in it, and a pointer for it.
@MainActor
private final class Stage {
    let window: NSWindow
    private var eventNumber = 0

    init<Page: View>(_ page: Page) {
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 760),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: page)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.orderOut(nil) }

    /// The web view showing the mock thread's message, once it is laid out.
    func messageView(timeout: Duration = .seconds(30)) async -> WKWebView? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            for web in webViews(in: window.contentView) where web.frame.height > 20 {
                if await string("document.body ? document.body.innerText : ''", in: web).contains("Second paragraph") {
                    // The height reports and the pictures settle.
                    try? await Task.sleep(for: .milliseconds(600))
                    return web
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    private func webViews(in view: NSView?) -> [WKWebView] {
        guard let view else { return [] }
        if let web = view as? WKWebView { return [web] }
        return view.subviews.flatMap { webViews(in: $0) }
    }

    func string(_ script: String, in web: WKWebView) async -> String {
        ((try? await web.evaluateJavaScript(script)) as? String) ?? ""
    }

    /// An element's rect in the web view's own (flipped) coordinates.
    func rect(of element: String, in web: WKWebView) async -> CGRect? {
        let json = await string("(function () { var e = \(element); if (!e) return ''; var r = e.getBoundingClientRect();"
            + " return JSON.stringify([r.left, r.top, r.width, r.height]); })()", in: web)
        guard let data = json.data(using: .utf8), let v = try? JSONDecoder().decode([Double].self, from: data), v.count == 4,
              v[2] > 0, v[3] > 0 else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    func selection(_ web: WKWebView) async -> String {
        await string("String(window.getSelection())", in: web).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clear(_ web: WKWebView) async {
        _ = await string("window.getSelection().removeAllRanges(); ''", in: web)
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// The view a click at this point of the web view goes to.
    func hit(_ web: WKWebView, at point: CGPoint) -> String {
        let inWindow = web.convert(point, to: nil)
        guard let content = window.contentView, let frame = content.superview else { return "nothing" }
        guard let view = frame.hitTest(inWindow) else { return "nothing" }
        return String(describing: type(of: view))
    }

    func reaches(_ web: WKWebView, at point: CGPoint) -> Bool {
        let inWindow = web.convert(point, to: nil)
        guard let view = window.contentView?.superview?.hitTest(inWindow) else { return false }
        return view === web || view.isDescendant(of: web)
    }

    var responder: String {
        window.firstResponder.map { String(describing: type(of: $0)) } ?? "nobody"
    }

    func holdsKeyboard(_ web: WKWebView) -> Bool {
        guard let view = window.firstResponder as? NSView else { return false }
        return view === web || view.isDescendant(of: web)
    }

    func drag(in web: WKWebView, from: CGPoint, to: CGPoint) async {
        post(.leftMouseDown, in: web, at: from)
        await pause(60)
        for step in 1...8 {
            let t = CGFloat(step) / 8
            post(.leftMouseDragged, in: web, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            await pause(40)
        }
        post(.leftMouseUp, in: web, at: to)
        await pause(400)
    }

    func doubleClick(in web: WKWebView, at point: CGPoint) async {
        post(.leftMouseDown, in: web, at: point, clicks: 1)
        await pause(30)
        post(.leftMouseUp, in: web, at: point, clicks: 1)
        await pause(60)
        post(.leftMouseDown, in: web, at: point, clicks: 2)
        await pause(30)
        post(.leftMouseUp, in: web, at: point, clicks: 2)
        await pause(400)
    }

    private func pause(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    /// Through the application's queue, not straight to the view: whatever
    /// stands between the pointer and the message gets its say, and a
    /// tracking loop that waits for the next event finds it there.
    private func post(_ type: NSEvent.EventType, in web: WKWebView, at point: CGPoint, clicks: Int = 1) {
        eventNumber += 1
        guard let event = NSEvent.mouseEvent(with: type, location: web.convert(point, to: nil), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: eventNumber, clickCount: clicks,
                                             pressure: type == .leftMouseUp ? 0 : 1) else { return }
        NSApp.postEvent(event, atStart: false)
    }
}
