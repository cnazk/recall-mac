import CryptoKit
import Foundation
import RecallCore

/// Rules that recognise a *shape* rather than a provider's prefix.
///
/// These are the ones that need a checksum or a wordlist to be safe. Without one, a rule
/// like "24 words" or "20 digits" fires on ordinary text and silently deletes it, which is
/// worse than missing the secret.
public extension SecretRule {
    /// A BIP-39 recovery phrase.
    ///
    /// Every word is checked against the official wordlist *and* the phrase's own
    /// checksum is verified, so this effectively cannot fire on prose. Worth the effort:
    /// a seed phrase is the one secret here whose loss is unrecoverable and total.
    static let seedPhrase = SecretRule(
        identifier: "crypto.seed-phrase",
        displayName: String(localized: "Recovery phrase"),
        summary: String(localized: "A valid BIP-39 wallet phrase, wordlist and checksum verified."),
        confidence: .certain
    ) { text in
        BIP39.isValidPhrase(text)
    }

    /// An IBAN, validated with the mod-97 check the standard defines.
    static let iban = SecretRule(
        identifier: "bank.iban",
        displayName: String(localized: "IBAN"),
        summary: String(localized: "Bank account numbers that pass the mod-97 check."),
        confidence: .likely
    ) { text in
        let trimmed = text.replacingOccurrences(of: " ", with: "").uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (15...34).contains(trimmed.count) else { return false }
        guard trimmed.prefix(2).allSatisfy(\.isLetter), trimmed.dropFirst(2).prefix(2).allSatisfy(\.isNumber) else {
            return false
        }
        guard trimmed.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        return ibanChecksumIsValid(trimmed)
    }

    /// National identifiers, which only fire with a nearby label.
    ///
    /// The shape alone — nine digits, or two letters and six digits — is far too common to
    /// act on. Requiring the label is what keeps this from eating order numbers.
    static let nationalIdentifier = SecretRule(
        identifier: "id.national",
        displayName: String(localized: "National ID number"),
        summary: String(localized: "A social security or NI number, when labelled as one."),
        confidence: .likely,
        pattern: "(?i)\\b(ssn|social security|national insurance|\\bni\\b)\\b[^\\n]{0,20}?\\b(\\d{3}-\\d{2}-\\d{4}|\\d{9}|[A-Z]{2}\\s?\\d{2}\\s?\\d{2}\\s?\\d{2}\\s?[A-D])\\b"
    )
}

/// IBAN mod-97: move the first four characters to the end, map letters to numbers, and
/// the whole value modulo 97 must be 1.
func ibanChecksumIsValid(_ iban: String) -> Bool {
    let rearranged = iban.dropFirst(4) + iban.prefix(4)

    var remainder = 0
    for character in rearranged {
        let chunk: String
        if character.isNumber {
            chunk = String(character)
        } else if let ascii = character.asciiValue, character.isLetter {
            chunk = String(Int(ascii - 65) + 10)
        } else {
            return false
        }
        for digit in chunk {
            guard let value = digit.wholeNumberValue else { return false }
            remainder = (remainder * 10 + value) % 97
        }
    }
    return remainder == 1
}

/// The BIP-39 wordlist and checksum.
enum BIP39 {
    /// Loaded once from the bundled official English wordlist.
    ///
    /// Deliberately *not* `Bundle.module`: that traps when its resource bundle is missing,
    /// and a clipboard manager must not die at launch because a detector's data file did
    /// not get copied. Found the hard way — the first build of this rule crashed the
    /// shipped app while every test passed. Missing wordlist now means this one rule is
    /// inert, and everything else carries on.
    static let words: [String] = {
        guard let url = wordlistURL(),
              let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            Log.security.error("BIP-39 wordlist missing; recovery phrases will not be detected")
            return []
        }
        return contents.split(whereSeparator: \.isNewline).map(String.init)
    }()

    /// Anchor for locating the module's own bundle without `Bundle.module`.
    private final class Token {}

    private static func wordlistURL() -> URL? {
        let name = "bip39-english"
        let ext = "txt"

        for bundle in [Bundle.main, Bundle(for: Token.self)] + Bundle.allBundles {
            if let url = bundle.url(forResource: name, withExtension: ext) { return url }
        }

        // The SwiftPM resource bundle, wherever the packaging step put it.
        let resourceBundle = "Recall_RecallSecurity.bundle"
        let searchRoots = [
            Bundle.main.resourceURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle(for: Token.self).resourceURL,
            Bundle(for: Token.self).bundleURL.deletingLastPathComponent(),
        ].compactMap { $0 }

        for root in searchRoots {
            let candidate = root.appendingPathComponent(resourceBundle)
            if let bundle = Bundle(url: candidate), let url = bundle.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    private static let index: [String: Int] = {
        Dictionary(uniqueKeysWithValues: words.enumerated().map { ($0.element, $0.offset) })
    }()

    /// Valid BIP-39 lengths. Anything else is not a phrase.
    static let validLengths: Set<Int> = [12, 15, 18, 21, 24]

    static func isValidPhrase(_ text: String) -> Bool {
        guard !words.isEmpty else { return false }

        let candidate = text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        guard validLengths.contains(candidate.count) else { return false }

        var indices: [Int] = []
        indices.reserveCapacity(candidate.count)
        for word in candidate {
            guard let position = index[word] else { return false }
            indices.append(position)
        }

        return checksumIsValid(indices)
    }

    /// Each word carries 11 bits. The trailing bits are a checksum over the entropy, and
    /// verifying them is what makes this rule safe to act on.
    private static func checksumIsValid(_ indices: [Int]) -> Bool {
        var bits: [Bool] = []
        bits.reserveCapacity(indices.count * 11)
        for value in indices {
            for shift in stride(from: 10, through: 0, by: -1) {
                bits.append((value >> shift) & 1 == 1)
            }
        }

        let checksumLength = bits.count / 33
        let entropyLength = bits.count - checksumLength
        guard entropyLength % 8 == 0 else { return false }

        var entropy = [UInt8](repeating: 0, count: entropyLength / 8)
        for (offset, bit) in bits.prefix(entropyLength).enumerated() where bit {
            entropy[offset / 8] |= UInt8(1 << (7 - (offset % 8)))
        }

        let digest = Data(SHA256.hash(data: Data(entropy)))
        var digestBits: [Bool] = []
        digestBits.reserveCapacity(digest.count * 8)
        for byte in digest {
            for shift in stride(from: 7, through: 0, by: -1) {
                digestBits.append((byte >> UInt8(shift)) & 1 == 1)
            }
        }

        return Array(bits.suffix(checksumLength)) == Array(digestBits.prefix(checksumLength))
    }
}
