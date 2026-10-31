// The on-device evaluations run only where Apple Intelligence reports
// itself available (`.enabled(if: AppleIntelligenceProvider.isAvailable)`).
// A CI simulator can say so and still not have the model: the first request
// then fails with ModelManagerServices' "no assets" error (1026, the
// com.apple.MobileAsset.UAF.FM.Overrides catalog). That measures nothing
// about a prompt, so it is recorded as a known, intermittent issue — visible
// in the result bundle, not a red run — while any other error still fails.

import Foundation
import FoundationModels
import Testing

enum OnDeviceModel {
    /// Runs an evaluation body; a model that cannot load becomes a known issue.
    @MainActor
    static func run(_ body: @MainActor () async throws -> Void) async throws {
        do {
            try await body()
        } catch let error where isUnavailable(error) {
            withKnownIssue("the on-device model could not load here: \(error)", isIntermittent: true) {
                throw error
            }
        }
    }

    /// The model said it was available and then could not be loaded.
    static func isUnavailable(_ error: any Error) -> Bool {
        if let generation = error as? LanguageModelSession.GenerationError,
           case .assetsUnavailable = generation {
            return true
        }
        let text = String(reflecting: error)
        return text.contains("ModelManagerError") || (error as NSError).domain.hasSuffix("LanguageModelError")
    }
}
