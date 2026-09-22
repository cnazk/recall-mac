import CryptoKit
import Foundation

/// A stable fingerprint of a payload's *content*, used as the deduplication key.
///
/// Two clips with the same hash are considered the same clip: the existing row is moved
/// to the top of the history rather than a duplicate being inserted.
public struct ContentHash: Codable, Sendable, Hashable, CustomStringConvertible {
    public let value: String

    public init(value: String) {
        self.value = value
    }

    public var description: String { value }

    public init(_ payload: ClipPayload) {
        var hasher = SHA256()
        hasher.update(data: Data(payload.kind.rawValue.utf8))
        hasher.update(data: Data([0]))

        switch payload {
        case .text(let text):
            hasher.update(data: Data(text.utf8))
        case .richText(let rtf, _):
            // Hash the RTF bytes: two clips that render the same but carry different
            // formatting are genuinely different clips.
            hasher.update(data: rtf)
        case .image(let image):
            // Hash the content digest rather than the bytes, so an image hashes the same
            // before and after it is offloaded to the blob store.
            hasher.update(data: Data(Self.digest(of: image).utf8))
        case .files(let refs):
            for ref in refs.sorted(by: { $0.url.path < $1.url.path }) {
                hasher.update(data: Data(ref.url.path.utf8))
                hasher.update(data: Data([0]))
            }
        case .url(let url):
            hasher.update(data: Data(url.absoluteString.utf8))
        case .color(let color):
            hasher.update(data: Data(color.raw.utf8))
        }

        self.value = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The blob-store address of an image: the SHA-256 of its plaintext bytes, which is
    /// exactly what ``ImagePayload/blobID`` holds once it has been offloaded.
    public static func digest(of image: ImagePayload) -> String {
        if let blobID = image.blobID { return blobID }
        return SHA256.hash(data: image.data).map { String(format: "%02x", $0) }.joined()
    }
}
