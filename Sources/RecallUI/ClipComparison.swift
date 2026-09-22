import Foundation
import RecallCore

/// Two clips being compared, in the order that makes a diff mean something.
///
/// Ordered by when they were copied, not by which one the user picked first. A diff is
/// read as "what changed", and what changed is only well defined from the older to the
/// newer — picking the newer one first should not invert every sign.
public struct ClipComparison: Identifiable, Equatable, Sendable {
    public let older: ClipItem
    public let newer: ClipItem

    /// Identifies the pair, so presenting it as a sheet reopens when the pair changes.
    public var id: String { "\(older.id)-\(newer.id)" }

    public init(_ one: ClipItem, _ other: ClipItem) {
        if other.createdAt < one.createdAt {
            self.older = other
            self.newer = one
        } else {
            self.older = one
            self.newer = other
        }
    }

    public var diff: TextDiff.Result {
        TextDiff.between(older.comparableText ?? "", newer.comparableText ?? "")
    }
}
