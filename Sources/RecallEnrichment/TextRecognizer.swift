import Foundation
import RecallCore
import Vision

/// Runs OCR over copied images so their text is searchable, and backs the
/// screen-capture-to-text hotkey.
public struct TextRecognizer: Sendable {
    public init() {}

    /// Recognised text, newline-separated, or nil when the image has none.
    public func recognizeText(in imageData: Data) async throws -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Without this the request recognises `en-US` and nothing else, because that is
        // what `recognitionLanguages` defaults to. A screenshot of Persian text came back
        // as "Lis palen" or as nothing at all — not a failure anyone would read as a
        // language problem.
        //
        // Detection beats naming the languages ourselves, and by more than seemed likely:
        // asking for `["en-US", "ar-SA"]` explicitly read the same Persian sample as
        // English gibberish, because the list is a priority order and English won. Left to
        // detect, the same image reads correctly, and English images still read as English.
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(data: imageData, options: [:])
        try handler.perform([request])

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// Adds OCR text to copied screenshots.
public struct ImageTextEnricher: Enricher {
    public let identifier = EnricherID.imageText
    private let recognizer = TextRecognizer()

    public init() {}

    public func canEnrich(_ item: ClipItem) -> Bool {
        guard case .image = item.payload else { return false }
        return item.ocrText == nil
    }

    public func enrich(_ item: ClipItem) async throws -> ClipItem? {
        guard case .image(let image) = item.payload else { return nil }
        guard let text = try await recognizer.recognizeText(in: image.data) else { return nil }
        var updated = item
        updated.ocrText = text
        return updated
    }
}

/// Finds QR codes in an image, which is how two-factor setup arrives in the real world.
public struct BarcodeReader: Sendable {
    public init() {}

    /// Every payload string found, in no particular order.
    public func payloads(in imageData: Data) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr, .aztec, .dataMatrix]

        let handler = VNImageRequestHandler(data: imageData, options: [:])
        try handler.perform([request])

        return (request.results ?? []).compactMap { $0.payloadStringValue }
    }

    /// The first two-factor setup link in the image, if there is one.
    public func twoFactorURI(in imageData: Data) throws -> String? {
        try payloads(in: imageData).first { payload in
            let lowered = payload.lowercased()
            return lowered.hasPrefix("otpauth://") || lowered.hasPrefix("otpauth-migration://")
        }
    }
}
