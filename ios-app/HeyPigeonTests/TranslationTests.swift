// Translating a selection (AI/Translation.swift): the language names and
// codes, the language choices, the cut of a long selection and its parts,
// the check for a paragraph left in the source language, the line that
// says who translated, where the translate circle sits beside a selection,
// the web view's selection report, and the sample inbox's answer. No view,
// no model.

import Foundation
import Testing
@testable import HeyPigeon

struct TranslationTests {
    @Test func aLanguageNameHasItsCode() {
        #expect(Translation.code(for: "Slovak") == "sk")
        #expect(Translation.code(for: "English") == "en")
        #expect(Translation.code(for: "German") == "de")
        #expect(Translation.code(for: "Klingonish") == nil)
        #expect(Translation.same("pt-BR", "pt") && !Translation.same("sk", "cs"))
    }

    @Test func aPassageIsCutIntoPartsOnItsParagraphs() {
        let a = String(repeating: "Prvá veta odseku. ", count: 20).trimmingCharacters(in: .whitespaces)
        let b = "Druhý odsek.\nNa dvoch riadkoch."
        let text = "\(a)\n\n \n\(b)\r\n\r\nTretí."
        #expect(Translation.paragraphs(text) == [a, b, "Tretí."])
        // Everything fits one request for a large model.
        #expect(Translation.segments(text, limit: Translation.maxCharacters) == ["\(a)\n\n\(b)\n\nTretí."])
        // A small limit: the long paragraph alone, the short ones together.
        #expect(Translation.segments(text, limit: 370) == [a, "\(b)\n\nTretí."])
        // A paragraph over the limit is cut between sentences, nothing lost.
        let parts = Translation.segments(a, limit: 100)
        #expect(parts.count > 1 && parts.allSatisfy { $0.count <= 100 && $0.hasSuffix(".") })
        #expect(parts.joined(separator: " ") == a)
        // A sentence over the limit is cut on a word.
        let run = String(repeating: "slovo ", count: 60)
        #expect(Translation.segments(run, limit: 50).allSatisfy { $0.count <= 50 && !$0.hasPrefix(" ") })
    }

    @Test func aParagraphLeftInTheSourceLanguageIsNoticed() {
        let english = "Thank you for your order. We will ship the goods within three working days to the address you gave."
        let slovak = "Ďakujeme za Vašu objednávku. Tovar odošleme do troch pracovných dní na adresu, ktorú ste uviedli pri registrácii."
        #expect(Translation.detectedLanguage(of: english) == "en")
        #expect(Translation.detectedLanguage(of: slovak) == "sk")
        #expect(!Translation.leftInSource(english, source: "sk", target: "en"))
        #expect(Translation.leftInSource("\(english)\n\n\(slovak)", source: "sk", target: "en"))
        // Too short to tell, or no languages to compare: nothing is claimed.
        #expect(!Translation.leftInSource("Ďakujem.", source: "sk", target: "en"))
        #expect(!Translation.leftInSource(slovak, source: nil, target: "en"))
        #expect(!Translation.leftInSource(slovak, source: "sk", target: "sk"))
    }

