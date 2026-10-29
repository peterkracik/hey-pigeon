// Evaluating the triage prompt (docs/ios-intelligence.md, "iOS 27 › One
// model layer"): a labeled set of (sender, subject, preview) rows with the
// expected priority and labels, a scorer, and a harness that runs every
// TriagePromptVariant through a classifier and reports the numbers. The
// pure parts run anywhere (the scorer, the loader, the report); the model
// run needs a device with Apple Intelligence and is skipped elsewhere.
//
// How to hill-climb: edit or add a variant in AI/TriagePrompt.swift, run
// `scoreEveryVariantOnDevice`, read the report in the test log, and move
// the winner into `TriagePromptVariant.shipped`. The same harness, with
// the Evaluations framework's graders wrapped around `TriageEvalReport`,
// is the step to take on the Mac once that framework is in the toolchain.

import Foundation
import FoundationModels
import HeyPigeonCore
import Testing
@testable import HeyPigeon

// MARK: - The labeled set

struct TriageEvalCase: Codable, Hashable {
    let from: String
    let subject: String
    let snippet: String
    let priority: String
    let labels: [String]
}

struct TriageEvalSet: Codable {
    let labels: [String]
    let cases: [TriageEvalCase]

    /// `triage-eval.json` next to this file, bundled with the test target.
    static func load() throws -> TriageEvalSet {
        let url = try #require(Bundle(for: EvalBundleToken.self).url(forResource: "triage-eval", withExtension: "json"))
        return try JSONDecoder().decode(TriageEvalSet.self, from: Data(contentsOf: url))
    }

    /// The label list as the classifier gets it: stable ids from the names.
    var triageLabels: [TriageLabel] {
        labels.map { TriageLabel(id: "eval-\($0.lowercased())", name: $0) }
    }
}

private final class EvalBundleToken {}

// MARK: - Scoring

/// One prediction against one case: the priority hit, and the labels'
/// precision/recall (by id, so a name the model misspelt counts as a miss).
struct TriageEvalScore: Equatable {
    let priorityCorrect: Bool
    /// Off by one priority step (low vs medium) is a smaller mistake than
    /// spam vs high; the distance feeds the report's "near misses".
    let priorityDistance: Int
    let labelsExpected: Int
    let labelsPredicted: Int
    let labelsCorrect: Int

    static func score(expected: TriageEvalCase, predicted: TriageVerdict, labels: [TriageLabel]) -> TriageEvalScore {
        let order = ["spam", "low", "medium", "high"]
        let want = order.firstIndex(of: expected.priority) ?? 1
        let got = order.firstIndex(of: Self.name(predicted.priority)) ?? 1
        let wantIds = Set(expected.labels.compactMap { n in labels.first { $0.name == n }?.id })
        let gotIds = Set(predicted.labelIds)
        return TriageEvalScore(
            priorityCorrect: want == got,
            priorityDistance: abs(want - got),
            labelsExpected: wantIds.count,
            labelsPredicted: gotIds.count,
            labelsCorrect: wantIds.intersection(gotIds).count
        )
    }

    static func name(_ p: Priority) -> String {
        switch p {
        case .spam: "spam"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        }
    }
}

/// The numbers for one prompt variant over the whole set.
struct TriageEvalReport: CustomStringConvertible {
    let variant: String
    let cases: Int
    let priorityAccuracy: Double
    /// Share of cases whose priority is right or one step off.
    let priorityNearAccuracy: Double
    let labelPrecision: Double
    let labelRecall: Double
    let failures: [String]

    var labelF1: Double {
        labelPrecision + labelRecall == 0 ? 0 : 2 * labelPrecision * labelRecall / (labelPrecision + labelRecall)
    }

    /// One number to climb: priority first (it is what every row shows),
    /// labels second.
    var overall: Double { 0.7 * priorityAccuracy + 0.3 * labelF1 }

    init(variant: String, scores: [(TriageEvalCase, TriageEvalScore)]) {
        self.variant = variant
        cases = scores.count
        let n = Double(max(1, scores.count))
        priorityAccuracy = Double(scores.filter { $0.1.priorityCorrect }.count) / n
        priorityNearAccuracy = Double(scores.filter { $0.1.priorityDistance <= 1 }.count) / n
        let predicted = scores.reduce(0) { $0 + $1.1.labelsPredicted }
        let expected = scores.reduce(0) { $0 + $1.1.labelsExpected }
        let correct = scores.reduce(0) { $0 + $1.1.labelsCorrect }
        labelPrecision = predicted == 0 ? (expected == 0 ? 1 : 0) : Double(correct) / Double(predicted)
        labelRecall = expected == 0 ? 1 : Double(correct) / Double(expected)
        failures = scores.filter { !$0.1.priorityCorrect }.map { "\($0.0.subject) (wanted \($0.0.priority))" }
    }

    var description: String {
        String(format: "%@: overall %.2f · priority %.0f%% (near %.0f%%) · labels P %.2f R %.2f F1 %.2f · %d cases%@",
               variant, overall, priorityAccuracy * 100, priorityNearAccuracy * 100, labelPrecision, labelRecall, labelF1, cases,
               failures.isEmpty ? "" : "\n  missed: " + failures.joined(separator: "; "))
    }
}

