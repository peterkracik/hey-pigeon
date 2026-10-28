// Compose / reply / forward — the desktop Composer, one to one: From chip,
// To / Cc / Bcc with recipient chips, Subject, a rich-text body, attachment
// chips, and the footer with Send · Discard · AI · Attach · Aa. Sends
// through the outbox like everything else (text part always, html part when
// formatting was applied).

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ComposeView: View {
    @State private var draft: SendDraft
    @State private var fromId: String
    @State private var to: [String]
    @State private var cc: [String]
    @State private var bcc: [String]
    @State private var showCc: Bool
    @State private var body_: AttributedString
    @State private var selection = AttributedTextSelection()
    @State private var attachments: [DraftAttachment]
    @State private var showFormat = false
    @State private var showAI = false
    @State private var showFiles = false
    @State private var showPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var linkURL = ""
    @State private var askLink = false
    @State private var sending = false
    @State private var pristine = true
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?

    private enum Field { case to, cc, bcc, subject, body }
    private static let maxAttachBytes = 18 * 1024 * 1024

    init(draft: SendDraft) {
        _draft = State(initialValue: draft)
        _to = State(initialValue: draft.to)
        _cc = State(initialValue: draft.cc)
        _bcc = State(initialValue: draft.bcc)
        _showCc = State(initialValue: !draft.cc.isEmpty || !draft.bcc.isEmpty)
        _fromId = State(initialValue: draft.fromAccountId ?? "")
        _body_ = State(initialValue: AttributedString(draft.bodyText))
        _attachments = State(initialValue: draft.attachments)
    }

    private var fromAccount: MailAccount? { model.accounts.first { $0.id == fromId } }
    private var canSend: Bool { !(to.isEmpty && cc.isEmpty && bcc.isEmpty) && !sending && !fromId.isEmpty }
    private var plainBody: String { String(body_.characters) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        if model.accounts.count > 1 { fromRow }
                        fieldRow("To") {
                            RecipientField(addresses: $to, focused: $focus, field: .to)
                            if !showCc {
                                Button("Cc/Bcc") { showCc = true; focus = .cc }
                                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                            }
                        }
                        if showCc {
                            fieldRow("Cc") { RecipientField(addresses: $cc, focused: $focus, field: .cc) }
                            fieldRow("Bcc") { RecipientField(addresses: $bcc, focused: $focus, field: .bcc) }
                        }
                        fieldRow("Subject") {
                            TextField("", text: $draft.subject).focused($focus, equals: .subject)
                        }
                        TextEditor(text: $body_, selection: $selection)
                            .font(.body)
                            .scrollDisabled(true)
                            .frame(minHeight: 240)
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                            .focused($focus, equals: .body)
                            .onChange(of: body_) { _, _ in pristine = false }
                        if !attachments.isEmpty { attachmentChips }
                    }
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
                footer
            }
            .background(Theme.canvas)
            .navigationTitle(draft.replyToThreadId == nil ? "New message" : "Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { close() } }
            }
            .onAppear {
                if fromId.isEmpty {
                    fromId = model.selectedAccountId ?? model.accounts.first?.id ?? ""
                }
                if draft.bodyText.isEmpty, let sig = fromAccount?.signature, !sig.isEmpty {
                    body_ = AttributedString("\n\n\(sig)")
                    pristine = true
                }
                focus = to.isEmpty ? .to : .body
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { addFiles(urls) }
            }
            .photosPicker(isPresented: $showPhotos, selection: $photos, maxSelectionCount: 10, matching: .images)
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                Task { await addPhotos(items); photos = [] }
            }
            .sheet(isPresented: $showAI) {
                AIEditSheet(text: selectedText ?? plainBody, hasSelection: selectedText != nil, history: draft.history) { result in
                    applyAI(result)
                }
                .presentationDetents([.medium, .large])
            }
            .alert("Link", isPresented: $askLink) {
                TextField("https://", text: $linkURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button("Link") { applyLink() }
                Button("Cancel", role: .cancel) { linkURL = "" }
            } message: {
                Text("Turn the selected text into a link.")
            }
        }
        .interactiveDismissDisabled(!pristine || !to.isEmpty || !draft.subject.isEmpty)
    }

    // MARK: Rows

    private var fromRow: some View {
        fieldRow("From") {
            Menu {
                ForEach(model.accounts) { a in
                    Button { switchFrom(a) } label: {
                        Label { Text("\(a.displayName)  \(a.email)") } icon: { Image(systemName: a.id == fromId ? "checkmark" : "circle.fill") }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if let a = fromAccount { Circle().fill(Theme.tagForeground(a.color)).frame(width: 8, height: 8) }
                    Text(fromAccount?.email ?? "Choose account").foregroundStyle(Theme.textPrimary)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.sunken, in: Capsule())
            }
        }
    }

    private func fieldRow<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Text(label)
                    .font(.subheadline).foregroundStyle(Theme.textTertiary)
                    .frame(width: 56, alignment: .leading)
                    .padding(.top, 2)
                content()
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            Divider().padding(.leading, 16)
        }
    }

    private var attachmentChips: some View {
        FlowLayout(spacing: 8) {
            ForEach(attachments) { a in
                HStack(spacing: 6) {
                    Image(systemName: "paperclip").font(.caption)
                    Text(a.filename).font(.caption.weight(.medium)).lineLimit(1)
                    Text(Self.size(a.size)).font(.caption2).foregroundStyle(Theme.textTertiary)
                    Button { attachments.removeAll { $0.id == a.id } } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                        .buttonStyle(.plain)
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.sunken, in: Capsule())
            }
        }
        .padding(.horizontal, 16).padding(.top, 10)
    }

    /// Desktop footer: Send · Discard · AI · Attach · Aa (+ the format bar).
    private var footer: some View {
        VStack(spacing: 8) {
            if showFormat {
                HStack(spacing: 4) {
                    format("Bold", "bold") { toggleIntent(.stronglyEmphasized) }
                    format("Italic", "italic") { toggleIntent(.emphasized) }
                    format("Underline", "underline") { toggleUnderline() }
                    format("Strikethrough", "strikethrough") { toggleIntent(.strikethrough) }
                    format("Link", "link") { askLink = true }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal, 16)
            }
            HStack(spacing: 10) {
                Button { send() } label: {
                    Label("Send", systemImage: "paperplane.fill").font(.subheadline.weight(.bold)).padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.textPrimary)
                .disabled(!canSend)
                Button { close() } label: { Image(systemName: "trash").frame(width: 22, height: 22) }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Discard")
                Spacer()
                if model.aiConfigured {
                    Button { showAI = true } label: { Image(systemName: "sparkles").foregroundStyle(Theme.accent).frame(width: 22, height: 22) }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Edit with AI")
                }
                Menu {
                    Button { showFiles = true } label: { Label("Files", systemImage: "folder") }
                    Button { showPhotos = true } label: { Label("Photo library", systemImage: "photo") }
                } label: { Image(systemName: "paperclip").frame(width: 22, height: 22) }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Attach file")
                Button { withAnimation { showFormat.toggle() } } label: {
                    Text("Aa").font(.subheadline.weight(.bold)).frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .foregroundStyle(showFormat ? Theme.accent : Theme.textPrimary)
                .accessibilityLabel("Formatting")
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
        .background(Theme.canvas)
    }

    private func format(_ label: String, _ systemImage: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Image(systemName: systemImage).frame(width: 36, height: 36) }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textPrimary)
            .accessibilityLabel(label)
    }

    // MARK: Formatting (iOS 26 rich TextEditor)

    private func toggleIntent(_ flag: InlinePresentationIntent) {
        body_.transformAttributes(in: &selection) { c in
            var intent = c.inlinePresentationIntent ?? []
            if intent.contains(flag) { intent.remove(flag) } else { intent.insert(flag) }
            c.inlinePresentationIntent = intent.isEmpty ? nil : intent
            // Mirror bold/italic into the font so the editor shows it.
            var font: Font = .body
            if intent.contains(.stronglyEmphasized) { font = font.bold() }
            if intent.contains(.emphasized) { font = font.italic() }
            c.font = font
            c.strikethroughStyle = intent.contains(.strikethrough) ? .single : nil
        }
    }

    private func toggleUnderline() {
        body_.transformAttributes(in: &selection) { c in
            c.underlineStyle = c.underlineStyle == nil ? .single : nil
        }
    }

    private func applyLink() {
        let raw = linkURL.trimmingCharacters(in: .whitespaces)
        linkURL = ""
        guard !raw.isEmpty else { return }
        let url = URL(string: raw.lowercased().hasPrefix("http") ? raw : "https://\(raw)")
        body_.transformAttributes(in: &selection) { c in
            c.link = url
            c.underlineStyle = .single
        }
    }

    /// Text under the selection, nil when it is just a caret.
    private var selectedText: String? {
        guard case .ranges(let set) = selection.indices(in: body_) else { return nil }
        let text = set.ranges.map { String(body_[$0].characters) }.joined()
        return text.isEmpty ? nil : text
    }

    private func applyAI(_ result: String) {
        if case .ranges(let set) = selection.indices(in: body_), let first = set.ranges.first {
            body_.transform(updating: &selection) { text in
                text.replaceSubrange(first, with: AttributedString(result))
            }
        } else {
            body_ = AttributedString(result)
        }
    }

    private func switchFrom(_ next: MailAccount) {
        // Switching From only swaps the signature while the body is pristine.
        if pristine {
            body_ = AttributedString(next.signature.isEmpty ? "" : "\n\n\(next.signature)")
            pristine = true
        }
        fromId = next.id
    }

    // MARK: Attachments

    private func addFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { model.show("Could not read \(url.lastPathComponent)"); continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            add(DraftAttachment(filename: url.lastPathComponent, mimeType: mime, size: data.count, dataBase64: data.base64EncodedString()))
        }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        for (i, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "jpg"
            add(DraftAttachment(filename: "photo-\(attachments.count + i + 1).\(ext)",
                                mimeType: type?.preferredMIMEType ?? "image/jpeg", size: data.count,
                                dataBase64: data.base64EncodedString()))
        }
    }

    private func add(_ a: DraftAttachment) {
        let total = attachments.reduce(0) { $0 + $1.size }
        guard total + a.size <= Self.maxAttachBytes else {
            model.show("Attachment too large — Gmail's limit is ~18 MB per message")
            return
        }
        attachments.append(a)
    }

    private static func size(_ n: Int) -> String {
        n >= 1024 * 1024 ? String(format: "%.1f MB", Double(n) / 1024 / 1024) : "\(max(1, n / 1024)) KB"
    }

    // MARK: Send / close

    private func send() {
        sending = true
        var d = draft
        d.to = to
        d.cc = cc
        d.bcc = bcc
        d.bodyText = plainBody
        d.bodyHTML = RichText.html(body_)
        d.attachments = attachments
        let from = fromId
        Keyboard.dismiss()
        dismiss()
        Task { await model.send(d, from: from) }
    }

    private func close() {
        Keyboard.dismiss()
        dismiss()
    }
}

/// Serializes the editor's attributed body to the html part — only when
/// some formatting was applied, else nil and the text part goes alone.
enum RichText {
    static func html(_ text: AttributedString) -> String? {
        var out = ""
        var formatted = false
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            var open = "", close = ""
            if let url = run.link { open += "<a href=\"\(escape(url.absoluteString))\">"; close = "</a>" + close; formatted = true }
            if intent.contains(.stronglyEmphasized) { open += "<b>"; close = "</b>" + close; formatted = true }
            if intent.contains(.emphasized) { open += "<i>"; close = "</i>" + close; formatted = true }
            if run.underlineStyle != nil && run.link == nil { open += "<u>"; close = "</u>" + close; formatted = true }
            if intent.contains(.strikethrough) { open += "<s>"; close = "</s>" + close; formatted = true }
            let chunk = escape(String(text[run.range].characters)).replacingOccurrences(of: "\n", with: "<br>")
            out += open + chunk + close
        }
        return formatted ? out : nil
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Wrapping row of chips (attachments, recipients).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
