import CryptoKit
import Foundation
import NaturalLanguage
import Testing
@testable import RecallCore
@testable import RecallIntelligence
@testable import RecallStorage

/// A fixture corpus and the queries a user would actually type at it.
///
/// This exists so ranking changes are *measured* rather than argued about. It is small
/// and honest: every expectation is a clip a person would plainly agree is the right
/// answer to that search.
enum Corpus {
    struct Case: Sendable, Hashable {
        let query: String
        /// Text of the clip that must come back.
        let expected: String
        /// Whether the query shares words with the answer. Queries that do not are the
        /// entire reason semantic search exists.
        let isLexical: Bool
    }

    static let clips: [String] = [
        "border-radius: 8px;\nbox-shadow: 0 1px 2px rgba(0,0,0,.2);",
        "def parse_amount(value):\n    return int(value.replace(',', ''))",
        "SELECT id, email FROM users WHERE created_at > now() - interval '7 days';",
        "AA219 · SFO → BOS · departs 14:05 · seat 22A · confirmation QJ8P2M",
        "Invoice #4471 — Total due $1,284.00 — Net 30 — Acme Supply Co.",
        "Dr Patel, Tuesday 3:40pm, Bayview Medical, bring the referral letter",
        "git rebase --interactive --autosquash origin/main",
        "The quarterly report is attached. Let me know if the numbers look off. — Sam",
        "https://developer.apple.com/documentation/foundationmodels",
        "192.168.1.14:8080",
        "Flat white, oat milk, extra hot — Maria's usual order",
        "brew install --cask font-jetbrains-mono",
        "Apartment viewing: 14 Rosemount Ave, Saturday 11am, ask about parking",
        "npm run build -- --analyze",
        "Happy birthday! Hope the year ahead is a good one. See you Sunday x",
    ]

    static let cases: [Case] = [
        .init(query: "CSS rounding", expected: "border-radius", isLexical: false),
        .init(query: "flight details", expected: "AA219", isLexical: false),
        .init(query: "doctor appointment", expected: "Dr Patel", isLexical: false),
        .init(query: "how much do I owe", expected: "Invoice #4471", isLexical: false),
        .init(query: "coffee order", expected: "Flat white", isLexical: false),
        .init(query: "border-radius", expected: "border-radius", isLexical: true),
        .init(query: "rebase", expected: "git rebase", isLexical: true),
        .init(query: "invoice", expected: "Invoice #4471", isLexical: true),
    ]
}

/// Stands in for the on-device model, so the harness measures ranking rather than
/// whatever Apple Intelligence happens to say today.
private struct ScriptedExpander: QueryExpanding {
    static let table: [String: [String]] = [
        "css rounding": ["border-radius", "corner radius", "rounded"],
        "flight details": ["departs", "seat", "confirmation"],
        "doctor appointment": ["dr", "medical", "referral"],
        "how much do I owe": ["invoice", "total due", "net 30"],
        "coffee order": ["flat white", "oat milk", "latte"],
    ]

    func expand(_ query: String) async -> [String] {
        Self.table[query.lowercased()] ?? []
    }
}

private func makeStore() throws -> SQLiteHistoryStore {
    try SQLiteHistoryStore(
        url: nil,
        keyStore: EphemeralKeyStore(key: SymmetricKey(data: Data(repeating: 5, count: 32))),
        blobDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recall-eval-\(UUID().uuidString)", isDirectory: true)
    )
}

private func populate(_ store: SQLiteHistoryStore, provider: (any EmbeddingProvider)?) async throws {
    for (offset, text) in Corpus.clips.enumerated() {
        let item = ClipItem(
            payload: .text(text),
            contentHash: ContentHash(.text(text)),
            createdAt: Date(timeIntervalSince1970: Double(1_000 + offset))
        )
        try await store.capture(item)
        if let provider, let vector = try? provider.embed(text) {
            try await store.setEmbedding(vector, model: provider.modelIdentifier, itemID: item.id)
        }
    }
}

/// Fraction of cases whose expected clip appears in the top `k`.
private func recall(at k: Int, results: [Corpus.Case: [ClipItem]]) -> Double {
    guard !results.isEmpty else { return 0 }
    let hits = results.filter { testCase, items in
        items.prefix(k).contains { ($0.payload.searchableText ?? "").contains(testCase.expected) }
    }
    return Double(hits.count) / Double(results.count)
}

@Suite("Search ranking")
struct RankingEvalTests {
    /// The embedding model ships with the OS but is not guaranteed in every environment.
    private var provider: NLEmbeddingProvider? { try? NLEmbeddingProvider() }

