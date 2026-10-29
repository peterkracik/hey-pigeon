// Let the on-device model look at an attachment (docs/ios-intelligence.md,
// "iOS 27 › Attachment understanding"): read a receipt's total and
// merchant, pull a parcel's tracking number or a boarding pass's QR code,
// summarize a screenshotted PDF page, describe an image someone sent.
// iOS 27's model takes images in the prompt and ships two Vision-backed
// tools it calls itself — OCRTool and BarcodeReaderTool. On device only:
// an attachment never goes to OpenAI or to Apple's cloud, whatever the AI
// provider setting says. Images are downscaled first (token cost grows with
// size); a PDF's first page is rendered to an image.

import Foundation
import FoundationModels
import PDFKit
import UIKit
import Vision

/// The typed answer: what the attachment is and the fields worth acting on.
@Generable
struct AttachmentInsight: Equatable {
    @Generable
    enum Kind: String {
        case receipt, invoice, ticket, boardingPass, shipment, document, image, other
    }

    @Guide(description: "What the attachment is.")
    var kind: Kind
    @Guide(description: "Two or three sentences on what it shows and says, for someone who has not opened it.")
    var summary: String
    @Guide(description: "The merchant, carrier, airline or sender named on it; empty when none.")
    var merchant: String
    @Guide(description: "The total amount as printed, digits only with a decimal point (e.g. 48.00); empty when none.")
    var total: String
    @Guide(description: "The currency of the total as a code (EUR, USD); empty when none.")
    var currency: String
    @Guide(description: "The main date on it as ISO 8601 (2026-11-14), e.g. a due date, a travel date, a delivery date; empty when none.")
    var date: String
    @Guide(description: "A parcel tracking number exactly as printed or encoded in a barcode; empty when none.")
    var trackingNumber: String
    @Guide(description: "The parcel carrier; empty when none.")
    var carrier: String
    @Guide(description: "The flight number (e.g. LH1172); empty when none.")
    var flight: String
    @Guide(description: "The departure time as ISO 8601 with time (2026-11-14T07:35:00); empty when none.")
    var departure: String
    @Guide(description: "A booking, order or confirmation code; empty when none.")
    var confirmationCode: String
}

/// What the chips offer, derived from the fields: one tap each.
enum AttachmentAction: Equatable, Identifiable {
    /// A reminder the morning of the travel day (or the day before, when
    /// the departure is early).
    case remindTravelDay(Date, flight: String)
    /// A reminder the day before an amount is due.
    case remindBefore(Date, what: String)
    /// The tracking number to the clipboard.
    case saveTracking(String, carrier: String)
    /// The confirmation code to the clipboard.
    case saveCode(String)

    var id: String {
        switch self {
        case .remindTravelDay(let d, _): "travel:\(d.timeIntervalSince1970)"
        case .remindBefore(let d, _): "due:\(d.timeIntervalSince1970)"
        case .saveTracking(let n, _): "tracking:\(n)"
        case .saveCode(let c): "code:\(c)"
        }
    }

    var title: String {
        switch self {
        case .remindTravelDay(_, let flight): flight.isEmpty ? "Remind me on travel day" : "Remind me on travel day · \(flight)"
        case .remindBefore(_, let what): "Remind me before \(what)"
        case .saveTracking(let n, let carrier): carrier.isEmpty ? "Copy tracking \(n)" : "Copy \(carrier) tracking"
        case .saveCode(let c): "Copy code \(c)"
        }
    }

    var systemImage: String {
        switch self {
        case .remindTravelDay: "airplane"
        case .remindBefore: "clock"
        case .saveTracking: "shippingbox"
        case .saveCode: "doc.on.clipboard"
        }
    }
}

enum AttachmentUnderstanding {
    /// Longest side after downscaling: enough to read a receipt, a fraction
    /// of the tokens of a 12-megapixel photo.
    static let maxImageSide: CGFloat = 1_024

    static var isAvailable: Bool { AppleIntelligenceProvider.isAvailable }

    static let instructions = """
    You look at one email attachment for its recipient. Use the OCR tool to read any text in it and \
    the barcode tool to decode any barcode or QR code before answering. Fill the fields only from what \
    the attachment shows; leave a field empty rather than guess. Dates as ISO 8601. The summary is \
    two or three plain sentences.
    """

    /// Look at a file: images and PDFs only, on device only.
    static func explain(file: URL, mimeType: String, filename: String) async throws -> AttachmentInsight {
        guard isAvailable else { throw AttachmentError.modelUnavailable }
        guard let image = try image(for: file, mimeType: mimeType) else { throw AttachmentError.notExplainable }
        let session = SystemModelProvider().session(instructions: instructions, task: .completion, tools: [OCRTool(), BarcodeReaderTool()])
        do {
            let response = try await session.respond(to: Prompt {
                "The attachment is named \(filename)."
                Attachment(image)
            }, generating: AttachmentInsight.self)
            AiUsageLedger.shared.record(provider: AppleIntelligenceProvider.providerId, response.usage)
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            throw AttachmentError.model(FoundationModelsBackend.describe(error))
        }
    }

