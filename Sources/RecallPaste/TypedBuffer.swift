import Foundation

/// The tail of what the user has just typed, used to spot snippet shortcodes.
///
/// Deliberately tiny and forgetful: it holds only enough characters to match the longest
/// shortcode, forgets everything the moment the user navigates or hits Return, and never
/// leaves the process. It is not a keylog, and the shape of the type is what keeps that
/// true rather than a promise in a comment.
public struct TypedBuffer: Sendable, Equatable {
    /// Longest run of characters kept. A shortcode is capped at 24 characters, so this
    /// leaves room for a word boundary and nothing more.
    public static let capacity = 32

    public private(set) var text: String = ""

    public init() {}

    public mutating func append(_ character: Character) {
        text.append(character)
        if text.count > Self.capacity {
            text.removeFirst(text.count - Self.capacity)
        }
    }

    public mutating func append(_ string: String) {
        for character in string { append(character) }
    }

    public mutating func deleteBackward() {
        guard !text.isEmpty else { return }
        text.removeLast()
    }

    /// Called whenever the user does something that means the previous characters are no
    /// longer a word in progress: arrow keys, Return, Escape, a click elsewhere.
    public mutating func reset() {
        text.removeAll(keepingCapacity: true)
    }

    public var isEmpty: Bool { text.isEmpty }
}
