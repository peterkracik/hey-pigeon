// The window's close / minimise / zoom buttons, kept visible and centred
// in the top bar. The window has no title bar and its toolbar is hidden
// (so the shared views' toolbar items never draw over the top bar), and
// with the toolbar hidden macOS left the three buttons out: the first
// build of the flat design shipped without them. This view, put in the
// window's background, unhides them and moves them down into the
// `MacLayout.topBar` row, again after every resize and full-screen exit,
// which re-lay them out at the top.

import AppKit
import SwiftUI

struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ view: ChromeView, context: Context) { view.place() }

    final class ChromeView: NSView {
        /// Read in deinit, which is not on the main actor; only touched there
        /// and on the main thread.
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                })
            }
            Task { @MainActor [weak self] in self?.place() }
        }

        override func layout() {
            super.layout()
            place()
        }

        /// The buttons sit in the titlebar's container view; grow it to the
        /// top bar's height and centre the three in it, at the left inset
        /// the top bar leaves them (`MacLayout.trafficLights`).
        func place() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            let buttons = types.compactMap { window.standardWindowButton($0) }
            guard let first = buttons.first, let container = first.superview?.superview else { return }
            let height = MacLayout.topBar
            var frame = container.frame
            if frame.height != height || frame.minY != window.frame.height - height {
                frame.size.height = height
                frame.origin.y = window.frame.height - height
                container.frame = frame
            }
            var x: CGFloat = 16
            for b in buttons {
                b.isHidden = false
                let y = ((b.superview?.bounds.height ?? height) - b.frame.height) / 2
                if b.frame.origin != NSPoint(x: x, y: y) { b.setFrameOrigin(NSPoint(x: x, y: y)) }
                x += b.frame.width + 8
            }
        }

        deinit {
            // The observers hold this view weakly; dropping the tokens is enough.
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}
