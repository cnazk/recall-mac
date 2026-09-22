import Foundation
import RecallCore

/// Decides what a piece of plain text really *is*.
///
/// A copied `#ff8800` is a colour, `https://example.com` is a link, and everything else
/// is text. Classifying at capture time is what lets the UI show a swatch or a favicon
/// without re-parsing on every render.
public struct PayloadClassifier: Sendable {
    public init() {}

    public func classify(text: String) -> ClipPayload {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let color = HexColor(parsing: trimmed), Self.looksLikeAColor(trimmed) {
            return .color(color)
        }
        if let url = Self.singleURL(in: trimmed) {
            return .url(url)
        }
        return .text(text)
    }

    /// A bare run of hex digits is only a colour if it could not be something else.
    /// `483920` is a valid hex colour *and* a plausible one-time code, so without a
    /// leading `#` we require at least one `a`–`f` before calling it a colour.
    static func looksLikeAColor(_ text: String) -> Bool {
        if text.hasPrefix("#") { return true }
        guard text.count == 6 || text.count == 8 else { return false }
        return text.lowercased().contains { "abcdef".contains($0) }
    }

    /// Returns a URL only when the whole clip is one link — a paragraph that happens to
    /// contain a link is still text.
    static func singleURL(in text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace) else { return nil }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return nil }
        guard ["http", "https", "ftp", "mailto", "file"].contains(scheme) else { return nil }
        guard url.host != nil || scheme == "mailto" || scheme == "file" else { return nil }
        return url
    }
}
