// Evaluating the summary prompt the same way as the triage one: a small
// set of inbox groups, a checker for the format the prompt asks for (the
// "- " bullets and **bold** that SummaryMarkup renders, 1–4 lines, no
// headers, no preamble) and a grounding check (every bolded fact appears
// in the input, so the model invented nothing). The shipped instruction
// comes from the engine (`aiPrompts().summary`, crates/ffi/src/settings.rs),
// so what is scored is what the app runs; variants are strings here.

import Foundation
import FoundationModels
import Testing
@testable import HeyPigeon

struct SummaryEvalCase {
    let title: String
    let items: [(from: String, subject: String, snippet: String)]
}

/// Did an answer follow the format rules, and did it stick to the input?
struct SummaryFormatCheck: Equatable {
    let lines: Int
    let everyLineIsABullet: Bool
    let hasBold: Bool
    let hasOtherMarkdown: Bool
    let ungroundedBold: [String]

    var passes: Bool { (1...4).contains(lines) && everyLineIsABullet && hasBold && !hasOtherMarkdown && ungroundedBold.isEmpty }

    static func check(_ answer: String, against items: [(from: String, subject: String, snippet: String)]) -> SummaryFormatCheck {
        let lines = answer.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let bold = Self.boldSpans(answer)
        let haystack = items.map { "\($0.from) \($0.subject) \($0.snippet)" }.joined(separator: " ").lowercased()
        // A bolded fact is grounded when its words appear in the input;
        // numbers must appear whole (an invented amount is the mistake
        // this catches).
        let ungrounded = bold.filter { span in
            let words = span.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            return !words.isEmpty && !words.allSatisfy { haystack.contains($0) }
        }
        return SummaryFormatCheck(
            lines: lines.count,
            everyLineIsABullet: !lines.isEmpty && lines.allSatisfy { $0.hasPrefix("- ") },
            hasBold: !bold.isEmpty,
            hasOtherMarkdown: lines.contains { $0.hasPrefix("#") || $0.contains("](") || $0.hasPrefix("* ") || $0.hasPrefix("1.") },
            ungroundedBold: ungrounded
        )
    }

    static func boldSpans(_ s: String) -> [String] {
        var out: [String] = []
        var rest = Substring(s)
        while let open = rest.range(of: "**"), let close = rest[open.upperBound...].range(of: "**") {
            out.append(String(rest[open.upperBound..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        return out
    }
}

struct SummaryEvalReport: CustomStringConvertible {
    let variant: String
    let cases: Int
    let formatPassRate: Double
    let groundedRate: Double
    let failures: [String]

    init(variant: String, checks: [(SummaryEvalCase, SummaryFormatCheck)]) {
        self.variant = variant
        cases = checks.count
        let n = Double(max(1, checks.count))
        formatPassRate = Double(checks.filter { $0.1.passes }.count) / n
        groundedRate = Double(checks.filter { $0.1.ungroundedBold.isEmpty }.count) / n
        failures = checks.filter { !$0.1.passes }.map { "\($0.0.title): lines \($0.1.lines), bullets \($0.1.everyLineIsABullet), bold \($0.1.hasBold), invented \($0.1.ungroundedBold)" }
    }

    var description: String {
        String(format: "%@: format %.0f%% · grounded %.0f%% · %d cases%@", variant, formatPassRate * 100, groundedRate * 100, cases,
               failures.isEmpty ? "" : "\n  failed: " + failures.joined(separator: "; "))
    }
}

enum SummaryEvaluation {
    static let cases: [SummaryEvalCase] = [
        SummaryEvalCase(title: "Today", items: [
            ("Priya Nair", "Q4 roadmap review", "Attaching the deck — can you look at slides 4–7 before Thursday?"),
            ("Tomáš", "Weekend ride?", "Forecast looks good for Saturday morning. Usual place at 8?"),
            ("GitHub", "[hey-pigeon] CI passed on main", "All 3 jobs succeeded."),
        ]),
        SummaryEvalCase(title: "Last 7 days", items: [
            ("Lufthansa", "Your trip to Lisbon: check-in opens", "Check-in for LH1172 is open."),
            ("Ana, Me (4)", "Contract draft v3", "I've accepted your changes to §4. One open point on the termination clause."),
            ("Stripe", "Invoice INV-0042 paid", "Your invoice for October was paid."),
            ("Apple", "Your receipt", "Thanks for your purchase."),
            ("Weekly Swift", "Issue 412", "Five articles on concurrency."),
        ]),
        SummaryEvalCase(title: "One newsletter", items: [
            ("Weekly Swift", "Issue 413", "Four articles and a podcast."),
        ]),
    ]

    /// The group prompt as the engine builds it (settings.rs build_summary_prompt).
    static func prompt(_ c: SummaryEvalCase) -> String {
        c.items.map { "From: \($0.from)\nSubject: \($0.subject)\n\($0.snippet)" }.joined(separator: "\n\n")
    }

    static func run(variant: String, instructions: String, provider: any ModelProvider = SystemModelProvider()) async throws -> SummaryEvalReport {
        var checks: [(SummaryEvalCase, SummaryFormatCheck)] = []
        for c in cases {
            let answer = try await provider.session(instructions: instructions).respond(to: prompt(c)).content
            checks.append((c, SummaryFormatCheck.check(answer, against: c.items)))
        }
        return SummaryEvalReport(variant: variant, checks: checks)
    }
}

struct SummaryEvaluationTests {
    @Test func formatCheckAcceptsTheRenderedSubsetAndRejectsTheRest() {
        let items = SummaryEvaluation.cases[0].items
        let good = "- **Priya Nair** wants a look at slides **4–7** before **Thursday**.\n- **Tomáš** proposes a ride **Saturday** at 8.\n- CI passed."
        #expect(SummaryFormatCheck.check(good, against: items).passes)
        let header = "## Today\n- **Priya Nair** sent the deck."
        #expect(!SummaryFormatCheck.check(header, against: items).passes)
        let noBold = "- Priya sent the deck."
        #expect(!SummaryFormatCheck.check(noBold, against: items).hasBold)
        let tooMany = (1...5).map { "- **Priya** item \($0)" }.joined(separator: "\n")
        #expect(SummaryFormatCheck.check(tooMany, against: items).lines == 5)
        let invented = "- **Priya Nair** asks for **€4,500** by Thursday."
        #expect(SummaryFormatCheck.check(invented, against: items).ungroundedBold == ["€4,500"])
        #expect(SummaryFormatCheck.boldSpans("a **b** c **d**") == ["b", "d"])
    }

    @MainActor
    @Test func theShippedPromptAsksForWhatTheCheckerChecks() {
        let p = MockEngine().aiPrompts().summary
        #expect(p.contains("starting with \"- \"") && p.contains("**") && p.contains("No headers"))
    }

    @Test(.enabled(if: AppleIntelligenceProvider.isAvailable, "needs Apple Intelligence on the device"))
    @MainActor
    func scoreTheShippedSummaryPromptOnDevice() async throws {
        try await OnDeviceModel.run {
            let shipped = AppModel(engine: MockEngine()).engine.aiPrompts().summary
            let variants: [(String, String)] = [
                ("shipped", shipped),
                // One candidate: the same rules with an example line, which small models follow better.
                ("with-example", shipped + "\n\nExample of one bullet: - **Acme** invoice **INV-12** for **€48** due **15 Nov**."),
            ]
            for (name, instructions) in variants {
                let report = try await SummaryEvaluation.run(variant: name, instructions: instructions)
                print(report)
                if name == "shipped" { #expect(report.formatPassRate >= 0.5) }
            }
        }
    }
}
