import Testing
@testable import RecallUI

/// Text lifted off a screenshot keeps the layout it had on screen. Dropped into a 13pt
/// row it becomes several lines of ragged fragments, which is how an image row ended up
/// looking like a broken text row.
@Suite("Row preview text")
@MainActor
struct RowPreviewTests {
    @Test("Newlines, tabs and runs of spaces all collapse to one space")
    func collapsesWhitespace() {
        #expect(ItemRowView.singleLine("Search\nhistory") == "Search history")
        #expect(ItemRowView.singleLine("a\t\tb") == "a b")
        #expect(ItemRowView.singleLine("a      b") == "a b")
        #expect(ItemRowView.singleLine("line one\r\nline two") == "line one line two")
    }

    @Test("Leading and trailing whitespace goes entirely")
    func trimsEnds() {
        #expect(ItemRowView.singleLine("\n  padded  \n") == "padded")
    }

    @Test("Nothing in, nothing out")
    func handlesEmptyAndNil() {
        #expect(ItemRowView.singleLine(nil) == nil)
        #expect(ItemRowView.singleLine("") == "")
        // Whitespace only is empty, not a row of spaces.
        #expect(ItemRowView.singleLine("   \n\t ") == "")
    }
}