    @Test("Literal searches are never lost to semantic reranking")
    func literalQueriesAlwaysWin() async throws {
        let store = try makeStore()
        try await populate(store, provider: provider)

        guard let provider else { return }
        let search = SemanticSearch(store: store, provider: provider, expander: ScriptedExpander())

        for testCase in Corpus.cases where testCase.isLexical {
            let results = try await search.search(testCase.query, limit: 10)
            let top = try #require(results.first?.item.payload.searchableText)
            #expect(top.contains(testCase.expected), "\(testCase.query) should return its literal match first")
        }
    }

    /// The finding this harness was built to produce: sentence embeddings alone do not
    /// carry technical synonymy, which is the product's headline claim.
    @Test("Measured: embeddings alone do not answer vocabulary-mismatch queries")
    func embeddingsAloneAreNotEnough() async throws {
        let store = try makeStore()
        try await populate(store, provider: provider)

        guard let provider else { return }
        let search = SemanticSearch(store: store, provider: provider, expander: NoQueryExpansion())

        var results: [Corpus.Case: [ClipItem]] = [:]
        for testCase in Corpus.cases where !testCase.isLexical {
            results[testCase] = try await search.search(testCase.query, limit: 10).map(\.item)
        }

        let recallAt3 = recall(at: 3, results: results)
        print("[eval] embeddings only — recall@3 over non-lexical queries: \(recallAt3)")

        // Deliberately asserts the *ceiling*, not a floor. If a future change makes
        // embeddings alone good enough, this test fails and the finding gets revisited —
        // which is the point of a harness.
        #expect(recallAt3 < 1.0, "embeddings alone answered everything; re-evaluate the expansion layer")
    }

    @Test("Query expansion closes the vocabulary gap")
    func expansionRecoversTheHardQueries() async throws {
        let store = try makeStore()
        try await populate(store, provider: provider)

        guard let provider else { return }
        let expanded = SemanticSearch(store: store, provider: provider, expander: ScriptedExpander())
        let plain = SemanticSearch(store: store, provider: provider, expander: NoQueryExpansion())

        var withExpansion: [Corpus.Case: [ClipItem]] = [:]
        var without: [Corpus.Case: [ClipItem]] = [:]
        for testCase in Corpus.cases where !testCase.isLexical {
            withExpansion[testCase] = try await expanded.search(testCase.query, limit: 10).map(\.item)
            without[testCase] = try await plain.search(testCase.query, limit: 10).map(\.item)
        }

        let before = recall(at: 3, results: without)
        let after = recall(at: 3, results: withExpansion)
        print("[eval] recall@3 — embeddings only: \(before), with expansion: \(after)")

        #expect(after > before, "expansion must improve the queries embeddings cannot answer")
        #expect(after >= 0.8, "expansion should answer at least four of the five hard queries")
    }

    @Test("The headline demo works: 'CSS rounding' finds border-radius")
    func cssRoundingFindsBorderRadius() async throws {
        let store = try makeStore()
        try await populate(store, provider: provider)

        guard let provider else { return }
        let search = SemanticSearch(store: store, provider: provider, expander: ScriptedExpander())

        let results = try await search.search("CSS rounding", limit: 5)
        let top = try #require(results.first?.item.payload.searchableText)
        #expect(top.contains("border-radius"))
    }
}

@Suite("Query operators")
struct QueryParserTests {
    let parser = QueryParser()
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Kinds, apps and dates are lifted out of the text")
    func parsesOperators() {
        let parsed = parser.parse("kind:image app:Xcode since:today rounded corners", now: now)
        #expect(parsed.kinds == [.image])
        #expect(parsed.sourceApp == "Xcode")
        #expect(parsed.since != nil)
        #expect(parsed.text == "rounded corners")
    }

    @Test("Plurals and aliases are accepted")
    func acceptsAliases() {
        #expect(parser.parse("kind:links", now: now).kinds == [.url])
        #expect(parser.parse("type:screenshots", now: now).kinds == [.image])
        #expect(parser.parse("from:Safari", now: now).sourceApp == "Safari")
        #expect(parser.parse("is:pinned", now: now).pinnedOnly)
    }

    @Test("An unknown operator stays part of the search text")
    func leavesUnknownTokensAlone() {
        let parsed = parser.parse("ratio:16:9 aspect", now: now)
        #expect(parsed.text == "ratio:16:9 aspect")
        #expect(parsed.kinds == nil)
    }

    @Test("A colon in ordinary text does not swallow words")
    func doesNotEatColons() {
        let parsed = parser.parse("note: remember the milk", now: now)
        #expect(parsed.text == "note: remember the milk")
    }

    @Test("Relative dates resolve against the given clock")
    func resolvesRelativeDates() throws {
        let calendar = Calendar(identifier: .gregorian)
        let yesterday = try #require(parser.parse("since:yesterday", now: now, calendar: calendar).since)
        let today = try #require(parser.parse("since:today", now: now, calendar: calendar).since)
        #expect(yesterday < today)
        #expect(today <= now)
    }
}
