// The share sheet's "Hey Pigeon": text, links and files become a prefilled
// composer. An extension cannot send mail and must not try: it writes the
// items into the App Group (PendingShare) and opens the app, which turns
// them into a draft the moment it is in front. Nothing is sent until Send.

import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(
            items: extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? [],
            onDone: { [weak self] opened in self?.finish(opened: opened) },
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
        host.didMove(toParent: self)
        view.backgroundColor = .clear
    }

    private func finish(opened: Bool) {
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Extensions have no UIApplication. The responder chain above this
    /// controller does reach one that answers `openURL:`, and that is the
    /// way share extensions have opened their app for years. When it does
    /// not work, the app still picks the share up on its next launch.
    private func open(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        let selector = sel_registerName("openURL:")
        while let r = responder {
            if r.responds(to: selector), !(r is UIViewController) {
                r.perform(selector, with: url)
                return true
            }
            responder = r.next
        }
        return false
    }
}
