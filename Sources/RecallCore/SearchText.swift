import Foundation

/// Folds the spellings of a word that are the same word.
///
/// Search compares what the user types against what was captured, and for Arabic-script
/// languages those two rarely agree on codepoints even when they agree on the word:
///
/// - **Persian against Arabic letters.** The OCR model is `ar-SA` — macOS has no Persian
///   recogniser, in either Vision API — so it reads Persian text in Arabic spellings:
///   `ی` comes back as `ي`, `ک` as `ك`. A Persian keyboard types the Persian ones, so the
///   words look identical on screen and share not one byte.
/// - **The zero-width non-joiner.** `کتاب‌های` is typed with U+200C inside it and recognised
///   without it, which is one word or two depending on who produced the text.
/// - **Digits.** `۱۲۳`, `١٢٣` and `123` are the same number three ways.
/// - **Hamza and the alef forms.** `أ`, `إ`, `آ` and `ا` are written with and without
///   their hamza almost interchangeably.
///
/// FTS5's `remove_diacritics 2` does not touch any of this: these are distinct letters to
/// Unicode, not accented ones.
///
/// Applied to **both sides** — text on its way into the index, and the query on its way
/// out — so it is a comparison rule rather than a rewrite. Nothing normalised here is ever
/// stored or shown: the detail pane still displays exactly what the OCR returned, because
/// a user copying text out of an image should get the text that was in the image.
public enum SearchText {
    public static func normalized(_ text: String) -> String {
        var result = String()
        result.reserveCapacity(text.count)

        for scalar in text.unicodeScalars {
            if let folded = Self.folded[scalar] {
                result.unicodeScalars.append(folded)
            } else if Self.isDiscardable(scalar) {
                continue
            } else if let digit = Self.asciiDigit(for: scalar) {
                result.unicodeScalars.append(digit)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Letters that are written more than one way for the same sound.
    private static let folded: [Unicode.Scalar: Unicode.Scalar] = [
        // Kaf: Arabic kaf and the Persian keheh.
        "\u{0643}": "\u{06A9}",
        // Yeh: Arabic yeh, alef maksura and the Urdu barree yeh, all to the Persian yeh.
        "\u{064A}": "\u{06CC}", "\u{0649}": "\u{06CC}", "\u{06D2}": "\u{06CC}",
        // Heh: teh marbuta and heh with yeh above.
        "\u{0629}": "\u{0647}", "\u{06C0}": "\u{0647}",
        // Alef, with every hamza and madda it is written with.
        "\u{0622}": "\u{0627}", "\u{0623}": "\u{0627}",
        "\u{0625}": "\u{0627}", "\u{0671}": "\u{0627}",
        // Hamza on a carrier, to the carrier.
        "\u{0624}": "\u{0648}", "\u{0626}": "\u{06CC}",
    ]

    /// Marks that change how a word is *read* but not which word it is.
    ///
    /// Harakat are optional in ordinary writing, the tatweel is a typographic stretch, and
    /// the zero-width joiners are invisible. Any of them present on one side of a
    /// comparison and absent on the other would break a match that should hold.
    private static func isDiscardable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x064B...0x0652, 0x0670: true   // harakat and the superscript alef
        case 0x0640: true                    // tatweel
        case 0x200B...0x200F: true           // ZWNJ, ZWJ and the direction marks
        case 0xFEFF: true                    // byte-order mark
        default: false
        }
    }

    /// Arabic-Indic and extended Arabic-Indic digits, as ASCII.
    private static func asciiDigit(for scalar: Unicode.Scalar) -> Unicode.Scalar? {
        let value = scalar.value
        let zero: UInt32
        switch value {
        case 0x0660...0x0669: zero = 0x0660
        case 0x06F0...0x06F9: zero = 0x06F0
        default: return nil
        }
        return Unicode.Scalar(0x30 + (value - zero))
    }
}
