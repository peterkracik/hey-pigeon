// Attachments under a message: chips that fetch the file on tap and open
// Quick Look (never auto-opened), with "Explain" on images and PDFs when
// the on-device model is there. The insight sheet shows what the model
// read and the one-tap chips (remind on travel day, copy the tracking
// number). The triage hook in ThreadView uses the same pieces.

import QuickLook
import QuickLookThumbnailing
import SwiftUI

struct AttachmentChips: View {
    let attachments: [AttachmentItem]
    @Environment(AppModel.self) private var model
    @State private var fetching: String?
    @State private var preview: URL?
    @State private var explaining: AttachmentItem?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 8) {
                ForEach(attachments) { a in
                    Button { Task { await open(a) } } label: {
                        AttachmentTile(attachment: a, fetching: fetching == a.id)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { Task { await open(a) } } label: { Label("Open", systemImage: "eye") }
                        if Downloads.isAvailable {
                            Button { Task { await save(a) } } label: { Label("Save to Downloads", systemImage: "arrow.down.circle") }
                        }
                        if a.isExplainable && AttachmentUnderstanding.isAvailable {
                            Button { explaining = a } label: { Label("Explain attachment", systemImage: "sparkles") }
                        }
                    }
                    .accessibilityLabel("Attachment \(a.filename)")
                }
            }
            if let error { Text(error).font(Theme.caption).foregroundStyle(Theme.dangerText) }
        }
        .quickLookPreview($preview)
        .sheet(item: $explaining) { a in AttachmentInsightSheet(attachment: a) }
    }

    /// The file into the Downloads folder, shown in the Finder (the Mac).
    private func save(_ a: AttachmentItem) async {
        guard fetching == nil else { return }
        fetching = a.id
        defer { fetching = nil }
        do {
            let file = try await model.engine.attachmentFile(a)
            try Downloads.save(file, as: a.filename.isEmpty ? "attachment" : a.filename)
            error = nil
        } catch { self.error = "Couldn't save \(a.filename): \(error.localizedDescription)" }
    }

    private func open(_ a: AttachmentItem) async {
        guard fetching == nil else { return }
        fetching = a.id
        defer { fetching = nil }
        do {
            preview = try await model.engine.attachmentFile(a)
            error = nil
        } catch { self.error = "Couldn't load \(a.filename): \(error.localizedDescription)" }
    }
}

/// One attachment as a small card: a preview of the first page or the
/// picture on top, then the name (two lines) with its type and size. The
/// preview is only drawn for images and PDFs, and only when the file is
/// small and the path is not metered (the same rule as the body prefetch):
/// making it means fetching the attachment, which nobody asked for yet.
/// Everything else shows the file-type icon, so a tile never waits.
private struct AttachmentTile: View {
    let attachment: AttachmentItem
    let fetching: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: CGImage?

    static let width: CGFloat = 168
    static let previewHeight: CGFloat = 96
    /// Larger files are not fetched just to be drawn small.
    static let thumbnailLimit = 8_000_000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewArea
                .frame(width: Self.width, height: Self.previewHeight)
                .clipped()
            VStack(alignment: .leading, spacing: 6) {
                Text(attachment.filename.isEmpty ? "Attachment" : attachment.filename)
                    .font(Theme.text(.caption, .medium)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(attachment.typeLabel)
                        .font(Theme.text(.caption2, .bold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    if let s = attachment.sizeText { Text(s).font(Theme.caption2).foregroundStyle(Theme.textTertiary) }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(width: Self.width, alignment: .leading)
        }
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.separator, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: attachment.id) { await loadThumbnail() }
    }

    @ViewBuilder private var previewArea: some View {
        ZStack {
            if let thumbnail {
                Rectangle().fill(Theme.card)
                Image(decorative: thumbnail, scale: displayScale)
                    .resizable().scaledToFill()
                    .frame(width: Self.width, height: Self.previewHeight, alignment: .top)
            } else {
                Rectangle().fill(Theme.card.opacity(0.6))
                Image(systemName: attachment.isImage ? "photo" : attachment.isPDF ? "doc.richtext" : "doc")
                    .font(.title2).foregroundStyle(Theme.textTertiary)
            }
            if fetching { ProgressView().controlSize(.small) }
        }
    }

    private func loadThumbnail() async {
        guard attachment.isExplainable, attachment.size <= Self.thumbnailLimit,
              Connectivity.shared.allowsPrefetch, thumbnail == nil,
              let file = try? await model.engine.attachmentFile(attachment), !Task.isCancelled else { return }
        let made = await AttachmentThumbnail.make(of: file, size: CGSize(width: Self.width, height: Self.previewHeight), scale: displayScale)
        if let made, !Task.isCancelled { thumbnail = made.image }
    }
}

/// Makes a tile's preview. A CGImage is not Sendable, so the generation
/// happens here, off the main actor, and only the box crosses back.
private enum AttachmentThumbnail {
    struct Box: @unchecked Sendable { let image: CGImage }

