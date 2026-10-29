// Attachments under a message: chips that fetch the file on tap and open
// Quick Look (never auto-opened), with "Explain" on images and PDFs when
// the on-device model is there. The insight sheet shows what the model
// read and the one-tap chips (remind on travel day, copy the tracking
// number). The triage hook in ThreadView uses the same pieces.

import QuickLook
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
            FlowLayout(spacing: 6) {
                ForEach(attachments) { a in
                    Button { Task { await open(a) } } label: {
                        HStack(spacing: 5) {
                            if fetching == a.id { ProgressView().controlSize(.mini) } else { Image(systemName: icon(a)).font(.caption) }
                            Text(a.filename).font(.caption.weight(.semibold)).lineLimit(1)
                            if let s = a.sizeText { Text(s).font(.caption2).foregroundStyle(Theme.textTertiary) }
                        }
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { Task { await open(a) } } label: { Label("Open", systemImage: "eye") }
                        if a.isExplainable && AttachmentUnderstanding.isAvailable {
                            Button { explaining = a } label: { Label("Explain attachment", systemImage: "sparkles") }
                        }
                    }
                    .accessibilityLabel("Attachment \(a.filename)")
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .quickLookPreview($preview)
        .sheet(item: $explaining) { a in AttachmentInsightSheet(attachment: a) }
    }

    private func icon(_ a: AttachmentItem) -> String {
        a.isImage ? "photo" : a.isPDF ? "doc.richtext" : "doc"
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

/// "Explain attachment": the on-device model's read of an image or a PDF
/// page, the fields it found, and the chips. Nothing leaves the device.
struct AttachmentInsightSheet: View {
    let attachment: AttachmentItem
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var insight: AttachmentInsight?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let insight {
                        Text(insight.summary).font(.body).foregroundStyle(Theme.textPrimary)
                        InsightFields(insight: insight)
                        AttachmentActionChips(actions: AttachmentUnderstanding.actions(for: insight), row: row)
                    } else if let error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Reading \(attachment.filename)…").font(.body).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Text("Read on this iPhone by Apple Intelligence. The attachment never leaves the device.")
                        .font(.caption).foregroundStyle(Theme.textTertiary).padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(Theme.canvas)
            .navigationTitle(attachment.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                do {
                    let file = try await model.engine.attachmentFile(attachment)
                    insight = try await AttachmentUnderstanding.explain(file: file, mimeType: attachment.mimeType, filename: attachment.filename)
                } catch { self.error = error.localizedDescription }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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
                    Text(k).font(.footnote).foregroundStyle(Theme.textTertiary).frame(width: 84, alignment: .leading)
                    Text(v).font(.footnote.weight(.medium)).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
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
            UIPasteboard.general.string = n
            model.show("Tracking number copied")
        case .saveCode(let c):
            UIPasteboard.general.string = c
            model.show("Code copied")
        }
    }
}

/// Wraps its children onto as many lines as they need (the chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += lineHeight + spacing; lineHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
