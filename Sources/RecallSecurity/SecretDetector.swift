import Foundation
import RecallCore

/// The verdict for one clip.
public struct SecretVerdict: Sendable, Equatable {
    public let isSecret: Bool
    /// Identifiers of the rules that fired, for the "why was this hidden?" affordance.
    public let matchedRules: [String]
    public let confidence: SecretRule.Confidence?

    public static let clean = SecretVerdict(isSecret: false, matchedRules: [], confidence: nil)
}

/// Classifies clip content as sensitive or not.
///
/// Detection runs on the capture path, before anything is written, so a secret never
/// reaches the database in the first place.
public struct SecretDetector: Sendable {
    private let rules: [SecretRule]
    private let minimumConfidence: SecretRule.Confidence

    public init(rules: [SecretRule] = SecretRule.builtIn, minimumConfidence: SecretRule.Confidence = .likely) {
        self.rules = rules
        self.minimumConfidence = minimumConfidence
    }

    /// Builds a detector with the rules the user has left switched on.
    public init(settings: RecallSettings, minimumConfidence: SecretRule.Confidence = .likely) {
        self.init(
            rules: SecretRule.builtIn.filter { !settings.disabledSecretRules.contains($0.identifier) },
            minimumConfidence: minimumConfidence
        )
    }

    /// Identifiers of the rules this detector is running.
    public var activeRuleIdentifiers: Set<String> {
        Set(rules.map(\.identifier))
    }

    public func inspect(_ text: String) -> SecretVerdict {
        guard !text.isEmpty else { return .clean }
        let matched = rules.filter { $0.matches(text) }
        let best = matched.map(\.confidence).max()
        guard let best, best >= minimumConfidence else {
            return SecretVerdict(isSecret: false, matchedRules: matched.map(\.identifier), confidence: best)
        }
        return SecretVerdict(isSecret: true, matchedRules: matched.map(\.identifier), confidence: best)
    }

    public func inspect(_ payload: ClipPayload) -> SecretVerdict {
        guard let text = payload.searchableText else { return .clean }
        return inspect(text)
    }
}
