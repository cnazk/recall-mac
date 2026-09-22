import Foundation
import RecallCore
import Testing
@testable import RecallUI

@Suite("Comparison shortcuts")
struct ComparisonKeyboardTests {
    @Test("⌘D compares")
    func commandDCompares() {
        #expect(PanelKeyboard.command(for: .character("d"), modifiers: .command, isSearching: false) == .compare)
    }

    /// Typing a `d` into the search box must not start a comparison.
    @Test("A bare d is still a letter")
    func bareDIsNotACommand() {
        #expect(PanelKeyboard.command(for: .character("d"), modifiers: [], isSearching: true) == nil)
    }

    /// Escape backs out of the comparison first. Closing the panel instead would throw
    /// away the search that was typed to find the second clip.
    @Test("Escape cancels a comparison before it closes the panel")
    func escapeBacksOutOfComparisonFirst() {
        #expect(PanelKeyboard.command(for: .escape, modifiers: [], isSearching: false, isComparing: true) == .cancelComparison)
        #expect(PanelKeyboard.command(for: .escape, modifiers: [], isSearching: false, isComparing: false) == .dismiss)
    }
}

@Suite("Comparison pairing")
struct ClipComparisonTests {
    private func clip(_ text: String, at seconds: TimeInterval) -> ClipItem {
        ClipItem(
            payload: .text(text),
            contentHash: ContentHash(.text(text)),
            createdAt: Date(timeIntervalSince1970: seconds)
        )
    }

    /// A diff reads as "what changed", which is only well defined from older to newer.
    /// Picking the newer clip first must not invert every sign.
    @Test("The pair is ordered by when it was copied, not by what was picked first")
    func ordersByAge() {
        let old = clip("before", at: 100)
        let new = clip("after", at: 200)

        #expect(ClipComparison(old, new).older.id == old.id)
        #expect(ClipComparison(new, old).older.id == old.id)
        #expect(ClipComparison(new, old).newer.id == new.id)
    }

    @Test("The diff runs from the older text to the newer")
    func diffsInAgeOrder() {
        let comparison = ClipComparison(clip("a b", at: 200), clip("a", at: 100))
        let inserted = comparison.diff.segments.filter { $0.change == .inserted }
        #expect(inserted.map(\.text) == ["b"], "b was added, not removed")
    }
}
