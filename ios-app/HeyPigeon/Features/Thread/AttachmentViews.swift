// Attachments under a message: tiles that fetch the file on tap and open
// Quick Look (never auto-opened), with "Explain" on images and PDFs when
// the on-device model is there. The insight sheet shows what the model
// read and the one-tap actions (remind on travel day, copy the tracking
// number). The triage hook in ThreadView uses the same pieces.
//
// Drawn on the paper (docs/specs/marker-look.md): a tile is boxed, not
// filled; what the model read is a block under a "Summary" title with its
// facts as a ruled list; and an action the AI suggests is its words under
// the highlighter, never a tinted chip.

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

/// One attachment as a small boxed tile: a preview of the first page or
/// the picture on top, then the name (two lines) with its type and size
/// in the mono. Boxed, not filled: the paper shows through and an outline
/// holds the tile. The preview is only drawn for images and PDFs, and
/// only when the file is small and the path is not metered (the same
/// rule as the body prefetch): making it means fetching the attachment,
/// which nobody asked for yet. Everything else shows the file-type icon
/// on a placeholder's grey, so a tile never waits.
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
    /// What is boxed has 6 pt corners.
    private static let box = RoundedRectangle(cornerRadius: 6, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewArea
                .frame(width: Self.width, height: Self.previewHeight)
                .clipped()
            // A white page on the white paper would run into its name.
            RowRule()
            VStack(alignment: .leading, spacing: 5) {
                Text(attachment.filename.isEmpty ? "Attachment" : attachment.filename)
                    .font(Theme.text(.secondary, .medium)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // The type and the size are data: the mono. The type is
                // a tag's grey, not pink: pink is for what the AI says.
                HStack(spacing: 8) {
                    Text(attachment.typeLabel)
                        .font(Theme.mono(size: 11, weight: .medium, relativeTo: .caption2))
                        .foregroundStyle(Theme.textSecondary)
                    if let s = attachment.sizeText {
                        Text(s).font(Theme.mono(size: 11, relativeTo: .caption2)).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(width: Self.width, alignment: .leading)
        }
        .frame(width: Self.width)
        .clipShape(Self.box)
        .overlay(Self.box.strokeBorder(Theme.outline, lineWidth: 1))
        .contentShape(Self.box)
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
                // No preview: a placeholder's grey under the file's glyph.
                Rectangle().fill(Theme.sunken)
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
    /// The type written on a tile: "PDF", "PNG", "DOCX"; "FILE" when nothing says.
    var typeLabel: String {
        if isPDF { return "PDF" }
        let ext = (filename as NSString).pathExtension.uppercased()
        if !ext.isEmpty, ext.count <= 5 { return ext }
        if isImage { return "IMG" }
        return "FILE"
    }
}

/// "Explain attachment": the on-device model's read of an image or a PDF
/// page under its title, the fields it found as a ruled list, and what it
/// suggests doing with them. Nothing leaves the device.
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
                    // What the model wrote opens under the AI's title.
                    SectionTitle("Summary", systemImage: "sparkles")
                    ResultState(working: "Reading \(attachment.filename)…", error: error, isReady: insight != nil,
                                retry: { attempt += 1 }) {
                        if let insight {
                            Text(insight.summary).font(Theme.text(.row)).lineSpacing(4).foregroundStyle(Theme.textPrimary)
                            InsightFields(insight: insight)
                            AttachmentActionChips(actions: AttachmentUnderstanding.actions(for: insight), row: row)
                        }
                    }
                    Text("Read on this \(Device.name) by Apple Intelligence. The attachment never leaves the device.")
                        .font(Theme.secondary).foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 20)
            }
            // Presented from inside the thread's scroll view: the iPad's
            // readable-column margins (`readableColumn`) are the thread's.
            .contentMargins(.horizontal, 0, for: .scrollContent)
            // A sheet stands on the raised paper.
            .background(Theme.raised)
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

/// The fields the model found, as a ruled list under a rule of its own
/// (a section with no name): what a field is, then its value in the
/// mono, as data is read. No card around them.
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
        if !pairs.isEmpty {
            VStack(spacing: 0) {
                SectionRule()
                ForEach(pairs, id: \.0) { k, v in
                    // A hairline between two fields; the first stands
                    // under the section's rule, the last has none.
                    if k != pairs.first?.0 { RowRule() }
                    HStack(alignment: .firstTextBaseline) {
                        Text(k).font(Theme.secondary).foregroundStyle(Theme.textTertiary).frame(width: 84, alignment: .leading)
                        Text(v).font(Theme.mono(size: 13, relativeTo: .footnote)).foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .padding(.vertical, 9)
                }
            }
        }
    }
}

/// The one-tap actions: a reminder through the existing reminder plumbing,
/// a copy to the clipboard with the toast saying so. What the AI suggests
/// is its words under the highlighter ("look here"), not a tinted chip.
struct AttachmentActionChips: View {
    let actions: [AttachmentAction]
    let row: ThreadRow?
    @Environment(AppModel.self) private var model

    var body: some View {
        if !actions.isEmpty {
            FlowLayout(spacing: 12) {
                ForEach(actions) { action in
                    Button { run(action) } label: {
                        Text(action.title)
                            .font(Theme.text(.secondary, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .marker()
                            // A line of words: taller to the finger.
                            .tapArea(vertical: 12)
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
/// the user picks (crates/ffi/src/suggest.rs). It is the AI speaking, so
/// its sparkle is pink ink and the action it offers is the words under
/// the highlighter; a hairline boxes the line, nothing fills it.
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
            Image(systemName: "sparkles").font(Theme.glyph(.bodySmall)).foregroundStyle(Theme.pinkInk)
            Text(reason)
                .font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.acceptSuggestion(row) } label: {
                Text(suggestion.title)
                    .font(Theme.text(.secondary, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .marker()
                    // A line of words: taller to the finger.
                    .tapArea(horizontal: 4, vertical: 12)
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
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1))
    }
}
