import Foundation
import RecallCore

/// Cleans up messy copied text without changing what it says.
///
/// The rule of thumb: only ever remove characters a user did not mean to copy
/// (surrounding whitespace, zero-width marks, stray carriage returns). Interior content —
/// including indentation, which matters for code — is left alone.
public struct TextNormalizer: Sendable {
    public struct Options: Sendable {
        public var trimEdges: Bool
        public var normalizeLineEndings: Bool
        public var stripZeroWidth: Bool
        /// Collapses runs of 3+ blank lines down to one, for text pasted out of PDFs.
        public var collapseBlankLines: Bool
        /// Strips a common leading indent when every line shares one.
        public var dedent: Bool

        public static let `default` = Options(
            trimEdges: true, normalizeLineEndings: true, stripZeroWidth: true,
            collapseBlankLines: true, dedent: false
        )

        public static let none = Options(
            trimEdges: false, normalizeLineEndings: false, stripZeroWidth: false,
            collapseBlankLines: false, dedent: false
        )

        public init(trimEdges: Bool, normalizeLineEndings: Bool, stripZeroWidth: Bool, collapseBlankLines: Bool, dedent: Bool) {
            self.trimEdges = trimEdges
            self.normalizeLineEndings = normalizeLineEndings
            self.stripZeroWidth = stripZeroWidth
            self.collapseBlankLines = collapseBlankLines
            self.dedent = dedent
        }
    }

    private static let zeroWidth: Set<Character> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{00AD}"]

    private let options: Options

    public init(options: Options = .default) {
        self.options = options
    }

    public func normalize(_ text: String) -> String {
        var result = text

        if options.stripZeroWidth {
            result.removeAll { Self.zeroWidth.contains($0) }
        }
        if options.normalizeLineEndings {
            result = result.replacingOccurrences(of: "\r\n", with: "\n")
            result = result.replacingOccurrences(of: "\r", with: "\n")
            // Non-breaking spaces copied out of web pages behave badly in editors.
            result = result.replacingOccurrences(of: "\u{00A0}", with: " ")
        }
        if options.collapseBlankLines {
            while result.contains("\n\n\n") {
                result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            }
        }
        if options.dedent {
            result = Self.dedent(result)
        }
        if options.trimEdges {
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    /// Removes the longest whitespace prefix shared by every non-empty line.
    static func dedent(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let indents = lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" } }
        guard let shortest = indents.min(by: { $0.count < $1.count }), !shortest.isEmpty else { return text }
        guard indents.allSatisfy({ $0.hasPrefix(shortest) }) else { return text }
        return lines.map { line in
            line.hasPrefix(shortest) ? String(line.dropFirst(shortest.count)) : line
        }.joined(separator: "\n")
    }
}
