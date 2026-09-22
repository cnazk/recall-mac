import Foundation
import RecallCore
import Testing
@testable import RecallStorage

/// End to end, because folding one side only is worse than folding neither: the index and
/// the query have to agree, and the two live in different places.
@Suite("Searching Arabic-script text")
struct PersianSearchTests {
    /// Exactly what happens with a Persian screenshot: Vision returns Arabic letters, the
    /// user types Persian ones, and before this the search returned nothing at all.
    @Test("A Persian query finds text the OCR read in Arabic letters")
    func findsPersianReadAsArabic() throws {
        let index = try SearchIndex()
        let id = UUID()
        try index.index(
            id: id,
            text: "\u{0633}\u{0644}\u{0627}\u{0645} \u{062F}\u{0646}\u{064A}\u{0627}",
            tags: []
        )

        let typed = "\u{062F}\u{0646}\u{06CC}\u{0627}"
        #expect(try index.search(typed, limit: 10) == [id])
    }

    @Test("A query typed in Persian digits finds a clip written in ASCII ones")
    func findsAcrossDigitForms() throws {
        let index = try SearchIndex()
        let id = UUID()
        try index.index(id: id, text: "order 12345", tags: [])
        #expect(try index.search("\u{06F1}\u{06F2}\u{06F3}\u{06F4}\u{06F5}", limit: 10) == [id])
    }

    @Test("Searching English is unaffected")
    func stillFindsEnglish() throws {
        let index = try SearchIndex()
        let id = UUID()
        try index.index(id: id, text: "the quick brown fox", tags: [])
        #expect(try index.search("brown", limit: 10) == [id])
        #expect(try index.search("zebra", limit: 10).isEmpty)
    }
}
