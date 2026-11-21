// The share sheet's content, shared by the iOS and the Mac extension
// (HeyPigeonShare/ShareViewController.swift hosts it in a UIViewController,
// macos-app/HeyPigeonMacShare in an NSViewController): what will be shared,
// one button. Tapping it saves the items into the App Group (PendingShare)
// and opens the app on the composer. Nothing is sent until Send.
//
// Drawn in the app's look (docs/specs/marker-look.md) with what an
// extension has in Theme's place, Typeface and WidgetPalette: the sheet's
// paper, ruled rows under the rule that opens a list, a file's size in
// the mono, and one ink action, Open Hey Pigeon.

import SwiftUI
import UniformTypeIdentifiers

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
                openingRule
                rows
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 1)
            .scrollContentBackground(.hidden)
            .background(WidgetPalette.raised)
            .navigationTitle("New email")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { PendingShare.clear(); onDone(false) } label: {
                        Text("Cancel").font(ShareType.sans(.body, mac: 13, .semibold)).foregroundStyle(WidgetPalette.textPrimary)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open Hey Pigeon") { save() }
                        .buttonStyle(ShareInkButtonStyle())
                        .disabled(loading || share?.isEmpty != false)
                }
            }
        }
        // Text that names no face of its own is set in the interface
        // face, and what the system tints is ink, as in the app.
        .font(ShareType.sans(.callout, mac: 13))
        .foregroundStyle(WidgetPalette.textPrimary)
        .tint(WidgetPalette.textPrimary)
        .task { await load() }
    }

    /// The rule that opens a list which has no title (the app's
    /// `SectionRule`, which an extension cannot see).
    private var openingRule: some View {
        Rectangle().fill(WidgetPalette.titleRule).frame(height: 1)
            .accessibilityHidden(true)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 0, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    /// What will be shared, a row each: the text, the links, the files.
    /// A row is ruled off from the one over it, so the first has no
    /// hairline over it and the last none under it.
    @ViewBuilder private var rows: some View {
        if loading {
            HStack {
                ProgressView()
                Text("Reading…").foregroundStyle(WidgetPalette.textSecondary)
            }
            .shareRow(ruled: false)
        } else if let share {
            if !share.text.isEmpty {
                Text(share.text).lineLimit(6).shareRow(ruled: false)
            }
            ForEach(share.links, id: \.absoluteString) { link in
                Label(link.absoluteString, systemImage: "link")
                    .font(ShareType.sans(.callout, mac: 13, .medium))
                    .lineLimit(2)
                    .shareRow(ruled: !share.text.isEmpty || link != share.links.first)
            }
            ForEach(share.files, id: \.storedName) { f in
                Label { fileLine(f) } icon: { Image(systemName: "paperclip") }
                    .font(ShareType.sans(.callout, mac: 13, .medium))
                    .lineLimit(1)
                    .shareRow(ruled: !share.text.isEmpty || !share.links.isEmpty || f != share.files.first)
            }
            if share.isEmpty {
                Text("Nothing to share here.").foregroundStyle(WidgetPalette.textTertiary).shareRow(ruled: false)
            }
        }
        if let error {
            Text(error).font(ShareType.sans(.footnote, mac: 12)).foregroundStyle(WidgetPalette.dangerText)
                .shareRow(ruled: hasRows)
        }
    }

    /// Whether a row stands over the error line.
    private var hasRows: Bool {
        if loading { return true }
        guard let share else { return false }
        return share.isEmpty || !share.text.isEmpty || !share.links.isEmpty || !share.files.isEmpty
    }

    /// A file's line: its name, then its size, which is data and set in
    /// the mono, a step back.
    private func fileLine(_ file: PendingShare.File) -> Text {
        let size: Text = Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
            .font(ShareType.mono(.footnote, mac: 12))
            .foregroundStyle(WidgetPalette.textSecondary)
        return Text("\(Text(file.filename)) · \(size)")
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

/// The sheet's type: a text style on the phone, so Dynamic Type scales
/// it; on the Mac, whose text styles are a step or two under its window's
/// 13 pt, a size of its own (as `Theme.text` gives the app's views).
private enum ShareType {
    static func sans(_ style: Font.TextStyle, mac: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        #if os(macOS)
        return Typeface.sans(size: mac, weight: weight)
        #else
        return Typeface.sans(style, weight)
        #endif
    }

    static func mono(_ style: Font.TextStyle, mac: CGFloat) -> Font {
        #if os(macOS)
        return Typeface.mono(size: mac)
        #else
        return Typeface.mono(style)
        #endif
    }
}

private extension View {
    /// A row of the sheet: straight on its paper, 16 pt in, with the
    /// hairline that parts it from the row over it when there is one.
    func shareRow(ruled: Bool) -> some View {
        listRowInsets(EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16))
            .listRowBackground(Color.clear.overlay(alignment: .top) {
                if ruled {
                    Rectangle().fill(WidgetPalette.separator).frame(height: 1).padding(.horizontal, 16)
                }
            })
            .listRowSeparator(.hidden)
    }
}

/// The sheet's one ink action, Open Hey Pigeon: an ink capsule with the
/// paper's colour for its words (the app's `InkButtonStyle`, which an
/// extension cannot see). The button draws its own fill and words, so it
/// reads the same whatever the bar puts behind it.
private struct ShareInkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ShareType.sans(.callout, mac: 13, .semibold))
            .foregroundStyle(WidgetPalette.onPrimary)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(WidgetPalette.textPrimary, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
            .contentShape(Capsule())
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
