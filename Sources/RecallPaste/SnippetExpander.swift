import Foundation
import RecallCore

/// Matches typed shortcodes such as `:sig` against saved snippets.
///
/// The matching itself is pure and testable here; the keystroke listening that feeds it
/// lives in the app layer, because it needs the Accessibility-trusted event tap.
public struct SnippetExpander: Sendable {
    /// Characters that end a shortcode. A code fires on the delimiter, not on every
    /// keystroke, so `:sign` never fires `:sig` first.
    public static let terminators: Set<Character> = [" ", "\t", "\n", "\r"]

    private let snippets: [String: UUID]

    /// - Parameter snippets: shortcode (including its leading marker) to item id.
    public init(snippets: [String: UUID]) {
        self.snippets = snippets
    }

    public init(items: [ClipItem]) {
        var map: [String: UUID] = [:]
        for item in items {
            if let code = item.snippetCode { map[code] = item.id }
        }
        self.init(snippets: map)
    }

    /// Given the characters typed so far, returns the snippet to expand and how many
    /// characters to delete before inserting it.
    public func match(typedBuffer buffer: String) -> (itemID: UUID, charactersToDelete: Int)? {
        guard let last = buffer.last, Self.terminators.contains(last) else { return nil }
        let candidate = String(buffer.dropLast())
        guard let token = candidate.split(whereSeparator: Self.terminators.contains).last else { return nil }
        guard let itemID = snippets[String(token)] else { return nil }
        // +1 for the terminator, which is consumed by the expansion.
        return (itemID, token.count + 1)
    }

    /// Validates a shortcode a user is trying to assign.
    public static func isValid(code: String) -> Bool {
        guard code.count >= 2, code.count <= 24 else { return false }
        guard let first = code.first, ":;/!".contains(first) else { return false }
        return code.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}
