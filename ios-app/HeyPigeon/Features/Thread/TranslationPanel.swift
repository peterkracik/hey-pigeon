// A selected passage of a received message, translated: the translate
// circle that follows the selection in the body (MessageBodyView), and
// the panel it opens beside the selection — a popover on the Mac and the
// iPad, a sheet on the phone. The target language starts as the device's
// and is picked from a menu; the last pick is kept on this device.
//
// Who translates, in order: Apple's translation on this device when it
// has the language pair (AI/SystemTranslator.swift; it offers to download
// a pair it supports), else the AI provider through the engine's
// `aiTranslate`, a few paragraphs per request (AI/Translation.swift
// `segments`), each answer checked for paragraphs left in the source
// language and asked again in smaller parts when it has one. Only the
// selected text is translated, on the tap. The line under the result says
// where it went: nowhere for Apple's translation, and for a model the
// provider every request was pinned to (the engine sends nothing to
// another one), not a second read after the answer.

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
    /// Who answers when a model translates, as the footnote says it: read
    /// before the first request and again only when the engine refuses
    /// one because the provider changed. Every request names this
    /// provider, so the sentence is about the request on screen, and a
    /// later one (another language, Try again) goes where the sentence
    /// already says.
    @State private var shown: AIStatus?
    /// `shown` has been read (nil is also "no provider").
    @State private var drawn = false
    /// The last request was not sent: the provider had changed.
    @State private var refused = false
    /// Who translated what is on screen; nil until something is.
    @State private var route: Route?
    /// More parts of the passage are still being translated.
    @State private var pending = false
    /// The model answered in a language it is not made for.
    @State private var caution: String?
    /// The language pair the system is offering to download, and the
    /// pairs already offered once (declined ones go to the model).
    @State private var download: LanguageDownload?
    @State private var offered: Set<String> = []

    /// Who produced the translation on screen.
    enum Route: Equatable {
        /// Apple's translation, on this device.
        case system
        /// The AI provider `shown` names.
        case model
        /// Nobody: the passage is already in the language asked for.
        case already
    }

    private var sent: String { Translation.prepared(text) }

    /// Try again, unless there was nothing to translate to begin with.
    private var retry: (() -> Void)? {
        guard !sent.isEmpty else { return nil }
        return { attempt += 1 }
    }
    private var wasCut: Bool { sent.count < text.trimmingCharacters(in: .whitespacesAndNewlines).count }

    /// What left the device, said accurately. Apple's translation and a
    /// passage already in the language send nothing; a model is the
    /// provider the request was pinned to, on the device or not. After a
    /// refusal nothing was sent, so the line says where Try again goes.
    static func footnote(route: Route = .model, shown: AIStatus?, refused: Bool, wasCut: Bool, language: String = "") -> String {
        let onDevice = shown?.answersOnDevice ?? false
        if refused {
            return onDevice ? "Try again translates on this \(Device.name)."
                            : "Try again sends the selected text to the AI provider."
        }
        var s: String
        switch route {
        case .system: s = "Translated on this \(Device.name) by Apple's translation. Nothing left the device."
        case .already: s = "The selection is already in \(language). Nothing was sent."
        case .model: s = onDevice ? "Translated on this \(Device.name)." : "The selected text was sent to the AI provider."
        }
        if wasCut { s += " Only the first \(Translation.maxCharacters.formatted()) characters were translated." }
        return s
    }

    /// Nothing is said before a translation, or a refusal, is on screen.
    private var footnoteShown: String {
        if refused { return Self.footnote(shown: shown, refused: true, wasCut: wasCut) }
        guard let route else { return " " }
        return Self.footnote(route: route, shown: shown, refused: false, wasCut: wasCut, language: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The translation's block opens as every block the AI writes
            // does: the sparkle and the name over a rule, with the
            // language — the one control — after the rule.
            SectionTitle(title: "Translation", systemImage: "sparkles") { languageMenu }
            ScrollView {
                ResultState(working: "Translating…", error: error, isReady: result != nil, retry: retry) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(result ?? "")
                            .font(Theme.text(.row))
                            .lineSpacing(4)
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                        // A long passage arrives part by part.
                        if pending {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Translating the rest…").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                            }
                        }
                        if let caution {
                            Label(caution, systemImage: "exclamationmark.triangle")
                                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            // The panel opens from inside the thread's scroll view: the
            // iPad's readable-column margins (`readableColumn`) are the
            // thread's, not this panel's.
            .contentMargins(.horizontal, 0, for: .scrollContent)
            // A hairline parts the translation from what is said about it.
            RowRule()
            HStack(alignment: .top) {
                Text(footnoteShown)
                    .font(Theme.secondary).foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 8)
                if let result, !pending {
                    Button {
                        Clipboard.copy(result)
                        Haptics.light()
                        withAnimation(.snappy) { copied = true }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(Theme.text(.secondary, .semibold))
                    }
                    // An outlined capsule, the small one: the panel has no
                    // ink action.
                    .buttonStyle(OutlineButtonStyle(compact: true))
                    .accessibilityLabel("Copy the translation")
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        // A sheet on the phone, a popover on the iPad and the Mac: the
        // raised paper either way.
        .background(Theme.raised)
        .panelSize(.medium)
        // A new language, or Try again: the task before it is cancelled,
        // so a late answer for the old request is dropped.
        .task(id: "\(language)|\(attempt)") { await translate() }
        // A pair Apple's translation supports but has not downloaded: the
        // system asks, and the same request runs again either way.
        .languageDownload(download) {
            download = nil
            attempt += 1
        }
    }

    /// The target language: the device's, the user's other languages, then
    /// the common set. Picking one translates again. It ends the title's
    /// line as plain ink writing with a chevron: a control, so it keeps
    /// its strength beside the light grey title, and nothing fills it.
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
                    .font(Theme.text(.bodySmall, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Image(systemName: "chevron.down").font(Theme.glyph(.caption2, .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .lineLimit(1)
            // A line of words: taller to the finger.
            .tapArea(vertical: 12)
        }
        .labelOnlyMenu()
        .accessibilityLabel("Translate into \(language)")
    }

    /// Translate the selection into `language`. The task is cancelled
    /// when the language changes; an answer that arrives after that is for
    /// the old language and is dropped.
    private func translate() async {
        result = nil
        error = nil
        copied = false
        route = nil
        pending = false
        caution = nil
        refused = false
        download = nil
        let text = sent
        guard !text.isEmpty else { error = "Nothing to translate."; return }
        // Sure of the language, or only guessing (a short selection): a
        // guess is enough to try Apple's translation with, not to tell a
        // model what it is reading or to call the passage translated.
        let sure = Translation.detectedLanguage(of: text)
        let target = Translation.code(for: language)
        if let sure, let target, Translation.same(sure, target) {
            result = text
            route = .already
            return
        }
        if let source = sure ?? Translation.detectedLanguage(of: text, atLeast: 0.2), let target,
           !Translation.same(source, target) {
            let readiness = await SystemTranslator.readiness(from: source, to: target)
            guard !Task.isCancelled else { return }
            let pair = "\(source)>\(target)"
            if readiness == .needsDownload, !offered.contains(pair) {
                // The spinner stays up while the system asks; the download
                // modifier bumps `attempt` when it is done with it.
                offered.insert(pair)
                download = LanguageDownload(source: source, target: target)
                return
            }
            if readiness == .ready,
               let parts = try? await SystemTranslator.translate(Translation.paragraphs(text), from: source, to: target) {
                guard !Task.isCancelled else { return }
                result = parts.joined(separator: "\n\n")
                route = .system
                return
            }
            guard !Task.isCancelled else { return }
        }
        await translateWithModel(text, source: sure, target: target)
    }

    /// The AI provider's translation, for what Apple's translation cannot
    /// take: one request per part of the passage, shown as they arrive.
    /// Every request names the provider the footnote is drawn from; a
    /// refusal shows who answers now and waits for Try again rather than
    /// send the text there unasked.
    private func translateWithModel(_ text: String, source: String?, target: String?) async {
        if !drawn {
            shown = try? model.engine.aiStatus()
            drawn = true
        }
        guard shown?.configured == true else {
            error = "Translating into \(language) from this language needs an AI provider. Set one up in Settings › AI."
            return
        }
        let onDevice = shown?.answersOnDevice ?? false
        let expected = AIAssist.expectedProvider(shown)
        let sourceName = source.flatMap(Translation.languageName(for:))
        let limit = onDevice ? Translation.deviceSegment : Translation.maxCharacters
        let segments = Translation.segments(text, limit: limit)
        var done: [String] = []
        do {
            for segment in segments {
                var out = try await model.engine.aiTranslate(text: segment, source: sourceName, target: language,
                                                             expectedProvider: expected)
                // A paragraph left in the source language: the same part
                // again, a few sentences at a time, where a small model
                // holds the target language.
                let smaller = Translation.segments(segment, limit: max(segment.count / 3, 200))
                if Translation.leftInSource(out, source: source, target: target), smaller.count > 1 {
                    var again: [String] = []
                    for piece in smaller {
                        again.append(try await model.engine.aiTranslate(text: piece, source: sourceName, target: language,
                                                                        expectedProvider: expected))
                    }
                    let joined = again.joined(separator: "\n\n")
                    if !Translation.leftInSource(joined, source: source, target: target) { out = joined }
                }
                guard !Task.isCancelled else { return }
                done.append(out)
                result = done.joined(separator: "\n\n")
                route = .model
                pending = done.count < segments.count
            }
            if onDevice {
                caution = Self.caution(language: language, source: sourceName,
                                       supported: { SystemModelProvider.supports(language: $0) },
                                       sourceCode: source, targetCode: target)
            }
        } catch let changed as AIProviderChanged {
            guard !Task.isCancelled else { return }
            shown = try? model.engine.aiStatus()
            refused = true
            fail(changed.errorDescription)
        } catch {
            guard !Task.isCancelled else { return }
            fail(error.localizedDescription)
        }
    }

    /// A request failed: the error replaces whatever parts had arrived.
    private func fail(_ message: String?) {
        result = nil
        route = nil
        pending = false
        error = message
    }

    /// The line under a translation the on-device model made in a
    /// language it is not made for, naming that language; nil when it
    /// knows both (or the languages could not be told).
    static func caution(language: String, source: String?, supported: (String) -> Bool,
                        sourceCode: String?, targetCode: String?) -> String? {
        var rough: String?
        if let targetCode, !supported(targetCode) {
            rough = language
        } else if let sourceCode, let source, !supported(sourceCode) {
            rough = source
        }
        guard let rough else { return nil }
        return "The model on this \(Device.name) is not made for \(rough), so this may read roughly. "
            + "Another provider in Settings › AI translates it better."
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
