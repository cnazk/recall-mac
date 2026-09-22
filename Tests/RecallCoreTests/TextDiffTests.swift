import Foundation
import Testing
@testable import RecallCore

@Suite("Diffing two clips")
struct TextDiffTests {
    private func texts(_ result: TextDiff.Result, _ change: TextDiff.Change) -> [String] {
        result.segments.filter { $0.change == change }.map(\.text)
    }

    // MARK: - Alignment

    @Test("Identical text has no changes")
    func identicalText() {
        let diff = TextDiff.between("same\ntext", "same\ntext")
        #expect(diff.isIdentical)
        #expect(diff.insertedCount == 0 && diff.removedCount == 0)
    }

    /// The whole point of reconstructing the unchanged runs: a diff of only the changes
    /// is a list of fragments with nothing to locate them against.
    @Test("Unchanged lines are kept as context")
    func keepsContext() {
        let diff = TextDiff.between("a\nb\nc", "a\nB\nc", granularity: .line)
        #expect(texts(diff, .unchanged) == ["a", "c"])
        #expect(texts(diff, .removed) == ["b"])
        #expect(texts(diff, .inserted) == ["B"])
    }

    @Test("An added line is an addition, not a rewrite of everything after it")
    func detectsInsertion() {
        let diff = TextDiff.between("a\nc", "a\nb\nc", granularity: .line)
        #expect(texts(diff, .inserted) == ["b"])
        #expect(diff.removedCount == 0)
    }

    @Test("A deleted line is a deletion")
    func detectsDeletion() {
        let diff = TextDiff.between("a\nb\nc", "a\nc", granularity: .line)
        #expect(texts(diff, .removed) == ["b"])
        #expect(diff.insertedCount == 0)
    }

    @Test("Everything is new when one side is empty")
    func handlesEmptySides() {
        #expect(texts(TextDiff.between("", "a b", granularity: .word), .inserted) == ["a", "b"])
        #expect(texts(TextDiff.between("a b", "", granularity: .word), .removed) == ["a", "b"])
        #expect(TextDiff.between("", "").isIdentical)
    }

    /// Reading a word diff means seeing the corrected word in its sentence, so the
    /// untouched words have to survive.
    @Test("A word diff changes only the word that changed")
    func wordLevelIsPrecise() {
        let diff = TextDiff.between(
            "the quick brown fox",
            "the quick red fox",
            granularity: .word
        )
        #expect(texts(diff, .removed) == ["brown"])
        #expect(texts(diff, .inserted) == ["red"])
        #expect(texts(diff, .unchanged) == ["the", "quick", "fox"])
    }

    // MARK: - Choosing the granularity

    @Test("Two one-line clips are compared by word")
    func singleLineUsesWords() {
        #expect(TextDiff.granularity(for: "hello there", "hello world") == .word)
    }

    @Test("Code is compared by line", arguments: [
        "func a() {\n    return 1\n}",
        "{\n  \"a\": 1,\n  \"b\": 2\n}",
        "key = one;\nother = two;",
    ])
    func codeUsesLines(code: String) {
        #expect(TextDiff.granularity(for: code, code + "\n") == .line)
    }

    /// Wrapped prose in long paragraphs: a line diff there marks the whole paragraph
    /// changed because one word in it was corrected.
    @Test("Long wrapped paragraphs are compared by word")
    func longProseUsesWords() {
        let paragraph = String(repeating: "a sentence of ordinary prose that runs on. ", count: 5)
        #expect(TextDiff.granularity(for: paragraph + "\n\n" + paragraph, paragraph) == .word)
    }

    @Test("Short multi-line prose is compared by line")
    func shortProseUsesLines() {
        let list = "milk\neggs\nbread"
        #expect(TextDiff.granularity(for: list, "milk\neggs\njam") == .line)
    }

    @Test("An explicit granularity overrides the guess")
    func honoursExplicitGranularity() {
        #expect(TextDiff.between("a b", "a c", granularity: .line).granularity == .line)
    }

    // MARK: - Copying the diff

    @Test("The unified text is the shape everyone recognises")
    func unifiedTextUsesSigns() {
        let diff = TextDiff.between("a\nb\nc", "a\nB\nc", granularity: .line)
        #expect(diff.unifiedText() == "  a\n- b\n+ B\n  c")
    }

    /// One `+` per word would be unreadable, so a word diff coalesces into before-and-
    /// after lines.
    @Test("A word diff copies as runs, not one word per line")
    func unifiedTextCoalescesWords() {
        let diff = TextDiff.between("the brown fox", "the red fox", granularity: .word)
        #expect(diff.unifiedText() == "  the\n- brown\n+ red\n  fox")
    }

    // MARK: - What can be compared

    @Test("A clip with no text cannot be compared")
    func imageWithoutTextIsNotComparable() {
        let image = ImagePayload(data: Data([1]), uti: "public.png", pixelWidth: 1, pixelHeight: 1)
        let item = ClipItem(payload: .image(image), contentHash: ContentHash(.image(image)))
        #expect(!item.isComparable)
    }

    /// Two screenshots of the same document should diff by what was read out of them.
    @Test("A screenshot compares by its recognised text")
    func imageComparesByOCR() {
        let image = ImagePayload(data: Data([1]), uti: "public.png", pixelWidth: 1, pixelHeight: 1)
        var item = ClipItem(payload: .image(image), contentHash: ContentHash(.image(image)))
        item.ocrText = "words in the picture"
        #expect(item.isComparable)
        #expect(item.comparableText == "words in the picture")
    }

    /// A diff prints the unchanged parts too, which for a credential is most of it.
    @Test("A secret is never comparable")
    func secretsAreNotComparable() {
        var item = ClipItem(payload: .text("sk-live-123"), contentHash: ContentHash(.text("sk-live-123")))
        item.sensitivity = .secret
        #expect(!item.isComparable)
    }

    /// Not `indexableText`: that folds in the summary and a link title, and diffing those
    /// reports changes to text the user never copied.
    @Test("Comparison ignores the summary and the link title")
    func comparesOnlyWhatWasCopied() {
        var item = ClipItem(payload: .text("the body"), contentHash: ContentHash(.text("the body")))
        item.summary = "a summary that differs"
        item.link = LinkMetadata(title: "a title that differs")
        #expect(item.comparableText == "the body")
    }
}