    static func make(of file: URL, size: CGSize, scale: CGFloat) async -> Box? {
        let request = QLThumbnailGenerator.Request(fileAt: file, size: size, scale: scale, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        return Box(image: rep.cgImage)
    }
}

extension AttachmentItem {
    /// The badge on a tile: "PDF", "PNG", "DOCX"; "FILE" when nothing says.
    var typeLabel: String {
        if isPDF { return "PDF" }
        let ext = (filename as NSString).pathExtension.uppercased()
        if !ext.isEmpty, ext.count <= 5 { return ext }
        if isImage { return "IMG" }
        return "FILE"
    }
}

/// "Explain attachment": the on-device model's read of an image or a PDF
/// page, the fields it found, and the chips. Nothing leaves the device.
struct AttachmentInsightSheet: View {
    let attachment: AttachmentItem
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var insight: AttachmentInsight?
    @State private var error: String?
    /// Bumped by Try again: the read runs once more.
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ResultState(working: "Reading \(attachment.filename)…", error: error, isReady: insight != nil,
                                retry: { attempt += 1 }) {
                        if let insight {
                            Text(insight.summary).font(Theme.sans(.body)).foregroundStyle(Theme.textPrimary)
                            InsightFields(insight: insight)
                            AttachmentActionChips(actions: AttachmentUnderstanding.actions(for: insight), row: row)
                        }
                    }
                    Text("Read on this \(Device.name) by Apple Intelligence. The attachment never leaves the device.")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary).padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            // Presented from inside the thread's scroll view: the iPad's
            // readable-column margins (`readableColumn`) are the thread's.
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .background(Theme.canvas)
            .navigationTitle(attachment.filename)
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            // Once as the sheet opens, and again for each Try again.
            .task(id: attempt) {
                error = nil
                do {
                    let file = try await model.engine.attachmentFile(attachment)
                    insight = try await AttachmentUnderstanding.explain(file: file, mimeType: attachment.mimeType, filename: attachment.filename)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                }
            }
        }
        .sheetSize(.mediumOrLarge)
    }

    private var row: ThreadRow? { try? model.engine.threadRow(id: attachment.threadId) }
}

private struct InsightFields: View {
    let insight: AttachmentInsight

    var body: some View {
        let pairs: [(String, String)] = [
            ("Kind", insight.kind.rawValue),
            ("From", insight.merchant),
            ("Total", insight.total.isEmpty ? "" : "\(insight.total) \(insight.currency)".trimmingCharacters(in: .whitespaces)),
            ("Date", insight.date),
            ("Flight", insight.flight),
            ("Departure", insight.departure),
            ("Tracking", insight.trackingNumber + (insight.carrier.isEmpty ? "" : " · \(insight.carrier)")),
            ("Code", insight.confirmationCode),
        ].filter { !$0.1.isEmpty }
        VStack(spacing: 0) {
            ForEach(pairs, id: \.0) { k, v in
                HStack(alignment: .firstTextBaseline) {
                    Text(k).font(Theme.secondary).foregroundStyle(Theme.textTertiary).frame(width: 84, alignment: .leading)
                    Text(v).font(Theme.text(.secondary, .medium)).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                    Spacer()
                }
                .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The one-tap chips: a reminder through the existing reminder plumbing,
/// a copy to the clipboard with the toast saying so.
struct AttachmentActionChips: View {
    let actions: [AttachmentAction]
    let row: ThreadRow?
    @Environment(AppModel.self) private var model

    var body: some View {
        if !actions.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(actions) { action in
                    Button { run(action) } label: {
                        Chip(text: action.title, systemImage: action.systemImage,
                             background: Theme.accentSoft, foreground: Theme.textPrimary, capsule: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func run(_ action: AttachmentAction) {
        switch action {
        case .remindTravelDay(let at, _), .remindBefore(let at, _):
            guard let row else { return }
            model.remind(row, at: at, onlyIfNoReply: false)
        case .saveTracking(let n, _):
            Clipboard.copy(n)
            model.show("Tracking number copied")
        case .saveCode(let c):
            Clipboard.copy(c)
            model.show("Code copied")
        }
    }
}

/// The AI's proposal for a new email, under the thread's header: what it
/// suggests, one tap to take it, one to dismiss it. Nothing changes until
/// the user picks (crates/ffi/src/suggest.rs).
struct SuggestionCard: View {
    let suggestion: MailSuggestion
    let row: ThreadRow
    @Environment(AppModel.self) private var model

    private var reason: String {
        switch suggestion {
        case .needsReply: "Looks like someone is waiting on your answer."
        case .remind: "Looks like this matters on a later date."
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "sparkles").font(Theme.secondary).foregroundStyle(Theme.textSecondary)
            Text(reason)
                .font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.acceptSuggestion(row) } label: {
                Chip(text: suggestion.title, systemImage: suggestion.systemImage,
                     background: Theme.accentSoft, foreground: Theme.textPrimary, capsule: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Accept: \(suggestion.title)")
            Button { model.dismissSuggestion(row) } label: {
                Image(systemName: "xmark").font(Theme.glyph(.caption, .semibold)).foregroundStyle(Theme.textTertiary)
                    .padding(6)
                    .tapArea(horizontal: 8, vertical: 10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss suggestion")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
