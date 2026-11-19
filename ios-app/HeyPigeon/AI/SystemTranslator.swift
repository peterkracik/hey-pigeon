// Apple's translation (the Translation framework), the first answer to
// "translate this selection": models made for translating, on this
// device, with no context window to overflow and no second language
// leaking into the answer. A general model asked to translate — the
// on-device one above all — kept sentences in the source language; it
// now gets only the language pairs Apple's translation does not have
// (Features/Thread/TranslationPanel.swift picks the route).
//
// This file never names the app's own `Translation` rules (AI/
// Translation.swift): the framework's module has the same name, and a
// file that imports it would have to say which one it means.

import Foundation
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// A language pair whose download the system should offer.
struct LanguageDownload: Equatable {
    /// Language codes ("sk", "en").
    let source: String
    let target: String
}

enum SystemTranslator {
    /// Whether Apple's translation can take a language pair now.
    enum Readiness: Equatable {
        /// Both languages are on the device.
        case ready
        /// The pair is supported once its languages are downloaded.
        case needsDownload
        /// Not a pair Apple's translation has (or not on this platform).
        case unsupported
    }

    /// The translation came back without one of its parts.
    struct Incomplete: Error {}

    /// Where a pair of language codes stands. The simulator has no
    /// translation models, so it always answers `unsupported` and the
    /// tests run the model route on the sample engine.
    static func readiness(from source: String, to target: String) async -> Readiness {
        #if canImport(Translation) && !targetEnvironment(simulator)
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: source),
                                                         to: Locale.Language(identifier: target))
        switch status {
        case .installed: return .ready
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
        #else
        return .unsupported
        #endif
    }

    /// The parts translated, in order, with the languages already on the
    /// device (`readiness` said `ready`). Throws when the system cannot,
    /// and the caller then asks a model instead.
    static func translate(_ parts: [String], from source: String, to target: String) async throws -> [String] {
        #if canImport(Translation) && !targetEnvironment(simulator)
        let session = TranslationSession(installedSource: Locale.Language(identifier: source),
                                         target: Locale.Language(identifier: target))
        let requests = parts.enumerated().map { index, part in
            TranslationSession.Request(sourceText: part, clientIdentifier: String(index))
        }
        // The answers may come back in another order: the identifier is
        // the part's place.
        var out = [String?](repeating: nil, count: parts.count)
        for response in try await session.translations(from: requests) {
            guard let index = response.clientIdentifier.flatMap({ Int($0) }), out.indices.contains(index) else { continue }
            out[index] = response.targetText
        }
        let done = out.compactMap { $0 }
        guard done.count == parts.count else { throw Incomplete() }
        return done
        #else
        throw Incomplete()
        #endif
    }
}

extension View {
    /// Offers the download of a language pair Apple's translation supports
    /// but does not have on the device yet (the system's own sheet asks),
    /// then calls `done` whether or not it was downloaded: the caller
    /// checks `SystemTranslator.readiness` again. Nothing happens for nil.
    func languageDownload(_ request: LanguageDownload?, done: @escaping @MainActor () -> Void) -> some View {
        #if canImport(Translation) && !targetEnvironment(simulator)
        let configuration = request.map {
            TranslationSession.Configuration(source: Locale.Language(identifier: $0.source),
                                             target: Locale.Language(identifier: $0.target))
        }
        // The session is not Sendable and its calls are not on the main
        // actor: the closure stays off it, and only `done` hops back.
        return translationTask(configuration) { @Sendable session in
            try? await session.prepareTranslation()
            await done()
        }
        #else
        return self
        #endif
    }
}
