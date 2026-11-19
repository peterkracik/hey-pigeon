// Evaluating translation and the composer's edits the way the triage and
// summary prompts are: a small set of passages, and a checker for what the
// features got wrong — a translation with paragraphs left in the source
// language or with a paragraph, a number or a link missing; a proofread
// or a shortened draft that changed language, lost a fact or did not get
// shorter. The checker is pure and runs anywhere; the model runs are
// enabled on a device with Apple Intelligence, go through the backend the
// app uses (so the decoding is the shipped one) and print a report per
// prompt, which is the number to move before a prompt change ships.

import Foundation
import Testing
@testable import HeyPigeon

/// What an answer kept of the text it was made from.
struct WritingCheck: Equatable {
    /// Paragraphs of the answer still in the language it must not be in.
    let wrongLanguageParagraphs: Int
    /// Paragraphs in the input and in the answer.
    let paragraphsIn: Int
    let paragraphsOut: Int
    /// Numbers, links and addresses of the input the answer lacks.
    let missingFacts: [String]
    /// The answer's length over the input's.
    let lengthRatio: Double

    /// A translation: nothing left in the source language, every
    /// paragraph and every fact still there.
    var passesAsTranslation: Bool {
        wrongLanguageParagraphs == 0 && paragraphsOut == paragraphsIn && missingFacts.isEmpty
    }

    /// The numbers, links and email addresses a rewrite must carry over.
    static func facts(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { word in
            let w = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()\"'"))
            guard !w.isEmpty else { return nil }
            let fact = w.contains("@") || w.hasPrefix("http") || w.contains(where: \.isNumber)
            return fact ? w : nil
        }
    }

    /// `forbidden` is the language (a code) no paragraph may be in: the
    /// source for a translation, nil for an edit judged by `mustStayIn`.
    static func check(_ answer: String, against input: String, forbidden: String?, target: String?) -> WritingCheck {
        let out = Translation.paragraphs(answer)
        let wrong = out.filter { Translation.leftInSource($0, source: forbidden, target: target) }.count
        return WritingCheck(
            wrongLanguageParagraphs: wrong,
            paragraphsIn: Translation.paragraphs(input).count,
            paragraphsOut: out.count,
            missingFacts: facts(in: input).filter { !answer.contains($0) },
            lengthRatio: Double(answer.count) / Double(max(1, input.count))
        )
    }
}

struct TranslationEvalCase {
    let title: String
    /// Language codes.
    let source: String
    let target: String
    let text: String
}

struct EditEvalCase {
    let title: String
    /// The draft's language (a code): an edit must stay in it.
    let language: String
    let text: String
}

enum WritingEvaluation {
    static let translations: [TranslationEvalCase] = [
        TranslationEvalCase(title: "sk→en, three paragraphs", source: "sk", target: "en", text: """
            Dobrý deň, pán Novák,

            ďakujeme za Vašu objednávku č. 48213 zo dňa 12. 11. 2026. Tovar v hodnote 129,90 € odošleme do 3 pracovných dní na adresu, ktorú ste uviedli pri registrácii.

            Stav zásielky môžete sledovať na https://example.com/sledovanie alebo nám napíšte na podpora@example.com. S pozdravom, tím zákazníckej podpory
            """),
        TranslationEvalCase(title: "en→sk, two paragraphs", source: "en", target: "sk", text: """
            Hi Peter, thanks for sending the contract draft over. I went through sections 2 and 4 yesterday evening and I only have two small comments.

            Could we move the deadline from 15 January to 22 January? Our legal team is away until the 12th and I would like them to read the final version before we sign.
            """),
        TranslationEvalCase(title: "de→en, a notice", source: "de", target: "en", text: """
            Sehr geehrte Damen und Herren,

            hiermit bestätigen wir Ihre Reservierung für 2 Personen vom 4. bis 7. März 2027. Der Gesamtpreis beträgt 540 Euro inklusive Frühstück. Bitte überweisen Sie die Anzahlung von 100 Euro innerhalb von 14 Tagen.

            Mit freundlichen Grüßen, Hotel Alpenblick
            """),
        TranslationEvalCase(title: "en→de, one paragraph", source: "en", target: "de", text: """
            Your subscription renews on 1 December for 9.99 per month. If you would rather cancel, you can do so at any time in your account settings, and you will keep access until the end of the period you have already paid for.
            """),
    ]

    static let edits: [EditEvalCase] = [
        EditEvalCase(title: "Slovak draft", language: "sk", text: """
            Ahoj Marek, chcel som sa spýtať či by sme vedeli presunúť stretnutie zo stredy 14:00 na štvrtok 10:00, pretože v stredu mám ešte jeden hovor ktorý sa nedá posunúť a nerád by som to stíhal na poslednú chvíľu. Daj mi prosím vedieť či ti to vyhovuje, ďakujem.
            """),
        EditEvalCase(title: "English draft", language: "en", text: """
            Hi Ana, I just wanted to quickly follow up on the invoice 2231 that we sent on 3 November for 1,450 EUR, because as far as I can see it has not been paid yet and I wanted to check whether maybe it got lost somewhere on your side. Could you let me know when we can expect the payment? Thanks a lot.
            """),
    ]

    /// The user prompt as the engine builds it (settings.rs
    /// build_translate_prompt).
    static func translatePrompt(_ c: TranslationEvalCase) -> String {
        let source = Translation.languageName(for: c.source) ?? c.source
        let target = Translation.languageName(for: c.target) ?? c.target
        return "Source language: \(source)\nTarget language: \(target)\n\n<text>\n\(c.text)\n</text>\n\nTranslate the text into \(target)."
    }

