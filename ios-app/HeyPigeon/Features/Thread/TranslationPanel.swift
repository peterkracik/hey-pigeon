// A selected passage of a received message, translated: the translate
// circle that follows the selection in the body (MessageBodyView shows it
// when the engine has an AI provider that can answer), and the panel it
// opens beside the selection — a popover on the Mac and the iPad, a sheet
// on the phone. The target language starts as the device's and is picked
// from a menu; the last pick is kept on this device. The request is the
// engine's edit call with a translate instruction (AI/Translation.swift):
// only the selected text leaves the app, on the tap.

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

    private var sent: String { Translation.prepared(text) }
    private var wasCut: Bool { sent.count < text.trimmingCharacters(in: .whitespacesAndNewlines).count }

    /// What left the device, said accurately: the active provider answers
    /// on the device or it does not (Settings › AI shows the same).
    private var footnote: String {
        let onDevice = (try? model.engine.aiStatus())?.answersOnDevice ?? false
        var s = onDevice ? "Translated on this \(Device.name)." : "The selected text was sent to the AI provider."
        if wasCut { s += " Only the first \(Translation.maxCharacters.formatted()) characters were translated." }
        return s
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
                Group {
                    if let result {
                        Text(result)
                            .font(.body)
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                    } else if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(Theme.dangerText)
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Translating…").font(.body).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            HStack(alignment: .top) {
                Text(footnote)
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
        .task(id: language) { await translate() }
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
    /// the old language and is dropped.
    private func translate() async {
        result = nil
        error = nil
        copied = false
        let text = sent
        guard !text.isEmpty else { error = "Nothing to translate."; return }
        do {
            let out = try await model.engine.aiEditText(instruction: Translation.instruction(to: language), text: text, history: nil)
            guard !Task.isCancelled else { return }
            result = out
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
