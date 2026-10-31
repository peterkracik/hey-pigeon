// The on-device provider's pure parts (no model needed): the prompt
// splitter the context-window handling rests on, the triage priority
// mapping, and the mock engine's provider resolution the Settings rows use.

import HeyPigeonCore
import Testing
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
@testable import HeyPigeon

struct OnDeviceAITests {
    @Test func chunksPackParagraphsUpToTheBudget() {
        let text = ["aaaa", "bbbb", "cccc", "dddd"].joined(separator: "\n\n")
        // 4 + 2 + 4 = 10 fits; a third paragraph would not.
        #expect(AppleIntelligenceProvider.chunks(text, budget: 10) == ["aaaa\n\nbbbb", "cccc\n\ndddd"])
        #expect(AppleIntelligenceProvider.chunks(text, budget: 100) == [text])
        #expect(AppleIntelligenceProvider.chunks("", budget: 10).isEmpty)
    }

    @Test func chunksCutAParagraphLongerThanTheBudget() {
        let long = String(repeating: "x", count: 25)
        let chunks = AppleIntelligenceProvider.chunks(long + "\n\nshort", budget: 10)
        #expect(chunks.count == 2)
        #expect(chunks[0].count == 10)
        #expect(chunks[1] == "short")
    }

    @Test func triagePriorityMapsOntoTheEngineEnum() {
        #expect(TriagePriority.spam.ffi == .spam)
        #expect(TriagePriority.high.ffi == .high)
    }

    @MainActor
    @Test func mockResolvesTheProviderLikeTheEngine() async throws {
        let engine = MockEngine()
        // No model, no key: nothing answers.
        var s = try engine.aiStatus()
        #expect(!s.configured && s.preferredProviderId == "openai")
        // The on-device model alone answers, and is the default preference.
        engine.onDeviceAI = true
        s = try engine.aiStatus()
        #expect(s.configured && s.answersOnDevice && s.preferredProviderId == "apple")
        // Preferring the key without one still answers on device.
        try engine.setAIProvider(.openai)
        s = try engine.aiStatus()
        #expect(s.preferredProviderId == "openai" && s.answersOnDevice)
        // With a key, the preference wins.
        try await engine.setAIKey("sk-test")
        s = try engine.aiStatus()
        #expect(s.providerId == "openai" && s.openaiConfigured)
        // Triage: on device is enough, Jev stays selectable.
        var t = try engine.triageStatus()
        #expect(t.configured && t.classifierId == "apple" && !t.jevConfigured)
        try engine.setTriageClassifier(.jev)
        t = try engine.triageStatus()
        #expect(t.classifierId == "jev" && t.configured)
    }

    /// Apple's cloud is the third provider: preferred when it is the only
    /// Apple model, second to the device by default, and the fallback order
    /// decides when the preferred one cannot answer.
    @MainActor
    @Test func mockResolvesAppleCloudAndTheFallbackOrder() async throws {
        let engine = MockEngine()
        engine.cloudAI = true
        var s = try engine.aiStatus()
        #expect(s.configured && s.answersInAppleCloud && s.preferredProviderId == "apple-cloud")
        #expect(s.availableProviderIds == ["apple-cloud"])
        #expect(s.fallbackOrder == ["apple", "apple-cloud", "openai"])
        engine.onDeviceAI = true
        s = try engine.aiStatus()
        #expect(s.preferredProviderId == "apple" && s.answersOnDevice)
        #expect(s.isAvailable(.appleCloud) && s.isAvailable(.apple) && !s.isAvailable(.openai))
        // Prefer the cloud; lose it; the order falls back to the device.
        try engine.setAIProvider(.appleCloud)
        #expect(try engine.aiStatus().answersInAppleCloud)
        engine.cloudAI = false
        #expect(try engine.aiStatus().answersOnDevice)
        // "Stay on this iPhone": OpenAI is never the fallback.
        try engine.setAIFallback(AIFallbackPreset.onDeviceOnly.order)
        try await engine.setAIKey("sk-test")
        engine.onDeviceAI = false
        s = try engine.aiStatus()
        #expect(s.fallbackOrder == ["apple"])
        #expect(!s.configured)
        // Classifiers follow: the cloud is a classifier too.
        engine.cloudAI = true
        let t = try engine.triageStatus()
        #expect(t.isAvailable(.appleCloud) && !t.isAvailable(.apple) && t.classifierId == "apple-cloud")
    }