// MARK: - Harness

/// Anything that turns one case into a verdict: the real backend, or a
/// scripted classifier in the pure tests.
typealias TriageClassify = @Sendable (TriageEvalCase, [TriageLabel]) async throws -> TriageVerdict

enum TriageEvaluation {
    static func run(_ set: TriageEvalSet, variant: TriagePromptVariant, classify: TriageClassify) async throws -> TriageEvalReport {
        var scores: [(TriageEvalCase, TriageEvalScore)] = []
        for c in set.cases {
            let verdict = try await classify(c, set.triageLabels)
            scores.append((c, TriageEvalScore.score(expected: c, predicted: verdict, labels: set.triageLabels)))
        }
        return TriageEvalReport(variant: variant.id, scores: scores)
    }

    /// The on-device model with a given instruction — the backend's own
    /// classify path, the instruction swapped for the variant's.
    static func onDeviceClassifier(variant: TriagePromptVariant, provider: any ModelProvider = SystemModelProvider()) -> TriageClassify {
        { c, labels in
            let session = provider.session(instructions: variant.instructions, task: .classification)
            let call = try await session.respond(
                to: TriagePrompt.prompt(from: c.from, subject: c.subject, snippet: c.snippet, labels: labels.map(\.name)),
                generating: TriageCall.self
            ).content
            return TriageVerdict(priority: call.priority.ffi, labelIds: TriagePrompt.labelIds(for: call.labels, in: labels))
        }
    }
}

// MARK: - Tests

struct TriageEvaluationTests {
    @Test func theLabeledSetLoadsAndIsWellFormed() throws {
        let set = try TriageEvalSet.load()
        #expect(set.cases.count >= 12)
        for c in set.cases {
            #expect(["spam", "low", "medium", "high"].contains(c.priority), "\(c.subject)")
            #expect(c.labels.allSatisfy { set.labels.contains($0) }, "\(c.subject) names an unknown label")
        }
    }

    @Test func aPerfectClassifierScoresOne() async throws {
        let set = try TriageEvalSet.load()
        let report = try await TriageEvaluation.run(set, variant: .shipped) { c, labels in
            let p: Priority = switch c.priority {
            case "spam": .spam
            case "low": .low
            case "medium": .medium
            default: .high
            }
            return TriageVerdict(priority: p, labelIds: TriagePrompt.labelIds(for: c.labels, in: labels))
        }
        #expect(report.priorityAccuracy == 1 && report.labelF1 == 1 && report.overall == 1)
        #expect(report.failures.isEmpty)
    }

    @Test func aClassifierThatSaysMediumForEverythingIsScoredHonestly() async throws {
        let set = try TriageEvalSet.load()
        let report = try await TriageEvaluation.run(set, variant: .terse) { _, _ in
            TriageVerdict(priority: .medium, labelIds: [])
        }
        let mediums = Double(set.cases.filter { $0.priority == "medium" }.count) / Double(set.cases.count)
        #expect(abs(report.priorityAccuracy - mediums) < 0.001)
        #expect(report.labelPrecision == 0 && report.labelRecall == 0 && report.labelF1 == 0)
        #expect(report.priorityNearAccuracy >= report.priorityAccuracy)
        #expect(report.description.hasPrefix("terse: overall"))
    }

    @Test func labelScoringIsByIdNotByName() {
        let labels = [TriageLabel(id: "a", name: "Invoices"), TriageLabel(id: "b", name: "Travel")]
        let c = TriageEvalCase(from: "x", subject: "s", snippet: "p", priority: "low", labels: ["Invoices"])
        let s = TriageEvalScore.score(expected: c, predicted: TriageVerdict(priority: .high, labelIds: ["a", "b"]), labels: labels)
        #expect(s == TriageEvalScore(priorityCorrect: false, priorityDistance: 2, labelsExpected: 1, labelsPredicted: 2, labelsCorrect: 1))
    }

    /// The real run: every variant through the on-device model, the report
    /// per variant in the log, and the shipped prompt expected to hold its
    /// ground. Needs a device with Apple Intelligence.
    @Test(.enabled(if: AppleIntelligenceProvider.isAvailable, "needs Apple Intelligence on the device"))
    func scoreEveryVariantOnDevice() async throws {
        let set = try TriageEvalSet.load()
        var reports: [TriageEvalReport] = []
        for variant in TriagePromptVariant.candidates {
            let report = try await TriageEvaluation.run(set, variant: variant, classify: TriageEvaluation.onDeviceClassifier(variant: variant))
            print(report)
            reports.append(report)
        }
        let shipped = try #require(reports.first { $0.variant == TriagePromptVariant.shipped.id })
        let best = try #require(reports.max { $0.overall < $1.overall })
        // A candidate that beats the shipped prompt by a clear margin is the
        // signal to promote it; the test only fails when shipped regresses.
        #expect(shipped.priorityAccuracy >= 0.5, "the shipped prompt gets fewer than half the priorities right")
        if best.variant != shipped.variant, best.overall - shipped.overall > 0.1 {
            print("⬆ \(best.variant) beats shipped by \(String(format: "%.2f", best.overall - shipped.overall)) — consider promoting it")
        }
    }
}
