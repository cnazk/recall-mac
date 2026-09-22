import Foundation
import Testing
@testable import RecallCore

@Suite("Search text folding")
struct SearchTextTests {
    /// The case this exists for. macOS has no Persian OCR model, so Persian in an image is
    /// read by the Arabic one and comes back in Arabic letters — while the search box is
    /// being typed into with a Persian keyboard.
    @Test("Persian read as Arabic matches Persian as typed", arguments: [
        ("\u{0633}\u{0644}\u{0627}\u{0645} \u{062F}\u{0646}\u{064A}\u{0627}",  // OCR: with Arabic yeh
         "\u{0633}\u{0644}\u{0627}\u{0645} \u{062F}\u{0646}\u{06CC}\u{0627}"), // typed: Persian yeh
        ("\u{0643}\u{062A}\u{0627}\u{0628}",   // OCR: Arabic kaf
         "\u{06A9}\u{062A}\u{0627}\u{0628}"),  // typed: Persian keheh
    ])
    func foldsPersianAndArabicLetters(recognized: String, typed: String) {
        #expect(SearchText.normalized(recognized) == SearchText.normalized(typed))
    }

    /// Typed with a zero-width non-joiner, recognised without one. Invisible either way.
    @Test("The zero-width non-joiner is not a difference")
    func ignoresZeroWidthNonJoiner() {
        let typed = "\u{06A9}\u{062A}\u{0627}\u{0628}\u{200C}\u{0647}\u{0627}\u{06CC}"
        let recognized = "\u{06A9}\u{062A}\u{0627}\u{0628}\u{0647}\u{0627}\u{06CC}"
        #expect(SearchText.normalized(typed) == SearchText.normalized(recognized))
    }

    @Test("Digits are the same number however they are written")
    func foldsDigits() {
        #expect(SearchText.normalized("\u{06F1}\u{06F2}\u{06F3}") == "123")  // Persian
        #expect(SearchText.normalized("\u{0661}\u{0662}\u{0663}") == "123")  // Arabic-Indic
        #expect(SearchText.normalized("123") == "123")
    }

    @Test("Alef is alef with or without its hamza")
    func foldsAlefForms() {
        let folded = ["\u{0622}", "\u{0623}", "\u{0625}", "\u{0671}"].map(SearchText.normalized)
        #expect(folded.allSatisfy { $0 == "\u{0627}" })
    }

    @Test("Optional vowel marks do not change which word it is")
    func dropsHarakat() {
        let marked = "\u{0645}\u{064E}\u{062F}\u{0652}\u{0631}\u{064E}\u{0633}\u{064E}\u{0629}"
        let plain = "\u{0645}\u{062F}\u{0631}\u{0633}\u{0647}"
        #expect(SearchText.normalized(marked) == SearchText.normalized(plain))
    }

    /// Folding is for Arabic script. It must not quietly rewrite anything else.
    @Test("Latin text is left exactly as it is", arguments: [
        "Hello, world!", "https://example.com/a?b=1", "let x = 1", "café", "日本語",
    ])
    func leavesEverythingElseAlone(text: String) {
        #expect(SearchText.normalized(text) == text)
    }

    @Test("Empty in, empty out")
    func handlesEmpty() {
        #expect(SearchText.normalized("").isEmpty)
    }
}
