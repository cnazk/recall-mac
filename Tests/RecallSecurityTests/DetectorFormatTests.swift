import Foundation
import Testing
@testable import RecallCore
@testable import RecallSecurity

@Suite("Provider credential formats")
struct ProviderFormatTests {
    let detector = SecretDetector()

    @Test("Detected", arguments: [
        "sk_live_4eC39HqLyjWDarjtT1zdp7dc",
        "xoxb-2411-1234567890-AbCdEfGhIjKlMnOpQrStUvWx",
        "glpat-ABCdefGHIjklMNOpqrST",
        "AIzaSyD-1234567890abcdefghijklmnopqrstu",
        "hf_abcdefghijklmnopqrstuvwxyz0123456789",
        "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123",
        "npm_abcdefghijklmnopqrstuvwxyz0123456789",
        "ACd1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6",
        "SG.abcdefghijklmnopqrst.uvwxyz0123456789abcd",
        "123456789:AAHfYH5ZtLm0pQrStUvWxYz1234567890ab",
        "v1.0-1234567890abcdef1234-abcdef1234567890abcd",
        "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNza\n-----END OPENSSH PRIVATE KEY-----",
        "abcd-efgh-ijkl-mnop",
        "https://admin:hunter2@internal.example.com/dashboard",
        "postgres://app:s3cr3t@db.example.com:5432/production",
    ])
    func detectsProviderFormats(sample: String) {
        #expect(detector.inspect(sample).isSecret, "expected \(sample.prefix(16))… to be flagged")
    }

    @Test("Not mistaken for secrets", arguments: [
        "https://example.com/pricing",
        "postgres://localhost:5432/dev",
        "The build ran at 12:30 and passed",
        "AC unit maintenance on Tuesday",
        "abcd-efgh-ijkl",
        "sk_test is the prefix Stripe uses for test keys",
    ])
    func ignoresOrdinaryText(sample: String) {
        #expect(!detector.inspect(sample).isSecret, "expected \(sample.prefix(20))… to pass")
    }

    @Test("An environment file is caught, an ordinary config is not")
    func detectsEnvironmentFiles() {
        let env = """
        DATABASE_URL=postgres://localhost/app
        API_SECRET=abcdef123456
        DEBUG=true
        """
        #expect(detector.inspect(env).isSecret)

        let plain = """
        NAME=Recall
        VERSION=0.1.0
        PLATFORM=macOS
        """
        #expect(!detector.inspect(plain).isSecret)
    }
}

@Suite("Recovery phrases")
struct SeedPhraseTests {
    let detector = SecretDetector()

    @Test("The wordlist is present")
    func wordlistLoaded() {
        #expect(BIP39.words.count == 2_048, "the official list has 2,048 words")
        #expect(BIP39.words.first == "abandon")
        #expect(BIP39.words.last == "zoo")
    }

    @Test("A valid 12-word phrase is caught")
    func detectsValidPhrase() {
        // The canonical all-zeros entropy test vector from the BIP-39 specification.
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        #expect(BIP39.isValidPhrase(phrase))
        #expect(detector.inspect(phrase).isSecret)
    }

    @Test("A valid 24-word phrase is caught")
    func detectsLongPhrase() {
        let phrase = Array(repeating: "abandon", count: 23).joined(separator: " ") + " art"
        #expect(BIP39.isValidPhrase(phrase))
    }

    @Test("Twelve real words with a wrong checksum are not a phrase")
    func rejectsBadChecksum() {
        // Every word is in the list; the checksum is not satisfied. Without the checksum
        // check this would fire and silently delete the clip.
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon"
        #expect(!BIP39.isValidPhrase(phrase))
    }

    @Test("Ordinary prose of the same length is not a phrase")
    func ignoresProse() {
        let prose = "the quick brown fox jumps over the lazy dog while nobody was really watching"
        #expect(!BIP39.isValidPhrase(prose))
        #expect(!detector.inspect(prose).isSecret)
    }

    @Test("Wrong word counts are rejected")
    func rejectsWrongLengths() {
        #expect(!BIP39.isValidPhrase("abandon abandon about"))
        #expect(!BIP39.isValidPhrase(Array(repeating: "abandon", count: 13).joined(separator: " ")))
    }
}

@Suite("IBAN and national identifiers")
struct CheckedShapeTests {
    let detector = SecretDetector()

    @Test("A valid IBAN is caught", arguments: [
        "GB82 WEST 1234 5698 7654 32",
        "DE89370400440532013000",
        "FR1420041010050500013M02606",
    ])
    func detectsIBAN(sample: String) {
        #expect(detector.inspect(sample).isSecret)
    }

    @Test("A mistyped IBAN fails the checksum rather than being flagged")
    func rejectsBadChecksum() {
        #expect(!detector.inspect("GB82 WEST 1234 5698 7654 33").isSecret)
    }

    @Test("A national ID fires only when it is labelled")
    func requiresALabel() {
        #expect(detector.inspect("SSN: 123-45-6789").isSecret)
        // The bare shape is far too common to act on.
        #expect(!detector.inspect("123456789").isSecret)
        #expect(!detector.inspect("Order 123-45-6789 shipped").isSecret)
    }
}

@Suite("Turning rules off")
struct RuleTogglingTests {
    @Test("A disabled rule stops firing, and the others carry on")
    func honoursDisabledRules() {
        var settings = RecallSettings.default
        settings.disabledSecretRules = ["otp"]

        let detector = SecretDetector(settings: settings)
        #expect(!detector.inspect("483920").isSecret, "the one-time code rule is off")
        #expect(detector.inspect("AKIAIOSFODNN7EXAMPLE").isSecret, "the others are unaffected")
    }

    @Test("Every rule has a name and a summary for the settings list")
    func rulesAreDescribable() {
        for rule in SecretRule.builtIn {
            #expect(!rule.displayName.isEmpty, "\(rule.identifier) needs a name")
            #expect(!rule.summary.isEmpty, "\(rule.identifier) needs a summary")
        }
    }

    @Test("Rule identifiers are unique")
    func identifiersAreUnique() {
        let identifiers = SecretRule.builtIn.map(\.identifier)
        #expect(Set(identifiers).count == identifiers.count)
    }
}
