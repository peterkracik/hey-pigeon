// A selected passage of a received message, translated: the translate
// circle that follows the selection in the body (MessageBodyView shows it
// when the engine has an AI provider that can answer), and the panel it
// opens beside the selection — a popover on the Mac and the iPad, a sheet
// on the phone. The target language starts as the device's and is picked
// from a menu; the last pick is kept on this device. The request is the
// engine's edit call with a translate instruction (AI/Translation.swift):
// only the selected text leaves the app, on the tap. The line under the
// result says where it went, from the status the request was pinned to
// (the engine sends nothing to another provider), not from a second read
// after the answer, which could name a provider that did not give it.

import SwiftUI

struct TranslationPanel: View {
    /// The selection as it was in the body; cut to `Translation.maxCharacters`
    /// before it is sent.
    let text: String
    @Environment(AppModel.self) private var model
    @AppStorage(Translation.languageKey) private var language = Translation.deviceLanguage
    @State private var result: String?
    @State private var error: String?
    @State private var copied = false
    /// Bumped by Try again: the same language is asked for once more.
    @State private var attempt = 0
    /// Who answers, as the footnote says it: read before the first
    /// request and again only when the engine refuses one because the
    /// provider changed. Every request names this provider, so the
    /// sentence is about the request on screen, and a later one (another
    /// language, Try again) goes where the sentence already says.
    @State private var shown: AIStatus?
    /// `shown` has been read (nil is also "no provider").
    @State private var drawn = false
    /// The last request was not sent: the provider had changed.
    @State private var refused = false

    private var sent: String { Translation.prepared(text) }

    /// Try again, unless there was nothing to translate to begin with.
    private var retry: (() -> Void)? {
        guard !sent.isEmpty else { return nil }
        return { attempt += 1 }
    }
    private var wasCut: Bool { sent.count < text.trimmingCharacters(in: .whitespacesAndNewlines).count }

    /// What left the device, said accurately: the provider the request
    /// was pinned to answers on the device or it does not. After a
    /// refusal nothing was sent, so the line says where Try again goes.
    static func footnote(shown: AIStatus?, refused: Bool, wasCut: Bool) -> String {
        let onDevice = shown?.answersOnDevice ?? false
        if refused {
            return onDevice ? "Try again translates on this \(Device.name)."
                            : "Try again sends the selected text to the AI provider."
        }
        var s = onDevice ? "Translated on this \(Device.name)." : "The selected text was sent to the AI provider."
        if wasCut { s += " Only the first \(Translation.maxCharacters.formatted()) characters were translated." }
        return s
    }

    /// Nothing is said before the first request has its provider.
    private var footnoteShown: String {
        drawn ? Self.footnote(shown: shown, refused: refused, wasCut: wasCut) : " "
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Translation")
                    .font(Theme.display(17, relativeTo: .headline))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                languageMenu
            }
            ScrollView {
                ResultState(working: "Translating…", error: error, isReady: result != nil, retry: retry) {
                    Text(result ?? "")
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            // The panel opens from inside the thread's scroll view: the
            // iPad's readable-column margins (`readableColumn`) are the
            // thread's, not this panel's.
            .contentMargins(.horizontal, 0, for: .scrollContent)
            HStack(alignment: .top) {
                Text(footnoteShown)
                    .font(.caption).foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 8)
                if let result {
                    Button {
                        Clipboard.copy(result)
                        Haptics.light()
                        withAnimation(.snappy) { copied = true }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityLabel("Copy the translation")
                }
            }
        }
        .padding(16)
        .background(Theme.canvas)
        .panelSize(.medium)
        // A new language, or Try again: the task before it is cancelled,
        // so a late answer for the old request is dropped.
        .task(id: "\(language)|\(attempt)") { await translate() }
    }

    /// The target language: the device's, the user's other languages, then
    /// the common set. Picking one translates again.
    private var languageMenu: some View {
        Menu {
            ForEach(Translation.choices(picked: language), id: \.self) { l in
                Button { language = l } label: {
                    if l == language { Label(l, systemImage: "checkmark") } else { Text(l) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(language)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.sunken, in: Capsule())
        }
        .labelOnlyMenu()
        .accessibilityLabel("Translate into \(language)")
    }

    /// One edit call with the translate instruction. The task is cancelled
    /// when the language changes; an answer that arrives after that is for
    /// the old language and is dropped. The call names the provider the
    /// footnote is drawn from; a refusal shows who answers now and waits
    /// for Try again rather than send the text there unasked.
    private func translate() async {
        result = nil
        error = nil
        copied = false
        let text = sent
        guard !text.isEmpty else { error = "Nothing to translate."; return }
        if !drawn {
            shown = try? model.engine.aiStatus()
            drawn = true
        }
        refused = false
        do {
            let out = try await model.engine.aiEditText(instruction: Translation.instruction(to: language), text: text,
                                                        history: nil, context: nil,
                                                        expectedProvider: AIAssist.expectedProvider(shown))
            guard !Task.isCancelled else { return }
            result = out
        } catch let changed as AIProviderChanged {
            guard !Task.isCancelled else { return }
            shown = try? model.engine.aiStatus()
            refused = true
            self.error = changed.errorDescription
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

/// The translate circle beside a selection in a message body: a glass
/// circle with the system's translate symbol, the size
/// `SelectionBadgeGeometry` places.
struct TranslateBadge: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "translate")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: SelectionBadgeGeometry.size, height: SelectionBadgeGeometry.size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help("Translate the selected text")
        .accessibilityLabel("Translate selection")
    }
}