    @Test func fallbackPresetsRoundTripThroughTheSyncedOrder() {
        #expect(AIFallbackPreset(order: []) == .privateFirst)
        #expect(AIFallbackPreset(order: ["apple", "apple-cloud", "openai"]) == .privateFirst)
        #expect(AIFallbackPreset(order: ["apple-cloud", "apple", "openai"]) == .cloudFirst)
        #expect(AIFallbackPreset(order: ["apple"]) == .onDeviceOnly)
        #expect(AIFallbackPreset(order: ["openai"]) == .privateFirst) // unknown shape → default
        #expect(AIProvider(rawValue: "anthropic") == .other("anthropic"))
        #expect(AIProvider.appleCloud.rawValue == "apple-cloud")
    }

    @Test func triagePromptMapsNamesToKnownIdsOnce() {
        let labels = [TriageLabel(id: "a", name: "Invoices"), TriageLabel(id: "b", name: "Travel")]
        #expect(TriagePrompt.labelIds(for: ["invoices", "Travel", "Invoices", "Nope"], in: labels) == ["a", "b"])
        #expect(TriagePrompt.prompt(from: "x@y", subject: "S", snippet: "P", labels: []).contains("Available labels: (none)"))
        #expect(TriagePromptVariant.candidates.map(\.id) == ["shipped", "explicit", "terse"])
        #expect(TriagePrompt.instructions == TriagePromptVariant.shipped.instructions)
    }

    @Test func usageLedgerCountsPerProviderAndFormats() {
        let defaults = UserDefaults(suiteName: "test.ai.usage.\(UUID().uuidString)")!
        let ledger = AiUsageLedger(defaults: defaults)
        ledger.record(provider: "apple", input: 1_200, output: 300)
        ledger.record(provider: "apple", input: 12_000, output: 10)
        ledger.record(provider: "apple-cloud", input: 5, output: 5)
        let apple = ledger.byProvider["apple"]!
        #expect(apple.requests == 2 && apple.inputTokens == 13_200 && apple.outputTokens == 310)
        #expect(AiUsageLedger.line(apple, price: nil) == "2 requests · 13K in / 310 out")
        #expect(AiUsageLedger.line(ledger.byProvider["apple-cloud"]!, price: nil) == "1 request · 5 in / 5 out")
        #expect(AiUsageLedger.line(apple, price: TokenPrice(inputPerMillion: 1_000, outputPerMillion: 1_000)) == "2 requests · 13K in / 310 out · $13.51")
        // Persisted: a second ledger over the same defaults sees it.
        #expect(AiUsageLedger(defaults: defaults).byProvider["apple"] == apple)
        ledger.reset()
        #expect(ledger.byProvider.isEmpty)
    }
}

/// Attachment understanding's pure parts: the heuristic that starts it, the
/// image sizing, the date parsing and the chips derived from the fields.
struct AttachmentUnderstandingTests {
    private func insight(kind: AttachmentInsight.Kind, date: String = "", departure: String = "", total: String = "",
                         currency: String = "", merchant: String = "", tracking: String = "", carrier: String = "",
                         flight: String = "", code: String = "") -> AttachmentInsight {
        AttachmentInsight(kind: kind, summary: "", merchant: merchant, total: total, currency: currency, date: date,
                          trackingNumber: tracking, carrier: carrier, flight: flight, departure: departure, confirmationCode: code)
    }

    @Test func onlyReceiptTicketAndShipmentSubjectsStartTheModel() {
        #expect(AttachmentUnderstanding.looksActionable(subject: "Your receipt from Apple"))
        #expect(AttachmentUnderstanding.looksActionable(subject: "Check-in opens: BTS → LIS"))
        #expect(AttachmentUnderstanding.looksActionable(subject: "Your parcel has shipped"))
        #expect(!AttachmentUnderstanding.looksActionable(subject: "Q4 roadmap review"))
        #expect(!AttachmentUnderstanding.looksActionable(subject: "Weekend ride?"))
    }

