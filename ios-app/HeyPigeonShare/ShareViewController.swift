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

/// The sheet: what will be shared, one button. Tapping it saves the items
/// and opens the app on the composer.
struct ShareView: View {
    let items: [NSExtensionItem]
    let onDone: (Bool) -> Void
    let openApp: (URL) -> Bool
    @State private var share: PendingShare?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    HStack { ProgressView(); Text("Reading…").foregroundStyle(.secondary) }
                } else if let share {
                    if !share.text.isEmpty { Text(share.text).lineLimit(6) }
                    ForEach(share.links, id: \.absoluteString) { Label($0.absoluteString, systemImage: "link").lineLimit(2) }
                    ForEach(share.files, id: \.storedName) { f in
                        Label("\(f.filename) · \(ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file))", systemImage: "paperclip").lineLimit(1)
                    }
                    if share.isEmpty { Text("Nothing to share here.").foregroundStyle(.secondary) }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("New email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { PendingShare.clear(); onDone(false) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open Hey Pigeon") { save() }.disabled(loading || share?.isEmpty != false)
                }
            }
        }
        .task { await load() }
    }

    private func save() {
        guard let share, share.save() else { error = "Couldn't hand this to Hey Pigeon."; return }
        let opened = openApp(AppGroup.Link.compose)
        onDone(opened)
    }

    /// Collect attachments: plain text, URLs, and files (images, PDFs,
    /// anything) up to the composer's size cap each.
    private func load() async {
        var out = PendingShare()
        guard let dir = PendingShare.filesURL else { loading = false; share = out; return }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for item in items {
            if out.subject.isEmpty, let title = item.attributedTitle?.string, !title.isEmpty { out.subject = title }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    if url.isFileURL { addFile(url, to: &out, in: dir) } else { out.links.append(url) }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    out.text = out.text.isEmpty ? text : out.text + "\n\n" + text
                } else if let type = provider.registeredTypeIdentifiers.first,
                          let url = try? await provider.loadItem(forTypeIdentifier: type) as? URL, url.isFileURL {
                    addFile(url, to: &out, in: dir)
                } else if let type = provider.registeredTypeIdentifiers.first,
                          let data = try? await provider.loadDataRepresentation(for: UTType(type) ?? .data) {
                    addData(data, type: UTType(type) ?? .data, suggestedName: provider.suggestedName, to: &out, in: dir)
                }
            }
        }
        share = out
        loading = false
    }

    private func addFile(_ url: URL, to out: inout PendingShare, in dir: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        addData(data, type: type, suggestedName: url.lastPathComponent, to: &out, in: dir)
    }

    private func addData(_ data: Data, type: UTType, suggestedName: String?, to out: inout PendingShare, in dir: URL) {
        guard data.count <= PendingShare.maxFileBytes else {
            error = "\(suggestedName ?? "A file") is over 18 MB and was left out."
            return
        }
        let name = suggestedName ?? "Shared.\(type.preferredFilenameExtension ?? "bin")"
        let stored = UUID().uuidString + "-" + name
        guard (try? data.write(to: dir.appendingPathComponent(stored), options: .atomic)) != nil else { return }
        out.files.append(PendingShare.File(filename: name, mimeType: type.preferredMIMEType ?? "application/octet-stream",
                                           storedName: stored, size: data.count))
    }
}

private extension NSItemProvider {
    /// Main-actor like its callers: NSItemProvider is not Sendable, so a
    /// nonisolated async wrapper would be a hop Swift 6 refuses.
    @MainActor
    func loadDataRepresentation(for type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            _ = loadDataRepresentation(for: type) { data, err in
                if let data { cont.resume(returning: data) } else { cont.resume(throwing: err ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
}
