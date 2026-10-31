// The Mac share sheet's "Hey Pigeon": text, links and files become a
// prefilled composer. The content is the same SwiftUI view as on iOS
// (ios-app/HeyPigeonShare/ShareView.swift); this hosts it in an
// NSViewController. An extension cannot send mail and must not try: the
// items go into the App Group (PendingShare) and the app opens on
// heypigeon://compose through the extension context — and whether or not
// that works, the app picks the share up the next time it is in front.

import AppKit
import SwiftUI

final class ShareViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 340))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = NSHostingController(rootView: ShareView(
            items: extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? [],
            onDone: { [weak self] _ in self?.finish() },
            openApp: { [weak self] url in self?.open(url) ?? false }
        ))
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        preferredContentSize = NSSize(width: 460, height: 340)
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// The extension context opens URLs on the Mac (NSWorkspace is out of
    /// reach from an extension). A failure is quiet: the app adopts the
    /// pending share on its next activation anyway.
    private func open(_ url: URL) -> Bool {
        extensionContext?.open(url, completionHandler: nil)
        return true
    }
}
