import Foundation
import RecallCore

/// A named pattern that marks text as sensitive.
///
/// Rules are deliberately conservative: a false positive costs the user an item that
/// vanishes after a minute, a false negative leaves a credential on disk.
public struct SecretRule: Sendable {
    public enum Confidence: Int, Sendable, Comparable {
        case possible = 0
        case likely = 1
        case certain = 2

        public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let identifier: String
    /// Shown in Settings, where every rule can be turned off individually.
    public let displayName: String
    /// One line saying what it matches, so a user can judge whether they want it.
    public let summary: String
    public let confidence: Confidence
    private let matcher: @Sendable (String) -> Bool

    public init(
        identifier: String,
        displayName: String,
        summary: String,
        confidence: Confidence,
        matcher: @escaping @Sendable (String) -> Bool
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.summary = summary
        self.confidence = confidence
        self.matcher = matcher
    }

    /// Convenience initialiser for a rule backed by a regular expression.
    public init(
        identifier: String,
        displayName: String,
        summary: String,
        confidence: Confidence,
        pattern: String
    ) {
        let regex = try! NSRegularExpression(pattern: pattern, options: [])
        self.init(identifier: identifier, displayName: displayName, summary: summary, confidence: confidence) { text in
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.firstMatch(in: text, options: [], range: range) != nil
        }
    }

    public func matches(_ text: String) -> Bool { matcher(text) }
}

public extension SecretRule {
    /// AWS access key IDs have a fixed, unmistakable shape.
    static let awsAccessKey = SecretRule(
        identifier: "aws.access-key",
        displayName: String(localized: "AWS access key"),
        summary: String(localized: "Keys beginning AKIA, ASIA and similar."),
        confidence: .certain,
        pattern: "\\b(AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA)[0-9A-Z]{16}\\b"
    )

    static let awsSecretKey = SecretRule(
        identifier: "aws.secret-key",
        displayName: String(localized: "AWS secret key"),
        summary: String(localized: "A 40-character secret next to the word “aws”."),
        confidence: .likely,
        pattern: "(?i)aws(.{0,20})?(secret|private)(.{0,20})?['\"][0-9a-zA-Z/+]{40}['\"]"
    )

    static let githubToken = SecretRule(
        identifier: "github.token",
        displayName: String(localized: "GitHub token"),
        summary: String(localized: "Personal access, OAuth and app tokens (ghp_, gho_, github_pat_)."),
        confidence: .certain,
        pattern: "\\b(ghp|gho|ghu|ghs|ghr|github_pat)_[0-9a-zA-Z_]{22,}\\b"
    )

    static let openAIKey = SecretRule(
        identifier: "generic.api-key",
        displayName: String(localized: "API key (sk- / pk-)"),
        summary: String(localized: "The sk-/pk- prefix used by many API providers."),
        confidence: .certain,
        pattern: "\\b(sk|pk)-[A-Za-z0-9_-]{20,}\\b"
    )

    static let privateKeyBlock = SecretRule(
        identifier: "pem.private-key",
        displayName: String(localized: "Private key block"),
        summary: String(localized: "PEM and OpenSSH private keys."),
        confidence: .certain,
        pattern: "-----BEGIN [A-Z ]*PRIVATE KEY-----"
    )

    static let jsonWebToken = SecretRule(
        identifier: "jwt",
        displayName: String(localized: "JSON web token"),
        summary: String(localized: "Three base64 segments beginning eyJ."),
        confidence: .likely,
        pattern: "\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\b"
    )

    /// A bare 6–8 digit number on its own is very likely a one-time code. We require the
    /// whole clip to be just the code so that copying a page of numbers is not caught.
    static let oneTimeCode = SecretRule(
        identifier: "otp",
        displayName: String(localized: "One-time code"),
        summary: String(localized: "A bare 6–8 digit number, on its own."),
        confidence: .likely
    ) { text in
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter(\.isNumber)
        guard digits.count == trimmed.replacingOccurrences(of: " ", with: "").count else { return false }
        return (6...8).contains(digits.count)
    }

    /// Credit card numbers: digit shape plus a Luhn check, which kills almost all
    /// false positives from order numbers and IDs.
    static let creditCard = SecretRule(
        identifier: "credit-card",
        displayName: String(localized: "Card number"),
        summary: String(localized: "13–19 digits that pass the Luhn check."),
        confidence: .certain
    ) { text in
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter(\.isNumber)
        guard (13...19).contains(digits.count) else { return false }
        // Reject anything that is not just a card number with separators.
        let allowed = CharacterSet(charactersIn: "0123456789 -")
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        return luhnIsValid(digits)
    }

    static let passwordAssignment = SecretRule(
        identifier: "password.assignment",
        displayName: String(localized: "Password assignment"),
        summary: String(localized: "password = …, token: …, api_key = … and similar."),
        confidence: .likely,
        pattern: "(?i)\\b(password|passwd|pwd|secret|token|api[_-]?key)\\b\\s*[:=]\\s*\\S{6,}"
    )

    /// The rules applied by default.
    ///
    /// Provider formats come first because they are unmistakable; the shape-based rules
    /// (codes, cards, assignments) come last because they are the ones a user is most
    /// likely to want to switch off.
    static let builtIn: [SecretRule] = providerRules + [
        .oneTimeCode, .creditCard, .passwordAssignment, .seedPhrase, .iban, .nationalIdentifier,
    ]

    /// Grouping used by the Settings list.
    static let providerRules: [SecretRule] = [
        .awsAccessKey, .awsSecretKey, .githubToken, .gitlabToken, .openAIKey, .anthropicKey,
        .stripeKey, .slackToken, .googleAPIKey, .huggingFaceToken, .npmToken, .twilioKey,
        .sendGridKey, .discordBotToken, .telegramBotToken, .cloudflareToken,
        .privateKeyBlock, .jsonWebToken, .appSpecificPassword, .basicAuthURL,
        .databaseURL, .environmentFile, .kubeConfig,
    ]
}

/// Luhn checksum used by the credit-card rule.
func luhnIsValid(_ digits: some StringProtocol) -> Bool {
    var sum = 0
    var double = false
    for character in digits.reversed() {
        guard let value = character.wholeNumberValue else { return false }
        var addend = value
        if double {
            addend *= 2
            if addend > 9 { addend -= 9 }
        }
        sum += addend
        double.toggle()
    }
    return sum % 10 == 0
}
