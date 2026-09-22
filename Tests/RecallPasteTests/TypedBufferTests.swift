import Foundation
import Testing
@testable import RecallCore
@testable import RecallPaste

@Suite("Typed buffer")
struct TypedBufferTests {
    @Test("Characters accumulate in order")
    func accumulates() {
        var buffer = TypedBuffer()
        buffer.append("s")
        buffer.append("i")
        buffer.append("g")
        #expect(buffer.text == "sig")
    }

    @Test("Backspace removes the last character")
    func handlesBackspace() {
        var buffer = TypedBuffer()
        buffer.append("sig")
        buffer.deleteBackward()
        #expect(buffer.text == "si")
    }

    @Test("Backspacing an empty buffer is harmless")
    func backspaceOnEmpty() {
        var buffer = TypedBuffer()
        buffer.deleteBackward()
        #expect(buffer.isEmpty)
    }

    @Test("The buffer never grows past its cap")
    func staysSmall() {
        var buffer = TypedBuffer()
        buffer.append(String(repeating: "a", count: 500))
        #expect(buffer.text.count == TypedBuffer.capacity, "this must never become a keylog")
    }

    @Test("Old characters fall off the front, keeping the most recent")
    func keepsTheTail() {
        var buffer = TypedBuffer()
        buffer.append(String(repeating: "x", count: TypedBuffer.capacity))
        buffer.append(":sig")
        #expect(buffer.text.hasSuffix(":sig"))
        #expect(buffer.text.count == TypedBuffer.capacity)
    }

    @Test("Resetting forgets everything")
    func resets() {
        var buffer = TypedBuffer()
        buffer.append("password123")
        buffer.reset()
        #expect(buffer.isEmpty)
    }

    @Test("A shortcode typed after other words still matches")
    func matchesAfterOtherText() throws {
        let id = UUID()
        let expander = SnippetExpander(snippets: [":sig": id])

        var buffer = TypedBuffer()
        buffer.append("thanks :sig ")

        let match = try #require(expander.match(typedBuffer: buffer.text))
        #expect(match.itemID == id)
        #expect(match.charactersToDelete == 5)
    }

    @Test("A shortcode split by a backspace correction still matches")
    func survivesTypingCorrection() throws {
        let id = UUID()
        let expander = SnippetExpander(snippets: [":sig": id])

        var buffer = TypedBuffer()
        buffer.append(":sog")
        buffer.deleteBackward()
        buffer.deleteBackward()
        buffer.append("ig ")

        let match = try #require(expander.match(typedBuffer: buffer.text))
        #expect(match.itemID == id)
    }
}