    @Test func imagesAreDownscaledToTheLongestSide() {
        #expect(AttachmentUnderstanding.targetSize(for: CGSize(width: 4_032, height: 3_024)) == CGSize(width: 1_024, height: 768))
        #expect(AttachmentUnderstanding.targetSize(for: CGSize(width: 600, height: 900)) == CGSize(width: 600, height: 900))
        #if canImport(UIKit)
        let big = UIGraphicsImageRenderer(size: CGSize(width: 2_000, height: 1_000)).image { _ in }
        #else
        let big = NSImage(size: CGSize(width: 2_000, height: 1_000))
        #endif
        let small = AttachmentUnderstanding.downscaled(big)
        #expect(max(small.size.width, small.size.height) <= AttachmentUnderstanding.maxImageSide)
    }

    @Test func datesParseWithAndWithoutATime() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Bratislava")!
        let day = try #require(AttachmentUnderstanding.parseDate("2026-11-14", cal: cal))
        #expect(cal.dateComponents([.year, .month, .day], from: day) == DateComponents(year: 2026, month: 11, day: 14))
        let local = try #require(AttachmentUnderstanding.parseDate("2026-11-14T07:35:00", cal: cal))
        #expect(cal.component(.hour, from: local) == 7)
        #expect(AttachmentUnderstanding.parseDate("", cal: cal) == nil)
        #expect(AttachmentUnderstanding.parseDate("soon", cal: cal) == nil)
    }

    @Test func chipsFollowTheFields() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Bratislava")!
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12)))
        // An early flight: the evening before. A late one: the morning of.
        let early = AttachmentUnderstanding.actions(for: insight(kind: .boardingPass, departure: "2026-11-14T07:35:00", flight: "LH1172", code: "ABC123"), now: now, calendar: cal)
        guard case .remindTravelDay(let at, let flight) = early[0] else { Issue.record("no travel chip"); return }
        #expect(flight == "LH1172")
        #expect(cal.dateComponents([.day, .hour], from: at) == DateComponents(day: 13, hour: 18))
        #expect(early.contains(.saveCode("ABC123")))
        let late = AttachmentUnderstanding.actions(for: insight(kind: .ticket, date: "2026-11-14T19:00:00"), now: now, calendar: cal)
        guard case .remindTravelDay(let at2, _) = late[0] else { Issue.record("no travel chip"); return }
        #expect(cal.dateComponents([.day, .hour], from: at2) == DateComponents(day: 14, hour: 7))
        // An invoice due later: the day before at the day-start hour; a receipt already paid (past date): nothing.
        let invoice = AttachmentUnderstanding.actions(for: insight(kind: .invoice, date: "2026-11-20", total: "48.00", currency: "EUR", merchant: "Cloudhost"), now: now, calendar: cal)
        guard case .remindBefore(let due, let what) = invoice[0] else { Issue.record("no due chip"); return }
        #expect(cal.component(.day, from: due) == 19 && what == "48.00 EUR to Cloudhost is due")
        #expect(AttachmentUnderstanding.actions(for: insight(kind: .receipt, date: "2026-10-01", total: "23.90"), now: now, calendar: cal).isEmpty)
        // A shipment: the tracking number, once even when the code repeats it.
        let parcel = AttachmentUnderstanding.actions(for: insight(kind: .shipment, tracking: "1Z999", carrier: "UPS", code: "1Z999"), now: now, calendar: cal)
        #expect(parcel == [.saveTracking("1Z999", carrier: "UPS")])
        #expect(parcel[0].title == "Copy UPS tracking")
        #expect(AttachmentUnderstanding.actions(for: insight(kind: .image), now: now, calendar: cal).isEmpty)
    }

    @Test func attachmentItemsKnowWhatTheModelCanLookAt() {
        let pdf = AttachmentItem(threadId: "t", messageId: "m", attachmentId: "a", filename: "x.pdf", mimeType: "application/octet-stream", size: 2_048)
        #expect(pdf.isPDF && pdf.isExplainable && pdf.sizeText != nil)
        let zip = AttachmentItem(threadId: "t", messageId: "m", attachmentId: "b", filename: "x.zip", mimeType: "application/zip", size: 0)
        #expect(!zip.isExplainable && zip.sizeText == nil)
        #expect(AttachmentItem(threadId: "t", messageId: "m", attachmentId: "c", filename: "p", mimeType: "image/HEIC", size: 1).isImage)
    }
}