    /// The image the model gets: the file, or the PDF's first page, scaled
    /// so its longest side is at most `maxImageSide`.
    static func image(for file: URL, mimeType: String) throws -> UIImage? {
        let lower = mimeType.lowercased()
        if lower == "application/pdf" || file.pathExtension.lowercased() == "pdf" {
            guard let page = PDFDocument(url: file)?.page(at: 0) else { return nil }
            let box = page.bounds(for: .mediaBox)
            return page.thumbnail(of: targetSize(for: box.size), for: .mediaBox)
        }
        guard lower.hasPrefix("image/"), let data = try? Data(contentsOf: file), let image = UIImage(data: data) else { return nil }
        return downscaled(image)
    }

    static func targetSize(for size: CGSize) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > maxImageSide, longest > 0 else { return size }
        let scale = maxImageSide / longest
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    static func downscaled(_ image: UIImage) -> UIImage {
        let target = targetSize(for: image.size)
        guard target != image.size else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    // MARK: Chips

    /// One-tap actions from the fields: travel day for a flight or ticket,
    /// the day before a due amount, the tracking number, the code.
    static func actions(for insight: AttachmentInsight, now: Date = Date(), calendar cal: Calendar = .current) -> [AttachmentAction] {
        var out: [AttachmentAction] = []
        let departure = parseDate(insight.departure, cal: cal) ?? (insight.kind == .boardingPass || insight.kind == .ticket ? parseDate(insight.date, cal: cal) : nil)
        if let departure, departure > now {
            // 07:00 the same day, or 18:00 the evening before for an early start.
            let hour = cal.component(.hour, from: departure)
            let at = hour < 9
                ? cal.date(bySettingHour: 18, minute: 0, second: 0, of: cal.date(byAdding: .day, value: -1, to: departure) ?? departure)
                : cal.date(bySettingHour: 7, minute: 0, second: 0, of: departure)
            if let at, at > now { out.append(.remindTravelDay(at, flight: insight.flight)) }
        }
        if insight.kind == .invoice || insight.kind == .receipt, !insight.total.isEmpty,
           let due = parseDate(insight.date, cal: cal), due > now {
            let dayBefore = cal.date(byAdding: .day, value: -1, to: due) ?? due
            if let at = cal.date(bySettingHour: ReminderPreset.dayStart, minute: 0, second: 0, of: dayBefore), at > now {
                let what = [insight.total.isEmpty ? "" : "\(insight.total) \(insight.currency)".trimmingCharacters(in: .whitespaces),
                            insight.merchant].filter { !$0.isEmpty }.joined(separator: " to ")
                out.append(.remindBefore(at, what: what.isEmpty ? "it is due" : "\(what) is due"))
            }
        }
        if !insight.trackingNumber.isEmpty { out.append(.saveTracking(insight.trackingNumber, carrier: insight.carrier)) }
        if !insight.confirmationCode.isEmpty, insight.trackingNumber != insight.confirmationCode {
            out.append(.saveCode(insight.confirmationCode))
        }
        return out
    }

    /// ISO 8601 with or without a time; a bare date lands on the day's start.
    static func parseDate(_ s: String, cal: Calendar = .current) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.timeZone = cal.timeZone
        if let d = f.date(from: t) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: t + (t.contains("+") || t.hasSuffix("Z") ? "" : "Z")) {
            // A local time without a zone: read it as local.
            return cal.date(from: cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: d).settingZone(cal.timeZone))
        }
        f.formatOptions = [.withFullDate]
        return f.date(from: t)
    }

    // MARK: The triage hook's heuristic

    /// Cheap first: only subjects that smell like a receipt, a ticket or a
    /// shipment start the model, and only when an image or PDF is attached.
    static let actionableWords = [
        "receipt", "invoice", "payment", "order", "ticket", "boarding", "check-in", "itinerary", "booking",
        "reservation", "e-ticket", "shipment", "shipped", "tracking", "parcel", "delivery", "package", "confirmation",
    ]

    static func looksActionable(subject: String) -> Bool {
        let s = subject.lowercased()
        return actionableWords.contains { s.contains($0) }
    }
}

private extension DateComponents {
    func settingZone(_ zone: TimeZone) -> DateComponents {
        var c = self
        c.timeZone = zone
        return c
    }
}

enum AttachmentError: LocalizedError {
    case modelUnavailable
    case notExplainable
    case model(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable: "Apple Intelligence isn't available on this iPhone."
        case .notExplainable: "Only images and PDFs can be explained."
        case .model(let why): why
        }
    }
}
