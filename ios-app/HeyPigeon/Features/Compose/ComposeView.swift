// Compose / reply / forward — the desktop Composer, one to one: From chip,
// To / Cc / Bcc with recipient chips, Subject, a rich-text body, attachment
// chips, and the footer with Send · Discard · AI · Attach · Aa. Send hands
// the draft to the model, which holds it for the undo window before it goes
// to the outbox (text part always, html part when formatting was applied);
// an undone send reopens this view prefilled. Closing (the X, a swipe down)
// or leaving the app saves it as a Gmail draft; Discard deletes that draft.
//
// The body editor and the AI are per platform, in the two extensions at
// the end: the phone's rich TextEditor over an AttributedString, the
// thread under a reply and the AIEditSheet; the Mac's HTML editor, the thread above a
// reply, the floating toolbar and the AI panel (ComposeMac.swift). The
// struct itself holds what both share: the fields, the attachments, the
// footer and the draft's lifecycle.

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ComposeView: View {
    @State private var draft: SendDraft
    @State private var fromId: String
    /// A "Send mail as" address of the From account, when one is picked
    /// instead of the account's own (AppModel.sendAliases).
    @State private var fromAddress: String?
    @State private var to: [String]
    @State private var cc: [String]
    @State private var bcc: [String]
    /// The text typed into each recipient field and not a chip yet.
    @State private var typedTo = ""
    @State private var typedCc = ""
    @State private var typedBcc = ""
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
    /// Content as last saved (or as opened) — a draft is saved only when it changed.
    @State private var savedSnapshot: Snapshot?
    /// Account the Gmail draft was saved under, nil while none was saved.
    @State private var savedFrom: String?
    /// Sent or discarded: leaving must not save a draft.
    @State private var finished = false
    /// Switching between dialog and full screen on the phone: this view
    /// closes and a new one opens with the draft, so it must not save it.
    @State private var handingOver = false
    /// Known addresses for the recipient fields' autocomplete.
    @State private var people: [PersonSuggestion] = []
    /// Written under its thread (the Mac's reply, ThreadView) rather than
    /// in a sheet: no chrome and no scroll view of its own, and leaving
    /// means taking the draft off the model, not dismissing a presentation.
    let inline: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?
    #if os(macOS)
    /// The Mac's editor (ComposeMac.swift), in the TextEditor's place.
    @State private var editor: MacComposeEditor
    /// The AI as a panel under the text, not a sheet.
    @State private var showAIPanel = false
    /// A reply keeps its prefilled recipients and subject behind the
    /// "Draft to …" line until asked for; a new message shows the fields.
    @State private var showFields: Bool
    /// The thread above a reply, once loaded: names for the "Draft to" line.
    @State private var thread: ThreadDetail?
    /// The editor's width, to keep the floating toolbar inside it.
    @State private var editorWidth: CGFloat = 640
    #endif

    /// The field labels' column, growing with the text size ("Subject"
    /// was cut at larger ones) and still one width for every row.
    @ScaledMetric(relativeTo: .subheadline) private var labelWidth: CGFloat = 56

    private enum Field { case to, cc, bcc, subject, body }
    private static let maxAttachBytes = MailLimits.maxAttachmentBytes
    /// How long typing pauses before the model's copy of the draft (what
    /// Siri's "send it" sends) catches up with the editor.
    private static let mirrorDelay: Duration = .milliseconds(300)

    init(draft: SendDraft, inline: Bool = false) {
        self.inline = inline
        _draft = State(initialValue: draft)
        _to = State(initialValue: draft.to)
        _cc = State(initialValue: draft.cc)
        _bcc = State(initialValue: draft.bcc)
        _showCc = State(initialValue: !draft.cc.isEmpty || !draft.bcc.isEmpty)
        _fromId = State(initialValue: draft.fromAccountId ?? "")
        _fromAddress = State(initialValue: draft.fromAddress)
        _body_ = State(initialValue: Self.richBody(of: draft))
        _attachments = State(initialValue: draft.attachments)
        // A forward or a restored (undone) send arrives with a body the user
        // owns: switching From must not replace it with a signature.
        _pristine = State(initialValue: draft.bodyText.isEmpty)
        _savedFrom = State(initialValue: draft.draftSaved ? draft.fromAccountId : nil)
        #if os(macOS)
        _editor = State(initialValue: MacComposeEditor(draft: draft))
        // A reply the sender redirected (Reply-To) shows where it goes.
        _showFields = State(initialValue: draft.replyToThreadId == nil || draft.to.isEmpty || draft.repliesElsewhere)
        #endif
    }

    /// The draft's content, for "did anything change?": what would be
    /// sent (text, html part), not every attribute the editor carries, so
    /// an untouched composer is never saved as a draft.
    private struct Snapshot: Equatable {
        let to: [String], cc: [String], bcc: [String]
        let subject: String, body: String, html: String?
        let attachments: [String]
    }

    private var snapshot: Snapshot {
        Snapshot(to: allTo, cc: allCc, bcc: allBcc, subject: draft.subject, body: plainBody,
                 html: bodyHTML, attachments: attachments.map(\.id))
    }

    /// A field's chips and the address still being typed into it: what is
    /// sent and saved (RecipientField.text).
    private func all(_ chips: [String], _ typed: String) -> [String] {
        guard let a = EmailAddress.pending(typed), !chips.contains(a) else { return chips }
        return chips + [a]
    }
    private var allTo: [String] { all(to, typedTo) }
    private var allCc: [String] { all(cc, typedCc) }
    private var allBcc: [String] { all(bcc, typedBcc) }

    private var fromAccount: MailAccount? { model.accounts.first { $0.id == fromId } }
    /// An account's other addresses to send from: its aliases, without
    /// the one it sends from anyway.
    private func aliases(of account: MailAccount) -> [SendAlias] {
        (model.sendAliases[account.id] ?? []).filter { !EmailAddress.same($0.email, account.email) }
    }
    /// The From row is worth showing: there is a choice to make.
    private var showsFromRow: Bool {
        model.accounts.count > 1 || model.accounts.contains { !aliases(of: $0).isEmpty }
    }
    private var canSend: Bool { !(allTo.isEmpty && allCc.isEmpty && allBcc.isEmpty) && !sending && !fromId.isEmpty }

    var body: some View {
        #if os(macOS)
        if inline {
            withLifecycle(inlineContent).droppingFiles { urls in Task { await addFiles(urls) } }
        } else {
            NavigationStack { withLifecycle(sheetContent) }.droppingFiles { urls in Task { await addFiles(urls) } }
        }
        #else
        NavigationStack { withLifecycle(sheetContent) }
        #endif
    }

    /// The sheet's column: the fields and the editor over the footer, with
    /// the title, close and full-screen chrome.
    private var sheetContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    headerFields
                    bodyEditor
                    if !attachments.isEmpty { attachmentChips }
                    // The Mac's reply has its thread above (headerFields).
                    #if os(iOS)
                    replyHistory
                    #endif
                }
                .padding(.bottom, 24)
            }
            .composeScrollsToEnd(draft.replyToThreadId != nil)
            .dismissKeyboardOnScroll(.interactively)
            footer
        }
        .background(Theme.canvas)
        .borderlessFields()
        .composeChrome(title: draft.replyToThreadId == nil ? "New message" : "Reply",
                       fullScreen: model.composeFullScreen,
                       close: { close() }, toggleFullScreen: { toggleFullScreen() })
    }

    /// The draft's lifecycle around either shape: the people for the
    /// fields, the signature and the baseline on appear, the save on the
    /// way out, the model's copy for Siri, the pickers and the link alert.
    private func withLifecycle<Content: View>(_ content: Content) -> some View {
        content
            .task { people = await model.searchPeople() }
            .onAppear {
                model.loadSendAliases()
                if fromId.isEmpty {
                    fromId = model.selectedAccountId ?? model.accounts.first?.id ?? ""
                }
                if draft.bodyText.isEmpty, let sig = fromAccount?.signature, !sig.isEmpty {
                    setBody(text: "\n\n\(sig)")
                    pristine = true
                }
                focus = to.isEmpty ? .to : .body
                // An undone send (it carries bodyRich) is unsaved work: no
                // baseline, so closing it saves it.
                if savedSnapshot == nil, draft.bodyRich == nil { savedSnapshot = snapshot }
            }
            // A swipe down closes like the X: whatever changed is kept as a draft.
            .onDisappear { if !finished && !handingOver { saveDraft() } }
            // The model's copy follows the editor, so Siri's "send it" sends
            // what is on screen, not what the composer opened with — once
            // typing pauses: each copy re-renders everything that observes
            // the model's draft.
            .task(id: snapshot) {
                try? await Task.sleep(for: Self.mirrorDelay)
                guard !Task.isCancelled, !finished, model.composeDraft?.draftKey == draft.draftKey else { return }
                model.composeDraft = composed
            }
            // Siri's "update draft" changed the model's copy: take its fields.
            .onChange(of: model.composeDraft?.externalRevision) { _, _ in
                guard let d = model.composeDraft, d.draftKey == draft.draftKey, d.externalRevision != draft.externalRevision else { return }
                adopt(d)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background, !finished { saveDraft() }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { Task { await addFiles(urls) } }
            }
            .photosPicker(isPresented: $showPhotos, selection: $photos, maxSelectionCount: 10, matching: .images)
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                Task { await addPhotos(items); photos = [] }
            }
            #if os(iOS)
            .sheet(isPresented: $showAI) {
                // What it writes is reviewed in the sheet before
                // `applyAI` / `replaceBody` put it into the message.
                AIEditSheet(text: selectedText ?? bodyWithoutSignature, hasSelection: selectedText != nil,
                            subject: draft.subject, history: draft.history,
                            onApply: applyAI, onWrite: replaceBody)
                .sheetSize(.mediumOrLarge, dragIndicator: false)
            }
            #endif
            .alert("Link", isPresented: $askLink) {
                TextField("https://", text: $linkURL)
                    .plainInput(.url)
                Button("Link") { applyLink() }
                Button("Cancel", role: .cancel) { linkURL = "" }
            } message: {
                Text("Turn the selected text into a link.")
            }
    }

    // MARK: Rows

    private var fromRow: some View {
        fieldRow("From") {
            Menu {
                ForEach(model.accounts) { a in
                    Button { switchFrom(a) } label: {
                        Label { Text("\(a.displayName)  \(a.email)") } icon: {
                            Image(systemName: a.id == fromId && fromAddress == nil ? "checkmark" : "circle.fill")
                        }
                    }
                    // The account's "Send mail as" addresses, under it.
                    ForEach(aliases(of: a)) { alias in
                        Button {
                            if a.id != fromId { switchFrom(a) }
                            fromAddress = alias.email
                        } label: {
                            Label { Text(alias.name.isEmpty ? alias.email : "\(alias.name)  \(alias.email)") } icon: {
                                Image(systemName: a.id == fromId && fromAddress == alias.email ? "checkmark" : "arrow.turn.down.right")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if let a = fromAccount { Circle().fill(Theme.tagForeground(a.color)).frame(width: 8, height: 8) }
                    Text(fromAddress ?? fromAccount?.email ?? "Choose account").foregroundStyle(Theme.textPrimary)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.sunken, in: Capsule())
            }
            .labelOnlyMenu()
        }
    }

    private func fieldRow<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Text(label)
                    .font(.subheadline).foregroundStyle(Theme.textTertiary)
                    .frame(width: labelWidth, alignment: .leading)
                    .padding(.top, 2)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    Button { attachments.removeAll { $0.id == a.id } } label: {
                        Image(systemName: "xmark").font(.caption2.weight(.bold))
                            // The chip's whole end, not just the glyph.
                            .tapArea(horizontal: 10, vertical: 9)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(a.filename)")
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
            if showFormat { formatBar }
            HStack(spacing: 10) {
                Button { send() } label: {
                    Label("Send", systemImage: "paperplane.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.onPrimary)
                        .frame(height: 22) // the icon buttons' content height, so the pill matches the circles
                        .padding(.horizontal, 6)
                }
                .pillButton(prominent: true)
                .tint(Theme.textPrimary)
                .disabled(!canSend)
                if ComposePresentation.offersSendLater {
                    // The same message at a later hour. It is sent by this
                    // device, so the help says what that takes.
                    Menu {
                        ForEach(SendLaterPreset.available(), id: \.preset) { item in
                            Button("\(item.preset.title) · \(Formatters.reminder(item.date))") { send(at: item.date) }
                        }
                    } label: { Image(systemName: "clock").frame(width: 22, height: 22) }
                        .pillButton()
                        .labelOnlyMenu()
                        .disabled(!canSend)
                        .help("Send later — from this \(Device.name), while Hey Pigeon is open")
                        .accessibilityLabel("Send later")
                }
                Button { discard() } label: { Image(systemName: "trash").frame(width: 22, height: 22) }
                    .pillButton()
                    .accessibilityLabel("Discard")
                Spacer()
                if model.aiConfigured {
                    Button { openAI() } label: { Image(systemName: "sparkles").foregroundStyle(Theme.accent).frame(width: 22, height: 22) }
                        .pillButton()
                        .accessibilityLabel("Write or edit with AI")
                }
                if ComposePresentation.offersSnippets, !model.snippets.isEmpty {
                    Menu {
                        ForEach(model.snippets) { snippet in
                            Button(snippet.name) { insertAtCaret(snippet.body) }
                        }
                    } label: { Image(systemName: "text.quote").frame(width: 22, height: 22) }
                        .pillButton()
                        .labelOnlyMenu()
                        .help("Insert a snippet (Settings › Compose)")
                        .accessibilityLabel("Insert a snippet")
                }
                Menu {
                    Button { showFiles = true } label: { Label("Files", systemImage: "folder") }
                    Button { showPhotos = true } label: { Label("Photo library", systemImage: "photo") }
                } label: { Image(systemName: "paperclip").frame(width: 22, height: 22) }
                    .pillButton()
                    .labelOnlyMenu()
                    .accessibilityLabel("Attach file")
                Button { withAnimation { showFormat.toggle() } } label: {
                    Text("Aa").font(.subheadline.weight(.bold)).frame(width: 22, height: 22)
                }
                .pillButton()
                .foregroundStyle(showFormat ? Theme.accent : Theme.textPrimary)
                .accessibilityLabel("Formatting")
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
        .background(footerBackground)
    }

    /// The From account's signature, when the body still ends with it.
    private var signatureSuffix: String? {
        guard let sig = fromAccount?.signature, !sig.isEmpty, plainBody.hasSuffix(sig) else { return nil }
        return sig
    }

    /// What the AI works on when nothing is selected: the body minus the
    /// signature, which `replaceBody` puts back.
    private var bodyWithoutSignature: String {
        guard let sig = signatureSuffix else { return plainBody }
        return String(plainBody.dropLast(sig.count))
    }

    /// New body text (an AI draft or a whole-body edit), signature kept.
    private func replaceBody(with text: String) {
        setBody(text: signatureSuffix.map { "\(text)\n\n\($0)" } ?? text)
        pristine = false
    }

    private func switchFrom(_ next: MailAccount) {
        // Switching From only swaps the signature while the body is pristine.
        if pristine {
            setBody(text: next.signature.isEmpty ? "" : "\n\n\(next.signature)")
            pristine = true
        }
        fromId = next.id
        // The account's own address again: an alias is another account's.
        fromAddress = nil
    }

    // MARK: Attachments

    /// Files from the Files picker. The size is checked before the file is
    /// read (a video would otherwise be loaded whole only to be refused),
    /// and reading plus base64 run off the main actor so a large PDF does
    /// not freeze the composer.
    private func addFiles(_ urls: [URL]) async {
        let limit = Self.maxAttachBytes
        for url in urls {
            let loaded = await Task.detached(priority: .userInitiated) { Self.load(url, limit: limit) }.value
            switch loaded {
            case .success(let a): add(a)
            case .failure(.tooLarge): model.show("\(url.lastPathComponent) is over Gmail's ~18 MB limit")
            case .failure(.unreadable): model.show("Could not read \(url.lastPathComponent)")
            }
        }
    }

    private enum LoadError: Error { case tooLarge, unreadable }

    /// One picked file as an attachment, inside its security scope.
    private nonisolated static func load(_ url: URL, limit: Int) -> Result<DraftAttachment, LoadError> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limit { return .failure(.tooLarge) }
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return .success(DraftAttachment(filename: url.lastPathComponent, mimeType: mime, size: data.count,
                                        dataBase64: data.base64EncodedString()))
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

    /// The draft as the editor holds it now.
    private var composed: SendDraft {
        var d = draft
        d.to = allTo
        d.cc = allCc
        d.bcc = allBcc
        d.bodyText = plainBody
        d.bodyHTML = bodyHTML
        d.bodyRich = bodyRich
        d.attachments = attachments
        d.fromAddress = fromAddress
        return d
    }

    /// Send now, or — with a date — at a later hour (AppModel.sendLater:
    /// the composer closes the same way, the message waits on this
    /// device).
    private func send(at date: Date? = nil) {
        sending = true
        finished = true
        var d = composed
        let from = fromId
        // A draft saved under another From account is not the one this
        // send's account would delete afterwards.
        if let old = savedFrom, old != from {
            model.deleteDraft(d.draftKey, from: old)
            d.draftSaved = false
        }
        Keyboard.dismiss()
        leave()
        if let date { model.sendLater(d, from: from, at: date) } else { model.send(d, from: from) }
    }

    /// The link alert's address as a URL ("example.com" gets https://);
    /// nil for nothing typed or something that is no address.
    static func linkAddress(from typed: String) -> URL? {
        let raw = typed.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        return URL(string: raw.lowercased().hasPrefix("http") ? raw : "https://\(raw)")
    }

    /// The link alert's "Link": the typed address onto the selection, by
    /// each platform's editor (`link(_:)`).
    private func applyLink() {
        let url = Self.linkAddress(from: linkURL)
        linkURL = ""
        if let url { link(url) }
    }

    /// The From chip and the To / Cc / Bcc / Subject rows, on both
    /// platforms (the Mac folds them behind its "Draft to …" line).
    @ViewBuilder private var recipientRows: some View {
        if showsFromRow { fromRow }
        fieldRow("To") {
            RecipientField(addresses: $to, focused: $focus, field: .to, people: people, text: $typedTo)
            if !showCc {
                Button("Cc/Bcc") { showCc = true; focus = .cc }
                    .composeTextButton()
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.textTertiary)
            }
        }
        if showCc {
            fieldRow("Cc") { RecipientField(addresses: $cc, focused: $focus, field: .cc, people: people, text: $typedCc) }
            fieldRow("Bcc") { RecipientField(addresses: $bcc, focused: $focus, field: .bcc, people: people, text: $typedBcc) }
        }
        fieldRow("Subject") {
            TextField("", text: $draft.subject)
                .focused($focus, equals: .subject)
                // Return in the Subject goes on to the body on the Mac.
                .onSubmit { if ComposePresentation.subjectReturnMovesToBody { focus = .body } }
                .accessibilityLabel("Subject")
        }
    }

    /// Take the fields of a draft changed outside the editor (an intent).
    private func adopt(_ d: SendDraft) {
        draft = d
        to = d.to
        cc = d.cc
        bcc = d.bcc
        typedTo = ""
        typedCc = ""
        typedBcc = ""
        showCc = showCc || !d.cc.isEmpty || !d.bcc.isEmpty
        adoptBody(of: d)
        attachments = d.attachments
        if let from = d.fromAccountId, !from.isEmpty { fromId = from }
        pristine = false
    }

    /// Dialog ⇄ full screen. Where the switch reopens the composer, the
    /// model's draft takes what is typed first, so nothing is lost.
    private func toggleFullScreen() {
        if ComposePresentation.switchReopens {
            handingOver = true
            model.composeDraft = composed
        }
        withAnimation(.snappy(duration: 0.25)) { model.composeFullScreen.toggle() }
    }

    /// X (or Esc): close, keeping the message as a Gmail draft (saved on
    /// disappear) — unless the AI panel is up, which Esc closes first.
    private func close() {
        if dismissAssistant() { return }
        Keyboard.dismiss()
        leave()
    }

    /// Trash: close and delete the draft, if one was saved; the toast's
    /// Undo opens the composer on it again (AppModel.discardDraft). A
    /// composer nothing was written in just closes: there is nothing to
    /// bring back.
    private func discard() {
        finished = true
        if savedFrom != nil || snapshot != savedSnapshot {
            model.discardDraft(composed, savedFrom: savedFrom)
        }
        Keyboard.dismiss()
        leave()
    }

    /// Leave the composer: the sheet is dismissed; written under its
    /// thread, the draft comes off the model and so off the thread
    /// (`dismiss` there would pop the thread itself off the navigation
    /// stack). What was typed is saved on the way out either way.
    private func leave() {
        if inline {
            if model.composeDraft?.draftKey == draft.draftKey { model.composeDraft = nil }
        } else {
            dismiss()
        }
    }

    /// Save (create or update) the Gmail draft when the content changed
    /// since it was opened or last saved.
    private func saveDraft() {
        let now = snapshot
        guard !fromId.isEmpty, now != savedSnapshot else { return }
        if let old = savedFrom, old != fromId { model.deleteDraft(draft.draftKey, from: old) }
        model.saveDraft(composed, from: fromId)
        savedSnapshot = now
        savedFrom = fromId
        draft.draftSaved = true
    }
}

#if os(iOS)
// MARK: - The phone's editor: the rich TextEditor and the AI sheet

extension ComposeView {
    private var plainBody: String { String(body_.characters) }
    private var bodyHTML: String? { RichText.html(body_) }
    private var bodyRich: AttributedString? { body_ }

    private func setBody(text: String) { body_ = AttributedString(text) }
    /// A snippet goes in where the caret is, or over the selection.
    private func insertAtCaret(_ text: String) {
        let snippet = AttributedString(text)
        switch selection.indices(in: body_) {
        case .insertionPoint(let index):
            body_.transform(updating: &selection) { $0.insert(snippet, at: index) }
        case .ranges(let set):
            if let first = set.ranges.first {
                body_.transform(updating: &selection) { $0.replaceSubrange(first, with: snippet) }
            } else {
                body_ = snippet + body_
            }
        }
        pristine = false
    }
    private func adoptBody(of d: SendDraft) { body_ = Self.richBody(of: d) }
    private var footerBackground: Color { Theme.canvas }

    /// Under a reply's text: the conversation it answers, the latest
    /// message open. The sheet covers the thread, and a reply used to be
    /// written without the mail it answers anywhere in sight.
    @ViewBuilder private var replyHistory: some View {
        if let threadId = draft.replyToThreadId {
            Divider().padding(.top, 16)
            ComposeThreadHistory(threadId: threadId, showsSubject: false, onQuote: { quote($0) }) { _ in }
        }
    }

    /// "Quote in reply": the message goes under the text as "> " lines
    /// (once), to be answered between them; the reply then carries it.
    private func quote(_ m: MessageItem) {
        let quoted = QuotedText.quote(m.bodyText ?? m.snippet, from: m.fromName, address: m.fromAddress,
                                      date: Formatters.fullDate(m.date))
        guard !plainBody.contains(quoted) else { return }
        body_.transform(updating: &selection) { $0.append(AttributedString("\n\n" + quoted)) }
        pristine = false
        focus = .body
    }

    /// The From chip and the To / Cc / Bcc / Subject rows.
    @ViewBuilder private var headerFields: some View {
        recipientRows
    }

    private var bodyEditor: some View {
        TextEditor(text: $body_, selection: $selection)
            .font(.body)
            .foregroundStyle(Theme.textPrimary)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            // A reply leaves room for the conversation under it.
            .frame(minHeight: draft.replyToThreadId == nil ? 280 : 140)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .focused($focus, equals: .body)
            .onChange(of: body_) { _, _ in pristine = false }
    }

    /// The glass format bar the footer's Aa shows.
    private var formatBar: some View {
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

    private func format(_ label: String, _ systemImage: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Image(systemName: systemImage).frame(width: 36, height: 36) }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textPrimary)
            .accessibilityLabel(label)
    }

    /// The sparkle: the AI sheet.
    private func openAI() { showAI = true }
    /// The phone has nothing over the composer that Esc would close first.
    private func dismissAssistant() -> Bool { false }

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

    /// The selection becomes a link (`applyLink`).
    private func link(_ url: URL) {
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
            replaceBody(with: result)
        }
    }
}
#else
// MARK: - The Mac's editor: the HTML editor, the thread above a reply, the AI panel

extension ComposeView {
    private var plainBody: String { editor.text }
    private var bodyHTML: String? { editor.htmlPart }
    /// Plain here: the html part carries the formatting. Set all the same
    /// so an undone send counts as unsaved work (`onAppear`'s baseline).
    private var bodyRich: AttributedString? { AttributedString(editor.text) }

    private func setBody(text: String) { editor.setText(text) }
    /// A snippet goes in where the caret is, as typing would (⌘Z takes it
    /// back).
    private func insertAtCaret(_ text: String) {
        editor.replaceSelection(with: text)
        pristine = false
    }
    private func adoptBody(of d: SendDraft) { editor.set(draft: d) }
    private var footerBackground: Color { inline ? Theme.card : Theme.canvas }

    /// Under the thread: the "Draft to …" line (the fields behind it, a
    /// window button and a close), the editor, the attachments and the
    /// footer, on a card like the thread's open message — no chrome and
    /// no scroll view of its own, the thread's does the scrolling. No
    /// shadow and no clip: both would fall on the editor's web view.
    private var inlineContent: some View {
        VStack(spacing: 0) {
            headerFields
            bodyEditor
            if !attachments.isEmpty { attachmentChips }
            footer
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1))
        .padding(.horizontal, 12).padding(.top, 10)
        .borderlessFields()
    }

    /// A reply: the thread (in the sheet; under the thread the messages
    /// are already on screen), then the "Draft to …" line that keeps the
    /// prefilled fields folded; the fields themselves when shown (always
    /// for a new message or a forward, which has no recipients yet).
    @ViewBuilder private var headerFields: some View {
        if let threadId = draft.replyToThreadId {
            if !inline { ComposeThreadHistory(threadId: threadId) { thread = $0 } }
            draftHeader
        }
        if showFields {
            recipientRows
        }
    }

    /// "Draft to Ana, Marek" under the thread, with the fields behind a
    /// disclosure — the reply's recipients are the thread's, and the line
    /// says so without a form.
    private var draftHeader: some View {
        HStack(spacing: 6) {
            Text("Draft")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.tagForeground(.mint))
            Text(recipientLine)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer()
            Button { withAnimation(.snappy(duration: 0.2)) { showFields.toggle() } } label: {
                HStack(spacing: 4) {
                    Text(showFields ? "Hide fields" : "To · Cc · Subject")
                    Image(systemName: showFields ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Recipients and subject")
            if inline {
                headerButton("arrow.up.left.and.arrow.down.right", help: "Open as a window") { detach() }
                headerButton("xmark", help: "Close and keep the draft (Esc)") { close() }
            }
        }
        .padding(.horizontal, 16).padding(.top, inline ? 14 : 18).padding(.bottom, showFields ? 4 : 0)
        // Under the thread the names for the line come from the store;
        // the sheet's history view loads them itself.
        .task(id: draft.replyToThreadId) {
            if inline, let id = draft.replyToThreadId { thread = try? model.engine.threadLocal(id: id) }
        }
    }

    private func headerButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// The window button: the draft moves to the composer's sheet with
    /// what is typed. This view is about to go and must not save on the
    /// way out — the sheet would then save the same draft again.
    private func detach() {
        handingOver = true
        model.composeDraft = composed
        model.composeDetached = true
    }

    private var recipientLine: String {
        let names = (to + cc).map(displayName)
        return names.isEmpty ? "with no recipients yet" : "to \(names.joined(separator: ", "))"
    }

    /// The name the thread knows an address by, else the address.
    private func displayName(_ address: String) -> String {
        // A Reply-To address stays an address: the name would be the one
        // its sender chose for an earlier message of the thread.
        if draft.repliesElsewhere { return address }
        return thread?.mail.first { EmailAddress.same($0.fromAddress, address) }?.fromName ?? address
    }

    /// Who writes to whom, for the AI's prompt.
    private var writeContext: AIWriteContext {
        AIWriteContext(senderName: fromAccount?.displayName, senderEmail: fromAccount?.email,
                       recipients: (to + cc).map { address in
                           let name = displayName(address)
                           return name == address ? address : "\(name) <\(address)>"
                       },
                       subject: draft.subject)
    }

    /// The HTML editor with the floating toolbar over its selection, and
    /// the AI panel under it while it is open.
    @ViewBuilder private var bodyEditor: some View {
        HTMLEditorView(editor: editor, placeholder: model.aiConfigured ? "Tip: Hit ⌘J for AI" : "Write your message…")
            .frame(height: editor.height)
            .overlay(alignment: .topLeading) {
                if let selection = editor.selection {
                    SelectionToolbar(editor: editor, selection: selection, width: editorWidth, showsAI: model.aiConfigured,
                                     onLink: { askLink = true }, onAI: { openAI() })
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { editorWidth = $0 }
            .padding(.top, 10)
            .onChange(of: editor.text) { _, _ in pristine = false }
            .onChange(of: focus) { _, f in if f == .body { editor.focus() } }
            .onAppear {
                editor.onCommand = { command in
                    switch command {
                    case .ai: openAI()
                    case .link: askLink = true
                    case .send: if canSend { send() }
                    case .escape: close()
                    }
                }
                editor.onFiles = { urls in Task { await addFiles(urls) } }
                editor.onPastedImage = { data in
                    add(DraftAttachment(filename: "pasted-image-\(attachments.count + 1).png", mimeType: "image/png",
                                        size: data.count, dataBase64: data.base64EncodedString()))
                }
                if focus == .body { editor.focus() }
            }
        if showAIPanel {
            MacAIPanel(subject: draft.subject, history: draft.history, context: writeContext,
                       target: { (selectedText ?? bodyWithoutSignature, selectedText != nil) },
                       onApply: applyAI, onWrite: replaceBody,
                       onClose: { withAnimation(.snappy(duration: 0.2)) { showAIPanel = false } })
                .padding(.horizontal, 16).padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    /// The format bar the footer's Aa shows: the floating toolbar's tools.
    private var formatBar: some View {
        MacFormatBar(editor: editor) { askLink = true }
    }

    /// The sparkle, ⌘J: the AI panel under the text.
    private func openAI() {
        withAnimation(.snappy(duration: 0.2)) { showAIPanel.toggle() }
    }

    /// Esc closes the AI panel before it closes the composer.
    private func dismissAssistant() -> Bool {
        guard showAIPanel else { return false }
        withAnimation(.snappy(duration: 0.2)) { showAIPanel = false }
        return true
    }

    /// The selection becomes a link (`applyLink`).
    private func link(_ url: URL) {
        editor.createLink(url)
    }

    /// The selection the AI works on, nil when there is none (the last one
    /// the page reported: the panel's field takes the focus, the page
    /// keeps the range).
    private var selectedText: String? { editor.savedSelection?.text }

    private func applyAI(_ result: String) {
        if selectedText != nil {
            editor.replaceSelection(with: result)
        } else {
            replaceBody(with: result)
        }
    }
}
#endif

extension ComposeView {
    /// The phone editor's text for a draft: as it was typed (an undone
    /// send), else read back from the html part of a saved draft, else
    /// the plain text.
    static func richBody(of draft: SendDraft) -> AttributedString {
        if let rich = draft.bodyRich { return rich }
        #if os(iOS)
        if let html = draft.bodyHTML, let rich = RichText.attributed(html: html) { return rich }
        #endif
        return AttributedString(draft.bodyText)
    }
}

/// Serializes the editor's attributed body to the html part — only when
/// some formatting was applied, else nil and the text part goes alone.
enum RichText {
    #if os(iOS)
    /// `html(_:)` read back: the bold, italic, underline, strikethrough
    /// and links of a draft this editor saved. Nil for anything else (a
    /// draft written in Gmail's own editor, with its blocks and styles):
    /// the composer then opens on the plain text, as before.
    static func attributed(html: String) -> AttributedString? {
        var out = AttributedString()
        var bold = 0, italic = 0, underline = 0, strike = 0
        var link: URL?
        var rest = Substring(html)
        func append(_ text: Substring) {
            guard !text.isEmpty else { return }
            var piece = AttributedString(unescape(String(text)))
            var intent: InlinePresentationIntent = []
            if bold > 0 { intent.insert(.stronglyEmphasized) }
            if italic > 0 { intent.insert(.emphasized) }
            if strike > 0 { intent.insert(.strikethrough) }
            if !intent.isEmpty {
                piece.inlinePresentationIntent = intent
                // As the format bar sets them, so the editor shows them.
                var font: Font = .body
                if bold > 0 { font = font.bold() }
                if italic > 0 { font = font.italic() }
                piece.font = font
                if strike > 0 { piece.strikethroughStyle = .single }
            }
            if underline > 0 || link != nil { piece.underlineStyle = .single }
            if let link { piece.link = link }
            out.append(piece)
        }
        while let open = rest.firstIndex(of: "<") {
            append(rest[..<open])
            guard let close = rest[open...].firstIndex(of: ">") else { return nil }
            let tag = String(rest[rest.index(after: open)..<close])
            let closing = tag.hasPrefix("/")
            let name = tag.drop { $0 == "/" }.prefix { $0.isLetter }.lowercased()
            switch name {
            case "b", "strong": bold += closing ? -1 : 1
            case "i", "em": italic += closing ? -1 : 1
            case "u": underline += closing ? -1 : 1
            case "s", "strike", "del": strike += closing ? -1 : 1
            case "a": link = closing ? nil : href(in: tag)
            case "br": out.append(AttributedString("\n"))
            // The Mac editor's paragraphs (and plain blocks): a blank line
            // between, as its own text part has. Lists and anything
            // richer still fall back to the plain text.
            case "p": if closing { out.append(AttributedString("\n\n")) }
            case "div": if closing { out.append(AttributedString("\n")) }
            default: return nil
            }
            rest = rest[rest.index(after: close)...]
        }
        append(rest)
        // No blank lines left over from the last paragraph, or from an
        // empty one's own <br>.
        while out.characters.last == "\n" { out.characters.removeLast() }
        return out
    }

    private static func href(in tag: String) -> URL? {
        guard let match = tag.range(of: #"href\s*=\s*"[^"]*""#, options: [.regularExpression, .caseInsensitive]),
              let open = tag[match].firstIndex(of: "\"") else { return nil }
        let value = tag[match][tag.index(after: open)...].dropLast()
        // Web and mail links only, whatever the html says: this is what
        // goes back out in the sent message.
        guard let url = URL(string: unescape(String(value))),
              ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// `escape` backwards (and the two entities other editors write).
    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
    #endif

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

    /// Text as HTML text or an attribute's value. The one escape: the
    /// Mac's editor page uses it too (MacComposeEditor).
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Wrapping row of chips (attachments, recipients). Each subview is
/// measured against the width left on its line, so a flexible input
/// (the recipient field) fills the rest of the line instead of wrapping.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for v in subviews {
            var s = v.sizeThatFits(ProposedViewSize(width: width - x, height: nil))
            if x > 0, x + s.width > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
                s = v.sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            var s = v.sizeThatFits(ProposedViewSize(width: bounds.maxX - x, height: nil))
            if x > bounds.minX, x + s.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
                s = v.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(s.width, bounds.maxX - x), height: s.height))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
