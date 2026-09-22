import Foundation
import RecallCore
import RecallStorage

/// A history item with the score that put it where it is in the results.
public struct ScoredItem: Sendable, Identifiable {
    public let item: ClipItem
    public let score: Float
    public var id: UUID { item.id }

    public init(item: ClipItem, score: Float) {
        self.item = item
        self.score = score
    }
}

/// Searches history by meaning as well as by literal text.
///
/// Results are the union of the keyword hits (from SQLite FTS) and the nearest
/// embeddings, blended so that an exact substring match still wins — typing `border` and
/// not getting the snippet containing the word `border` would feel broken, however good
/// the semantic hit is.
public actor SemanticSearch {
    private let store: SQLiteHistoryStore
    private let provider: any EmbeddingProvider
    private let expander: any QueryExpanding
    /// Below this cosine similarity, a semantic hit is noise rather than a result.
    private let similarityFloor: Float

    /// How far a backfill has got, for the progress indicator in the panel.
    public private(set) var indexingProgress: (done: Int, remaining: Int) = (0, 0)

    public init(
        store: SQLiteHistoryStore,
        provider: any EmbeddingProvider,
        expander: any QueryExpanding = NoQueryExpansion(),
        similarityFloor: Float = 0.35
    ) {
        self.store = store
        self.provider = provider
        self.expander = expander
        self.similarityFloor = similarityFloor
    }

    /// Embeds any item that does not yet have a vector for the current model.
    /// Called on a low-priority task after capture and at app launch for backfill.
    @discardableResult
    public func indexPending(limit: Int = 50) async -> Int {
        do {
            // Vectors from a previous model are not comparable with the current one, so
            // a model change discards them rather than quietly mixing coordinate spaces.
            try await store.deleteEmbeddings(exceptModel: provider.modelIdentifier)

            let pending = try await store.itemsWithoutEmbeddings(model: provider.modelIdentifier, limit: limit)
            let outstanding = try await store.pendingEmbeddingCount(model: provider.modelIdentifier)
            indexingProgress = (0, outstanding)

            var indexed = 0
            for item in pending {
                if Task.isCancelled { break }
                let text = item.indexableText
                guard !text.isEmpty else { continue }
                guard let vector = try? provider.embed(text) else { continue }
                try await store.setEmbedding(vector, model: provider.modelIdentifier, itemID: item.id)
                indexed += 1
                indexingProgress = (indexed, max(outstanding - indexed, 0))
            }
            return indexed
        } catch {
            Log.intelligence.error("Embedding backfill failed: \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    public func search(_ text: String, base: HistoryQuery = .recent, limit: Int = 50) async throws -> [ScoredItem] {
        var query = base
        query.text = text
        query.limit = limit

        let keywordHits = try await store.items(matching: query)
        var scores: [UUID: Float] = [:]
        var items: [UUID: ClipItem] = [:]

        // Keyword hits start at 1.0 and decay with rank, so the literal order is preserved.
        for (rank, item) in keywordHits.enumerated() {
            items[item.id] = item
            scores[item.id] = 1.0 - Float(rank) * 0.001
        }

        // Expanded terms: "CSS rounding" also searches for "border-radius". Scored below
        // any literal hit, because the user's own words always win.
        for term in await expander.expand(text) {
            var expanded = base
            expanded.text = term
            expanded.limit = limit
            for (rank, item) in (try await store.items(matching: expanded)).enumerated() {
                items[item.id] = item
                let score = 0.8 - Float(rank) * 0.001
                scores[item.id] = max(scores[item.id] ?? 0, score)
            }
        }

        guard let queryVector = try? provider.embed(text) else {
            return rank(scores: scores, items: items, limit: limit)
        }

        // When the query carries filters, only vectors for the surviving items are worth
        // scoring — this is also what keeps brute force viable as history grows.
        var eligible: Set<UUID>?
        if base.kinds != nil || !base.tags.isEmpty || base.sourceApp != nil || base.since != nil || base.pinnedOnly {
            var filtered = base
            filtered.text = nil
            filtered.limit = .max
            eligible = Set(try await store.items(matching: filtered).map(\.id))
        }

        let stored = try await store.embeddings(model: provider.modelIdentifier)
        var semantic: [(UUID, Float)] = []
        for (itemID, vector) in stored {
            if let eligible, !eligible.contains(itemID) { continue }
            let similarity = Vector.similarity(queryVector, vector)
            if similarity >= similarityFloor {
                semantic.append((itemID, similarity))
            }
        }
        semantic.sort { $0.1 > $1.1 }

        for (itemID, similarity) in semantic.prefix(limit) {
            guard let item = try await store.item(id: itemID) else { continue }
            items[itemID] = item
            // A semantic-only hit can never outrank a keyword hit.
            scores[itemID] = max(scores[itemID] ?? 0, similarity * 0.9)
        }

        return rank(scores: scores, items: items, limit: limit)
    }

    private func rank(scores: [UUID: Float], items: [UUID: ClipItem], limit: Int) -> [ScoredItem] {
        scores
            .compactMap { id, score in items[id].map { ScoredItem(item: $0, score: score) } }
            .sorted { lhs, rhs in
                if lhs.item.isPinned != rhs.item.isPinned { return lhs.item.isPinned }
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.item.lastUsedAt > rhs.item.lastUsedAt
            }
            .prefix(limit)
            .map { $0 }
    }
}
