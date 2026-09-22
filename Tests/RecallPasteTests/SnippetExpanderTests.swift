import Foundation
import Testing
@testable import RecallCore
@testable import RecallPaste

@Suite("Snippet expansion")
struct SnippetExpanderTests {
    let signatureID = UUID()

    var expander: SnippetExpander {
        SnippetExpander(snippets: [":sig": signatureID])
    }

    @Test("Expands on a terminator")
    func expandsOnTerminator() throws {
        let match = try #require(expander.match(typedBuffer: "hello :sig "))
        #expect(match.itemID == signatureID)
        // 4 characters of ":sig" plus the space that triggered it.
        #expect(match.charactersToDelete == 5)
    }

    @Test("Does not fire before the terminator")
    func waitsForTerminator() {
        #expect(expander.match(typedBuffer: "hello :sig") == nil)
    }

    @Test("A longer code that merely starts with a known one does not fire")
    func prefixesDoNotFire() {
        #expect(expander.match(typedBuffer: ":signature ") == nil)
    }

    @Test("Unknown codes are left alone")
    func ignoresUnknownCodes() {
        #expect(expander.match(typedBuffer: ":nope ") == nil)
    }

    @Test("Codes are built from the items that carry them")
    func buildsFromItems() throws {
        var item = ClipItem(payload: .text("Best,\nAlex"), contentHash: ContentHash(.text("Best,\nAlex")))
        item.snippetCode = ":sig"
        let expander = SnippetExpander(items: [item])
        #expect(try #require(expander.match(typedBuffer: ":sig\n")).itemID == item.id)
    }

    @Test("Shortcode validation")
    func validatesCodes() {
        #expect(SnippetExpander.isValid(code: ":sig"))
        #expect(SnippetExpander.isValid(code: ";bug-1"))
        #expect(!SnippetExpander.isValid(code: "sig"))
        #expect(!SnippetExpander.isValid(code: ":"))
        #expect(!SnippetExpander.isValid(code: ":has space"))
    }
}
