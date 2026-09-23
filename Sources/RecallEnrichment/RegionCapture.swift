import AppKit
import Foundation
import RecallCore

/// Grabs a region of the screen and reads the text in it.
///
/// Backed by `/usr/sbin/screencapture` rather than ScreenCaptureKit: the system binary
/// already draws the crosshair selection every Mac user knows, handles Escape, spans
/// displays, and prompts for Screen Recording permission itself. Reimplementing that to
/// own the pixels would be a worse version of something already on the machine.
public struct RegionCapture: Sendable {
    public struct Result: Sendable {
        public let text: String?
        public let image: ImagePayload

        public init(text: String?, image: ImagePayload) {
            self.text = text
            self.image = image
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case cancelled
        case captureFailed(Int32)
        case unreadableImage

        public var description: String {
            switch self {
            case .cancelled: String(localized: "Screen capture was cancelled.")
            case .captureFailed(let code): String(localized: "Screen capture failed (code \(code)).")
            case .unreadableImage: String(localized: "The captured region could not be read.")
            }
        }
    }

    private let recognizer = TextRecognizer()
    private let executable: URL

    public init(executable: URL = URL(fileURLWithPath: "/usr/sbin/screencapture")) {
        self.executable = executable
    }

    /// Prompts the user to drag out a region, then recognises the text in it.
    ///
    /// Returns `.cancelled` when the user presses Escape — a cancel is a decision, not an
    /// error, and must never leave anything behind in history.
    public func captureRegion() async throws -> Result {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recall-capture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        try await run(arguments: ["-i", "-x", "-t", "png", url.path])

        // screencapture exits 0 on cancel and simply writes nothing.
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure.cancelled
        }

        let data = try Data(contentsOf: url)
        guard let rep = NSBitmapImageRep(data: data) else { throw Failure.unreadableImage }

        let image = ImagePayload(
            data: data,
            uti: "public.png",
            pixelWidth: rep.pixelsWide,
            pixelHeight: rep.pixelsHigh
        )

        let text = try? await recognizer.recognizeText(in: data)
        return Result(text: text, image: image)
    }

    private func run(arguments: [String]) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: Failure.captureFailed(process.terminationStatus))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