    @Test func theOnDeviceModelsRoughLanguageIsNamed() {
        let knows: (String) -> Bool = { ["en", "de"].contains($0) }
        #expect(TranslationPanel.caution(language: "German", source: "English", supported: knows,
                                         sourceCode: "en", targetCode: "de") == nil)
        #expect(TranslationPanel.caution(language: "Slovak", source: "English", supported: knows,
                                         sourceCode: "en", targetCode: "sk")?.contains("not made for Slovak") == true)
        #expect(TranslationPanel.caution(language: "English", source: "Slovak", supported: knows,
                                         sourceCode: "sk", targetCode: "en")?.contains("not made for Slovak") == true)
        #expect(TranslationPanel.caution(language: "English", source: nil, supported: knows,
                                         sourceCode: nil, targetCode: "en") == nil)
    }

    @Test func languageNamesAreEnglishWhateverTheRegion() {
        #expect(Translation.languageName(for: "sk") == "Slovak")
        #expect(Translation.languageName(for: "en-US") == "English")
        #expect(Translation.languageName(for: "de_AT") == "German")
        #expect(Translation.languageName(for: "pt-BR") == "Portuguese")
    }

    @Test func choicesPutTheDevicesLanguagesFirstWithoutRepeats() {
        let c = Translation.choices(preferred: ["sk-SK", "en-GB", "sk"], picked: "Finnish")
        #expect(Array(c.prefix(2)) == ["Slovak", "English"])
        #expect(c.contains("Finnish"))
        #expect(c.filter { $0 == "Slovak" }.count == 1)
        #expect(c.filter { $0 == "English" }.count == 1)
        #expect(Set(Translation.common).isSubset(of: Set(c)))
    }

    @Test func aLongSelectionIsCutOnAWord() {
        let word = "slovo "
        let long = String(repeating: word, count: Translation.maxCharacters / word.count + 50)
        let cut = Translation.prepared(long)
        #expect(cut.count <= Translation.maxCharacters)
        #expect(cut.hasSuffix("slovo"))
        #expect(Translation.prepared("  short text\n") == "short text")
    }

    @Test func theCircleSitsRightOfTheSelectionWhenThereIsRoom() {
        let s = BodySelection(text: "x", rect: CGRect(x: 0, y: 0, width: 200, height: 40),
                              end: CGPoint(x: 120, y: 30), lineHeight: 20)
        let c = SelectionBadgeGeometry.center(for: s, width: 320)
        #expect(c.y == 30)
        #expect(c.x == 120 + SelectionBadgeGeometry.gap + SelectionBadgeGeometry.size / 2)
    }

    @Test func theCircleMovesUnderTheLineAtTheRightMargin() {
        let s = BodySelection(text: "x", rect: CGRect(x: 0, y: 0, width: 320, height: 40),
                              end: CGPoint(x: 315, y: 30), lineHeight: 20)
        let c = SelectionBadgeGeometry.center(for: s, width: 320)
        #expect(c.y > 40)
        // Pulled in so the whole circle is on screen.
        #expect(c.x + SelectionBadgeGeometry.size / 2 <= 320)
        #expect(c.x - SelectionBadgeGeometry.size / 2 >= 0)
    }

    @Test func theWebViewsReportBecomesASelection() throws {
        let s = try #require(BodySelection(message: [
            "text": "Dobrý deň", "x": 10, "y": 20, "width": 100, "height": 36, "endX": 90, "endY": 46, "lineHeight": 18,
        ]))
        #expect(s.text == "Dobrý deň")
        #expect(s.rect == CGRect(x: 10, y: 20, width: 100, height: 36))
        #expect(s.end == CGPoint(x: 90, y: 46))
        #expect(s.lineHeight == 18)
        #expect(s.isUsable)
        #expect(BodySelection(message: nil) == nil)
        #expect(BodySelection(message: ["x": 1]) == nil)
        #expect(BodySelection(message: ["text": "  \n"])?.isUsable == false)
    }

    /// The line under a translation is built from the provider the
    /// request was pinned to; after a refusal it says where Try again
    /// goes, since nothing was sent.
    @MainActor @Test func theFootnoteNamesTheProviderTheRequestWentTo() throws {
        let engine = MockEngine()
        let none = try engine.aiStatus()
        engine.onDeviceAI = true
        let device = try engine.aiStatus()
        #expect(TranslationPanel.footnote(shown: device, refused: false, wasCut: false)
            == "Translated on this \(Device.name).")
        #expect(TranslationPanel.footnote(shown: none, refused: false, wasCut: false)
            == "The selected text was sent to the AI provider.")
        #expect(TranslationPanel.footnote(shown: nil, refused: false, wasCut: true)
            .hasPrefix("The selected text was sent to the AI provider. Only the first "))
        #expect(TranslationPanel.footnote(shown: device, refused: true, wasCut: true)
            == "Try again translates on this \(Device.name).")
        #expect(TranslationPanel.footnote(shown: none, refused: true, wasCut: false)
            == "Try again sends the selected text to the AI provider.")
        // Apple's translation and a passage already in the language send nothing.
        #expect(TranslationPanel.footnote(route: .system, shown: nil, refused: false, wasCut: false)
            == "Translated on this \(Device.name) by Apple's translation. Nothing left the device.")
        #expect(TranslationPanel.footnote(route: .already, shown: none, refused: false, wasCut: false, language: "Slovak")
            == "The selection is already in Slovak. Nothing was sent.")
    }

    /// The panel's request: pinned to the provider read before it, it is
    /// refused when another one answers by then (here Apple's cloud after
    /// the device model went), and goes through once it names that one.
    @MainActor @Test func aTranslationIsPinnedToTheProviderItsFootnoteNames() async throws {
        let engine = MockEngine()
        engine.onDeviceAI = true
        engine.cloudAI = true
        let shown = try engine.aiStatus()
        engine.onDeviceAI = false
        await #expect(throws: AIProviderChanged.self) {
            _ = try await engine.aiTranslate(text: "Hello", source: "English", target: "Slovak",
                                             expectedProvider: AIAssist.expectedProvider(shown))
        }
        let now = try engine.aiStatus()
        #expect(now.answersInAppleCloud)
        let out = try await engine.aiTranslate(text: "Hello", source: nil, target: "Slovak",
                                               expectedProvider: AIAssist.expectedProvider(now))
        #expect(out == "[Slovak] Hello")
    }

    @Test func theSampleInboxEchoesTheSelectionInTheLanguage() async throws {
        let out = try await MockEngine().aiTranslate(text: "Hello", source: nil, target: "Slovak", expectedProvider: nil)
        #expect(out == "[Slovak] Hello")
    }
}
