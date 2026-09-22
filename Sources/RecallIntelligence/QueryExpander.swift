import Foundation
import RecallCore

/// Turns a vague query into the words the user would have had to type.
///
/// Measured, not assumed: `NLEmbedding` scores "CSS rounding" against
/// `border-radius: 8px;` at about 0.20 — *below* an unrelated Python snippet. Sentence
/// embeddings carry prose similarity ("flight details" → an itinerary, ~0.49) but not
/// technical synonymy, which is exactly the case the product promises. Expanding the
/// query locally and feeding the extra terms to the keyword index closes that gap
/// without a model download.
public protocol QueryExpanding: Sendable {
    /// Related terms for `query`, excluding the query itself. Empty is always a valid
    /// answer: expansion is an enhancement, never a dependency.
    func expand(_ query: String) async -> [String]
}

/// Expansion through the on-device language model.
public actor LanguageModelQueryExpander: QueryExpanding {
    private let model: any LanguageModelProviding
    private let maximumTerms: Int
    /// Queries repeat constantly while typing, and the answer never changes.
    private var cache: [String: [String]] = [:]

    public init(model: any LanguageModelProviding = LanguageModelFactory.makeDefault(), maximumTerms: Int = 6) {
        self.model = model
        self.maximumTerms = maximumTerms
    }

    public func expand(_ query: String) async -> [String] {
        let key = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 80, model.isAvailable else { return [] }
        if let cached = cache[key] { return cached }

        let instructions = """
        The user is searching their clipboard history. Given their search, reply with up \
        to \(maximumTerms) comma-separated terms that would literally appear in the text \
        they are looking for — property names, function names, field labels, synonyms. \
        For "CSS rounding" you would answer: border-radius, corner-radius, rounded. \
        Reply with the terms only, no explanation.
        """

        guard let response = try? await model.respond(to: key, instructions: instructions) else {
            cache[key] = []
            return []
        }

        let terms = response
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0 != key && $0.count <= 40 }
            .prefix(maximumTerms)

        let result = Array(terms)
        cache[key] = result
        return result
    }
}

/// Expansion turned off.
public struct NoQueryExpansion: QueryExpanding {
    public init() {}
    public func expand(_ query: String) async -> [String] { [] }
}