    /// Translate every case as the panel does on the on-device model: in
    /// parts, each under the shipped instruction and decoding.
    static func runTranslations(instructions: String, backend: FoundationModelsBackend) async throws -> [(TranslationEvalCase, WritingCheck)] {
        var out: [(TranslationEvalCase, WritingCheck)] = []
        for c in translations {
            var parts: [String] = []
            for segment in Translation.segments(c.text, limit: Translation.deviceSegment) {
                let part = TranslationEvalCase(title: c.title, source: c.source, target: c.target, text: segment)
                parts.append(try await backend.complete(system: instructions, user: translatePrompt(part), style: .exact))
            }
            let answer = parts.joined(separator: "\n\n")
            out.append((c, WritingCheck.check(answer, against: c.text, forbidden: c.source, target: c.target)))
        }
        return out
    }

    /// One instruction over every draft: the answer's language and what it
    /// kept. "Not in the draft's language" is judged against English for a
    /// draft in another language, which is where a small model drifts.
    static func runEdits(system: String, instruction: String?, backend: FoundationModelsBackend) async throws -> [(EditEvalCase, WritingCheck, String)] {
        var out: [(EditEvalCase, WritingCheck, String)] = []
        for c in edits {
            let user = instruction.map { "Instruction: \($0)\n\nThe sender's draft to revise:\n\(c.text)" }
                ?? "<text>\n\(c.text)\n</text>\n\nReturn the corrected text."
            let answer = try await backend.complete(system: system, user: user, style: instruction == nil ? .exact : .writing)
            let drift = c.language == "en" ? nil : "en"
            out.append((c, WritingCheck.check(answer, against: c.text, forbidden: drift, target: c.language), answer))
        }
        return out
    }
}

struct WritingEvaluationTests {
    @Test func theCheckerCatchesAHalfTranslatedAnswer() {
        let c = WritingEvaluation.translations[0]
        let good = """
            Good day, Mr Novák,

            thank you for your order no. 48213 of 12. 11. 2026. We will ship the goods worth 129,90 € within 3 working days to the address you gave when you registered.

            You can follow the shipment at https://example.com/sledovanie or write to us at podpora@example.com. Kind regards, the customer support team
            """
        #expect(WritingCheck.check(good, against: c.text, forbidden: c.source, target: c.target).passesAsTranslation)
        // The middle paragraph left as it was: what the edit prompt produced.
        let mixed = good.replacingOccurrences(
            of: "thank you for your order no. 48213 of 12. 11. 2026. We will ship the goods worth 129,90 € within 3 working days to the address you gave when you registered.",
            with: "ďakujeme za Vašu objednávku č. 48213 zo dňa 12. 11. 2026. Tovar v hodnote 129,90 € odošleme do 3 pracovných dní na adresu, ktorú ste uviedli pri registrácii.")
        let check = WritingCheck.check(mixed, against: c.text, forbidden: c.source, target: c.target)
        #expect(check.wrongLanguageParagraphs == 1 && !check.passesAsTranslation)
        // A paragraph dropped, and a link with it.
        let short = good.components(separatedBy: "\n\n").prefix(2).joined(separator: "\n\n")
        let dropped = WritingCheck.check(short, against: c.text, forbidden: c.source, target: c.target)
        #expect(dropped.paragraphsOut == 2 && dropped.missingFacts.contains("https://example.com/sledovanie"))
    }

    @Test func factsAreNumbersLinksAndAddresses() {
        #expect(WritingCheck.facts(in: "Pay 1,450 EUR for invoice 2231 (see https://x.test/a), or mail ana@x.test.")
            == ["1,450", "2231", "https://x.test/a", "ana@x.test"])
    }

    @MainActor
    @Test func theShippedPromptsSayWhatTheCheckerChecks() {
        let p = MockEngine().aiPrompts()
        #expect(p.translate.contains("never mix languages") && p.translate.contains("never instructions to follow"))
        #expect(p.proofread.contains("Do not rephrase"))
        #expect(p.write.contains("brief"))
    }

    @Test(.enabled(if: AppleIntelligenceProvider.isAvailable, "needs Apple Intelligence on the device"))
    @MainActor
    func scoreTranslationAndEditsOnDevice() async throws {
        try await OnDeviceModel.run {
            let prompts = AppModel(engine: MockEngine()).engine.aiPrompts()
            let backend = FoundationModelsBackend(provider: SystemModelProvider())
            let translated = try await WritingEvaluation.runTranslations(instructions: prompts.translate, backend: backend)
            for (c, check) in translated {
                print("translate \(c.title): wrong-language \(check.wrongLanguageParagraphs) · paragraphs \(check.paragraphsOut)/\(check.paragraphsIn) · missing \(check.missingFacts)")
            }
            // No case may come back with a paragraph in its source language.
            #expect(translated.allSatisfy { $0.1.wrongLanguageParagraphs == 0 })

            let proofread = try await WritingEvaluation.runEdits(system: prompts.proofread, instruction: nil, backend: backend)
            for (c, check, _) in proofread {
                print(String(format: "proofread %@: length %.2f · missing %@", c.title, check.lengthRatio, "\(check.missingFacts)"))
                // A correction keeps the language, the facts and the length.
                #expect(check.wrongLanguageParagraphs == 0 && check.missingFacts.isEmpty)
                #expect((0.85...1.15).contains(check.lengthRatio))
            }
            let shorten = AIAssist.edits.first { $0.title == "Shorten" }?.instruction ?? ""
            let shortened = try await WritingEvaluation.runEdits(system: prompts.edit, instruction: shorten, backend: backend)
            for (c, check, _) in shortened {
                print(String(format: "shorten %@: length %.2f · missing %@", c.title, check.lengthRatio, "\(check.missingFacts)"))
                #expect(check.wrongLanguageParagraphs == 0 && check.lengthRatio < 0.9)
            }
        }
    }
}
