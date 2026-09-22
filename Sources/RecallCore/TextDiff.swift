import Foundation

/// What changed between two clips.
///
/// Built on `CollectionDifference`, which is Myers' algorithm in the standard library —
/// there is no reason to hand-roll one, and a hand-rolled LCS would be the part most
/// likely to be quadratic on the day someone copies a large file twice.
public enum TextDiff {
    /// Lines for code, words for prose. See ``granularity(for:_:)``.
    public enum Granularity: Equatable, Sendable {
        case line
        case word
    }

    public enum Change: Equatable, Sendable {
        case unchanged
        case inserted
        case removed
    }

    public struct Segment: Equatable, Sendable, Identifiable {
        /// Position in the diff. Stable for as long as the two inputs are, which is all a
        /// list needs, and the alternative — the text itself — repeats constantly.
        public let id: Int
        public let change: Change
        public let text: String
    }

    public struct Result: Equatable, Sendable {
        public let granularity: Granularity
        public let segments: [Segment]

        public var insertedCount: Int { segments.count { $0.change == .inserted } }
        public var removedCount: Int { segments.count { $0.change == .removed } }
        public var isIdentical: Bool { segments.allSatisfy { $0.change == .unchanged } }

        /// The diff as text, in the shape everyone already recognises: `-` for what went,
        /// `+` for what arrived, a space for context.
        ///
        /// Runs of the same kind are joined into one line, so a word diff reads as a pair
        /// of before-and-after lines rather than one `+` per word.
        public func unifiedText() -> String {
            var lines: [String] = []
            var runChange: Change?
            var run: [String] = []

            func flush() {
                guard let runChange, !run.isEmpty else { return }
                let prefix = switch runChange {
                case .inserted: "+"
                case .removed: "-"
                case .unchanged: " "
                }
                lines.append(prefix + " " + run.joined(separator: granularity == .line ? "\n\(prefix) " : " "))
                run = []
            }

            for segment in segments {
                if segment.change != runChange {
                    flush()
                    runChange = segment.change
                }
                run.append(segment.text)
            }
            flush()
            return lines.joined(separator: "\n")
        }
    }

    /// - Parameter granularity: pass one to override the choice made by
    ///   ``granularity(for:_:)``.
    public static func between(
        _ old: String,
        _ new: String,
        granularity chosen: Granularity? = nil
    ) -> Result {
        let granularity = chosen ?? Self.granularity(for: old, new)
        let oldTokens = tokens(of: old, granularity: granularity)
        let newTokens = tokens(of: new, granularity: granularity)

        return Result(granularity: granularity, segments: align(oldTokens, newTokens))
    }

    /// Lines for code, words for prose — the same sort of judgement `PayloadClassifier`
    /// makes about a clip's kind, and made once here so the view never has to guess.
    ///
    /// Three cases, in order:
    ///
    /// - Two single-line clips are a value or a sentence. A line diff of those says only
    ///   "this line changed", which is the one thing you could already see.
    /// - Anything that looks structured — indented lines, lines closing on a brace or a
    ///   semicolon — is code, where a line is the unit people think in.
    /// - What is left is prose in paragraphs. Long lines there are wrapped sentences, so
    ///   a line diff would mark a whole paragraph changed over one corrected word.
    public static func granularity(for old: String, _ new: String) -> Granularity {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false)

        if oldLines.count <= 1, newLines.count <= 1 { return .word }
        if looksStructured(oldLines) || looksStructured(newLines) { return .line }

        let longest = (oldLines + newLines).map(\.count).max() ?? 0
        return longest > 120 ? .word : .line
    }

    /// A quarter of the lines indented, or closing on punctuation that only code uses.
    ///
    /// A quarter rather than a majority: a function is mostly its body, and the body is
    /// indented, but a short config file may be three flat keys and one nested block.
    static func looksStructured(_ lines: [Substring]) -> Bool {
        let meaningful = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard meaningful.count >= 2 else { return false }

        let structural = meaningful.count { line in
            if line.first == " " || line.first == "\t" { return true }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return "{}[];,".contains(trimmed.last ?? " ")
        }
        return Double(structural) / Double(meaningful.count) >= 0.25
    }

    private static func tokens(of text: String, granularity: Granularity) -> [String] {
        switch granularity {
        case .line:
            text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        case .word:
            // Whitespace runs collapse. A word diff is about which words changed, and
            // marking a double space as a difference is noise nobody asked about.
            text.split(whereSeparator: \.isWhitespace).map(String.init)
        }
    }

    /// Walks both sides at once, using the difference to say which side to take from.
    ///
    /// `CollectionDifference` gives removals and insertions by offset but not the
    /// unchanged run between them, and it is the unchanged text that makes a diff
    /// readable — so it is reconstructed here.
    private static func align(_ old: [String], _ new: [String]) -> [Segment] {
        var removals: [Int: String] = [:]
        var insertions: [Int: String] = [:]
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, let element, _): removals[offset] = element
            case .insert(let offset, let element, _): insertions[offset] = element
            }
        }

        var segments: [Segment] = []
        var oldIndex = 0
        var newIndex = 0

        func append(_ change: Change, _ text: String) {
            segments.append(Segment(id: segments.count, change: change, text: text))
        }

        while oldIndex < old.count || newIndex < new.count {
            if let removed = removals[oldIndex] {
                append(.removed, removed)
                oldIndex += 1
            } else if let inserted = insertions[newIndex] {
                append(.inserted, inserted)
                newIndex += 1
            } else if oldIndex < old.count, newIndex < new.count {
                append(.unchanged, old[oldIndex])
                oldIndex += 1
                newIndex += 1
            } else {
                // Unreachable while the difference is consistent with its inputs, and a
                // `break` rather than a crash if it ever is not.
                break
            }
        }
        return segments
    }
}
