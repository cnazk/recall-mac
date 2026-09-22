import Foundation
import RecallCore

/// History that lives only in RAM.
///
/// This is both the In-Memory Mode implementation and the store the tests run against.
/// Items are held newest-first; pinned items always sort above unpinned ones.
public actor InMemoryHistoryStore: HistoryStore {
    private var storage: [ClipItem] = []
    private var indexByHash: [ContentHash: UUID] = [:]

    public init() {}

    @discardableResult
    public func capture(_ item: ClipItem) throws -> CaptureOutcome {
        if let existingID = indexByHash[item.contentHash],
           let index = storage.firstIndex(where: { $0.id == existingID }) {
            var existing = storage.remove(at: index)
            existing.lastUsedAt = item.createdAt
            existing.useCount += 1
            // A re-copy refreshes the countdown rather than inheriting the old deadline.
            existing.expiresAt = item.expiresAt
            existing.source = item.source ?? existing.source
            storage.insert(existing, at: 0)
            return .promoted(existing)
        }

        storage.insert(item, at: 0)
        indexByHash[item.contentHash] = item.id
        return .inserted(item)
    }

    public func items(matching query: HistoryQuery) throws -> [ClipItem] {
        var results = storage

        if query.pinnedOnly {
            results = results.filter(\.isPinned)
        }
        if let kinds = query.kinds, !kinds.isEmpty {
            results = results.filter { kinds.contains($0.kind) }
        }
        if !query.tags.isEmpty {
            results = results.filter { !$0.tags.isDisjoint(with: query.tags) }
        }
        if let since = query.since {
            results = results.filter { $0.createdAt >= since }
        }
        if let app = query.sourceApp?.lowercased() {
            results = results.filter { item in
                [item.source?.localizedName, item.source?.bundleIdentifier]
                    .compactMap { $0?.lowercased() }
                    .contains { $0.contains(app) }
            }
        }
        if let text = query.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            // Folded on both sides, so In-Memory Mode searches the way the SQLite store
            // does rather than being subtly stricter about Arabic-script spellings.
            let needle = SearchText.normalized(text)
            results = results.filter {
                SearchText.normalized($0.indexableText).localizedCaseInsensitiveContains(needle)
            }
        }

        results.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            // Pinned items hold their user-assigned position.
            let lhsOrder = lhs.pinOrder ?? Int.max
            let rhsOrder = rhs.pinOrder ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return lhs.lastUsedAt > rhs.lastUsedAt
        }

        let start = min(query.offset, results.count)
        let end = min(start + query.limit, results.count)
        return Array(results[start..<end])
    }

    public func snippets() throws -> [ClipItem] {
        storage.filter { $0.snippetCode != nil }
    }

    public func item(id: UUID) throws -> ClipItem? {
        storage.first { $0.id == id }
    }

    public func markUsed(id: UUID, at date: Date) throws {
        guard let index = storage.firstIndex(where: { $0.id == id }) else { return }
        storage[index].lastUsedAt = date
        storage[index].useCount += 1
    }

    public func setPinned(_ pinned: Bool, id: UUID) throws {
        guard let index = storage.firstIndex(where: { $0.id == id }) else { return }
        storage[index].isPinned = pinned
        // A new pin goes to the end of the pinned group; unpinning drops the ordinal.
        let highest = storage.compactMap(\.pinOrder).max() ?? 0
        storage[index].pinOrder = pinned ? highest + PinOrder.spacing : nil
    }

    public func reorderPins(_ ids: [UUID]) throws {
        for (position, id) in ids.enumerated() {
            guard let index = storage.firstIndex(where: { $0.id == id }), storage[index].isPinned else { continue }
            storage[index].pinOrder = (position + 1) * PinOrder.spacing
        }
    }

    public func applyEnrichment(_ enrichment: ClipEnrichment, to id: UUID) throws {
        guard !enrichment.isEmpty, let index = storage.firstIndex(where: { $0.id == id }) else { return }
        storage[index] = enrichment.applied(to: storage[index])
    }

    public func update(_ item: ClipItem) throws {
        guard let index = storage.firstIndex(where: { $0.id == item.id }) else { return }
        let old = storage[index]
        if old.contentHash != item.contentHash {
            indexByHash[old.contentHash] = nil
            indexByHash[item.contentHash] = item.id
        }
        storage[index] = item
    }

    public func delete(id: UUID) throws {
        guard let index = storage.firstIndex(where: { $0.id == id }) else { return }
        indexByHash[storage[index].contentHash] = nil
        storage.remove(at: index)
    }

    public func deleteAll() throws {
        storage.removeAll()
        indexByHash.removeAll()
    }

    @discardableResult
    public func purgeExpired(asOf date: Date) throws -> Int {
        // A pinned item is never removed automatically, even when it is a detected
        // secret past its deadline: the pin is the user overruling us, and the UI warns
        // rather than deletes.
        let doomed = storage.filter { !$0.isPinned && $0.hasExpired(asOf: date) }
        for item in doomed {
            indexByHash[item.contentHash] = nil
        }
        let condemned = Set(doomed.map(\.id))
        storage.removeAll { condemned.contains($0.id) }
        return doomed.count
    }

    @discardableResult
    public func enforceRetention(limit: Int, olderThan cutoff: Date?) throws -> Int {
        var removed = 0

        if let cutoff {
            let doomed = storage.filter { !$0.isPinned && $0.createdAt < cutoff }
            for item in doomed { indexByHash[item.contentHash] = nil }
            storage.removeAll { !$0.isPinned && $0.createdAt < cutoff }
            removed += doomed.count
        }

        // Pinned items are never counted against the limit and never evicted.
        let unpinned = storage.filter { !$0.isPinned }
        if unpinned.count > limit {
            let doomed = Set(unpinned.sorted { $0.lastUsedAt > $1.lastUsedAt }.dropFirst(limit).map(\.id))
            for item in storage where doomed.contains(item.id) { indexByHash[item.contentHash] = nil }
            storage.removeAll { doomed.contains($0.id) }
            removed += doomed.count
        }

        return removed
    }

    public var count: Int {
        get throws { storage.count }
    }

    /// Always zero: In-Memory Mode's whole promise is that there is nothing on disk.
    public var footprint: Int64 {
        get throws { 0 }
    }
}
