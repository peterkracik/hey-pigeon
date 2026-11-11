// Translating a selection (AI/Translation.swift): the instruction and the
// language names the provider gets, the language choices, the cut of a
// long selection, where the translate circle sits beside a selection, the
// web view's selection report, and the sample inbox's answer. No view, no
// model.

import Foundation
import Testing
@testable import HeyPigeon

struct TranslationTests {
    @Test func theInstructionNamesTheLanguageAndStartsWithThePrefix() {
        let s = Translation.instruction(to: "Slovak")
        #expect(s.hasPrefix(Translation.instructionPrefix + " Slovak."))
        #expect(s.contains("already in Slovak"))
        #expect(s.hasSuffix("nothing else."))
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
            _ = try await engine.aiEditText(instruction: Translation.instruction(to: "Slovak"), text: "Hello",
                                            history: nil, context: nil,
                                            expectedProvider: AIAssist.expectedProvider(shown))
        }
        let now = try engine.aiStatus()
        #expect(now.answersInAppleCloud)
        let out = try await engine.aiEditText(instruction: Translation.instruction(to: "Slovak"), text: "Hello",
                                              history: nil, context: nil,
                                              expectedProvider: AIAssist.expectedProvider(now))
        #expect(out == "[Slovak] Hello")
    }

    @Test func theSampleInboxEchoesTheSelectionInTheLanguage() async throws {
        let out = try await MockEngine().aiEditText(instruction: Translation.instruction(to: "Slovak"), text: "Hello", history: nil)
        #expect(out == "[Slovak] Hello")
    }
}
