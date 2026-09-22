import Foundation
import Testing
@testable import RecallCore
@testable import RecallSecurity

@Suite("Secret detection")
struct SecretDetectorTests {
    let detector = SecretDetector()

    @Test("Detects credential formats", arguments: [
        "AKIAIOSFODNN7EXAMPLE",
        "ghp_1234567890abcdefghijklmnopqrstuvwxyz",
        "sk-abcdefghijklmnopqrstuvwxyz0123456789",
        "-----BEGIN RSA PRIVATE KEY-----\nMIIEow==\n-----END RSA PRIVATE KEY-----",
        "password: hunter2is-long",
        "4111 1111 1111 1111",
        "123456",
    ])
    func detectsSecrets(sample: String) {
        #expect(detector.inspect(sample).isSecret, "expected \(sample.prefix(12))… to be flagged")
    }

    @Test("Leaves ordinary text alone", arguments: [
        "Hello, world",
        "https://example.com/pricing",
        "border-radius: 8px;",
        "Order #4829104 shipped",
        "1234",
        "The meeting is at 10:30 in room 214",
    ])
    func ignoresOrdinaryText(sample: String) {
        #expect(!detector.inspect(sample).isSecret, "expected \(sample.prefix(20))… to pass")
    }

    @Test("Luhn check rejects card-shaped numbers that are not cards")
    func luhnGuardsCardRule() {
        #expect(!detector.inspect("4111 1111 1111 1112").isSecret)
        #expect(detector.inspect("5500 0000 0000 0004").isSecret)
    }

    @Test("Verdicts name the rules that fired")
    func verdictExplainsItself() {
        let verdict = detector.inspect("AKIAIOSFODNN7EXAMPLE")
        #expect(verdict.matchedRules.contains("aws.access-key"))
        #expect(verdict.confidence == .certain)
    }
}

@Suite("App exclusions")
struct AppExclusionTests {
    @Test("Password managers are excluded out of the box")
    func builtInExclusions() {
        let policy = AppExclusionPolicy()
        #expect(policy.isExcluded(bundleIdentifier: "com.1password.1password"))
        #expect(policy.isExcluded(bundleIdentifier: "com.bitwarden.desktop"))
        #expect(policy.isExcluded(bundleIdentifier: "com.apple.keychainaccess"))
        #expect(!policy.isExcluded(bundleIdentifier: "com.apple.Safari"))
        #expect(!policy.isExcluded(bundleIdentifier: nil))
    }

    @Test("User exclusions are additive")
    func userExclusions() {
        let policy = AppExclusionPolicy(userExcludedBundleIDs: ["com.example.vault"])
        #expect(policy.isExcluded(bundleIdentifier: "com.example.vault"))
        #expect(policy.isExcluded(bundleIdentifier: "com.1password.1password"))
    }

    @Test("Concealed pasteboard markers are honoured")
    func concealedTypes() {
        let policy = AppExclusionPolicy()
        #expect(policy.isConcealed(pasteboardTypes: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        #expect(!policy.isConcealed(pasteboardTypes: ["public.utf8-plain-text"]))
    }
}
