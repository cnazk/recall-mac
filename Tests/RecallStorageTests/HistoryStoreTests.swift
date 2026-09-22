import CryptoKit
import Foundation
import Testing
@testable import RecallCore
@testable import RecallStorage

/// A fixed key, so the suite never touches the real Keychain and a database can be
/// reopened within a test.
private let testKey = SymmetricKey(data: Data(repeating: 7, count: 32))
private var testKeyStore: EphemeralKeyStore { EphemeralKeyStore(key: testKey) }

private func makeSQLiteStore(url: URL? = nil) throws -> SQLiteHistoryStore {
    try SQLiteHistoryStore(
        url: url,
        keyStore: testKeyStore,
        blobDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recall-test-blobs-\(UUID().uuidString)", isDirectory: true)
    )
}

/// Both stores must behave identically, so the suite runs against each in turn.
private func makeStores() throws -> [(name: String, store: any HistoryStore)] {
    [
        ("in-memory", InMemoryHistoryStore()),
        ("sqlite", try makeSQLiteStore()),
    ]
}

private func item(_ text: String, createdAt: Date = Date(timeIntervalSince1970: 1_000)) -> ClipItem {
    ClipItem(payload: .text(text), contentHash: ContentHash(.text(text)), createdAt: createdAt)
}

@Suite("History stores")
struct HistoryStoreTests {
    @Test("Captured items come back newest first")
    func ordersByRecency() async throws {
        for (name, store) in try makeStores() {
            try await store.capture(item("first", createdAt: Date(timeIntervalSince1970: 1)))
            try await store.capture(item("second", createdAt: Date(timeIntervalSince1970: 2)))

            let items = try await store.items(matching: .recent)
            #expect(items.count == 2, "\(name)")
            #expect(items.first?.payload == .text("second"), "\(name)")
        }
    }

    @Test("Copying the same content twice promotes instead of duplicating")
    func deduplicates() async throws {
        for (name, store) in try makeStores() {
            let outcome1 = try await store.capture(item("hello", createdAt: Date(timeIntervalSince1970: 1)))
            try await store.capture(item("other", createdAt: Date(timeIntervalSince1970: 2)))
            let outcome2 = try await store.capture(item("hello", createdAt: Date(timeIntervalSince1970: 3)))

            guard case .inserted = outcome1 else { Issue.record("\(name): expected insert"); return }
            guard case .promoted(let promoted) = outcome2 else { Issue.record("\(name): expected promote"); return }

            #expect(try await store.count == 2, "\(name)")
            #expect(promoted.useCount == 1, "\(name)")

            let items = try await store.items(matching: .recent)
            #expect(items.first?.payload == .text("hello"), "\(name): promoted item should be on top")
        }
    }

    @Test("Pinned items sort above everything else")
    func pinnedFirst() async throws {
        for (name, store) in try makeStores() {
            let old = item("pinned", createdAt: Date(timeIntervalSince1970: 1))
            try await store.capture(old)
            try await store.capture(item("newer", createdAt: Date(timeIntervalSince1970: 2)))
            try await store.setPinned(true, id: old.id)

            let items = try await store.items(matching: .recent)
            #expect(items.first?.id == old.id, "\(name)")
        }
    }

    @Test("Pins hold their position instead of reshuffling by recency")
    func pinsKeepTheirOrder() async throws {
        for (name, store) in try makeStores() {
            let first = item("first pin", createdAt: Date(timeIntervalSince1970: 1))
            let second = item("second pin", createdAt: Date(timeIntervalSince1970: 2))
            try await store.capture(first)
            try await store.capture(second)
            try await store.setPinned(true, id: first.id)
            try await store.setPinned(true, id: second.id)

            // Using the older pin must not move it above the newer one.
            try await store.markUsed(id: first.id, at: Date(timeIntervalSince1970: 9_000))

            let pinned = try await store.items(matching: HistoryQuery(pinnedOnly: true))
            #expect(pinned.map(\.id) == [first.id, second.id], "\(name)")
        }
    }

    @Test("Reordering pins rewrites their positions")
    func reordersPins() async throws {
        for (name, store) in try makeStores() {
            let a = item("a", createdAt: Date(timeIntervalSince1970: 1))
            let b = item("b", createdAt: Date(timeIntervalSince1970: 2))
            let c = item("c", createdAt: Date(timeIntervalSince1970: 3))
            for clip in [a, b, c] {
                try await store.capture(clip)
                try await store.setPinned(true, id: clip.id)
            }

            try await store.reorderPins([c.id, a.id, b.id])

            let pinned = try await store.items(matching: HistoryQuery(pinnedOnly: true))
            #expect(pinned.map(\.id) == [c.id, a.id, b.id], "\(name)")
        }
    }

    @Test("Unpinning drops the ordinal so the item rejoins history by recency")
    func unpinningClearsOrder() async throws {
        for (name, store) in try makeStores() {
            let clip = item("pinned then not")
            try await store.capture(clip)
            try await store.setPinned(true, id: clip.id)
            try await store.setPinned(false, id: clip.id)

            let stored = try await store.item(id: clip.id)
            #expect(stored?.isPinned == false, "\(name)")
            #expect(stored?.pinOrder == nil, "\(name)")
        }
    }

    @Test("Text search matches item content")
    func searches() async throws {
        for (name, store) in try makeStores() {
            try await store.capture(item("border-radius: 8px"))
            try await store.capture(item("flight AA219 to Boston"))

            let hits = try await store.items(matching: HistoryQuery(text: "border"))
            #expect(hits.count == 1, "\(name)")
            #expect(hits.first?.payload == .text("border-radius: 8px"), "\(name)")
        }
    }

    @Test("Text recognised inside an image is searchable")
    func searchesImageText() async throws {
        for (name, store) in try makeStores() {
            let image = ImagePayload(data: Data([1, 2, 3]), uti: "public.png", pixelWidth: 8, pixelHeight: 8)
            var screenshot = ClipItem(payload: .image(image), contentHash: ContentHash(.image(image)))
            // What the OCR pass would have written after capture.
            screenshot.ocrText = "Gate B12 boarding at 14:05"
            try await store.capture(screenshot)
            try await store.update(screenshot)

            let hits = try await store.items(matching: HistoryQuery(text: "boarding"))
            #expect(hits.count == 1, "\(name): OCR text must reach the search index")
            #expect(hits.first?.id == screenshot.id, "\(name)")
        }
    }

    @Test("Kind filters narrow the list")
    func filtersByKind() async throws {
        for (name, store) in try makeStores() {
            let url = URL(string: "https://example.com")!
            try await store.capture(item("plain"))
            try await store.capture(ClipItem(payload: .url(url), contentHash: ContentHash(.url(url))))

            let links = try await store.items(matching: HistoryQuery(kinds: [.url]))
            #expect(links.count == 1, "\(name)")
            #expect(links.first?.kind == .url, "\(name)")
        }
    }

    @Test("Expired secrets are purged, survivors are not")
    func purgesExpired() async throws {
        for (name, store) in try makeStores() {
            let now = Date(timeIntervalSince1970: 1_000)
            var secret = item("483920", createdAt: now)
            secret.sensitivity = .secret
            secret.expiresAt = now.addingTimeInterval(60)

            try await store.capture(secret)
            try await store.capture(item("ordinary", createdAt: now))

            #expect(try await store.purgeExpired(asOf: now.addingTimeInterval(30)) == 0, "\(name)")
            #expect(try await store.purgeExpired(asOf: now.addingTimeInterval(61)) == 1, "\(name)")

            let remaining = try await store.items(matching: .recent)
            #expect(remaining.count == 1, "\(name)")
            #expect(remaining.first?.payload == .text("ordinary"), "\(name)")
        }
    }

    @Test("A pinned secret outlives its deadline instead of being purged")
    func pinningDefeatsExpiry() async throws {
        for (name, store) in try makeStores() {
            let now = Date(timeIntervalSince1970: 1_000)
            var secret = item("483920", createdAt: now)
            secret.sensitivity = .secret
            secret.expiresAt = now.addingTimeInterval(60)
            try await store.capture(secret)
            try await store.setPinned(true, id: secret.id)

            #expect(try await store.purgeExpired(asOf: now.addingTimeInterval(600)) == 0, "\(name)")
            #expect(try await store.item(id: secret.id) != nil, "\(name): a pin is never auto-removed")
        }
    }

    @Test("No automatic deletion path touches a pinned item")
    func pinsSurviveEveryAutomaticPath() async throws {
        for (name, store) in try makeStores() {
            let now = Date(timeIntervalSince1970: 1_000)
            var pinned = item("keep me", createdAt: Date(timeIntervalSince1970: 1))
            pinned.sensitivity = .secret
            pinned.expiresAt = now
            try await store.capture(pinned)
            try await store.setPinned(true, id: pinned.id)

            for index in 0..<10 {
                try await store.capture(item("clip \(index)", createdAt: Date(timeIntervalSince1970: Double(10 + index))))
            }

            // Expiry, the retention cutoff and the history limit, in turn.
            try await store.purgeExpired(asOf: now.addingTimeInterval(10_000))
            try await store.enforceRetention(limit: 1, olderThan: Date(timeIntervalSince1970: 5_000))

            #expect(try await store.item(id: pinned.id) != nil, "\(name)")
        }
    }

    @Test("Retention trims to the limit but never evicts pinned items")
    func enforcesRetention() async throws {
        for (name, store) in try makeStores() {
            let pinned = item("keep me", createdAt: Date(timeIntervalSince1970: 1))
            try await store.capture(pinned)
            try await store.setPinned(true, id: pinned.id)

            for index in 0..<10 {
                try await store.capture(item("clip \(index)", createdAt: Date(timeIntervalSince1970: Double(10 + index))))
            }

            try await store.enforceRetention(limit: 3, olderThan: nil)
            let items = try await store.items(matching: .recent)

            #expect(items.count == 4, "\(name): 3 unpinned + 1 pinned")
            #expect(items.contains { $0.id == pinned.id }, "\(name): pinned item must survive")
        }
    }

    @Test("Retention drops items older than the cutoff")
    func dropsOldItems() async throws {
        for (name, store) in try makeStores() {
            try await store.capture(item("ancient", createdAt: Date(timeIntervalSince1970: 100)))
            try await store.capture(item("recent", createdAt: Date(timeIntervalSince1970: 10_000)))

            try await store.enforceRetention(limit: 100, olderThan: Date(timeIntervalSince1970: 5_000))
            let items = try await store.items(matching: .recent)

            #expect(items.count == 1, "\(name)")
            #expect(items.first?.payload == .text("recent"), "\(name)")
        }
    }

    @Test("Deleting everything leaves nothing behind")
    func deletesAll() async throws {
        for (name, store) in try makeStores() {
            try await store.capture(item("a"))
            try await store.capture(item("b"))
            try await store.deleteAll()
            #expect(try await store.count == 0, "\(name)")
        }
    }

    @Test("Marking an item used bumps its counters")
    func marksUsed() async throws {
        for (name, store) in try makeStores() {
            let clip = item("paste me")
            try await store.capture(clip)
            let usedAt = Date(timeIntervalSince1970: 9_999)
            try await store.markUsed(id: clip.id, at: usedAt)

            let stored = try await store.item(id: clip.id)
            #expect(stored?.useCount == 1, "\(name)")
            #expect(stored?.lastUsedAt == usedAt, "\(name)")
        }
    }
}

@Suite("SQLite specifics")
struct SQLiteStoreTests {
    @Test("Search input is escaped rather than interpreted as FTS syntax")
    func escapesFTSQuery() {
        #expect(SearchIndex.ftsQuery(for: "border radius") == "\"border\"* AND \"radius\"*")
        #expect(SearchIndex.ftsQuery(for: "a OR b*") == "\"a\"* AND \"OR\"* AND \"b\"*")
    }

    @Test("Embeddings round-trip and are deleted with their item")
    func embeddingsCascade() async throws {
        let store = try makeSQLiteStore()
        let clip = ClipItem(payload: .text("css"), contentHash: ContentHash(.text("css")))
        try await store.capture(clip)
        try await store.setEmbedding([0.5, 0.5, 0.5, 0.5], model: "test", itemID: clip.id)

        let stored = try await store.embeddings(model: "test")
        #expect(stored.count == 1)
        #expect(stored.first?.vector.count == 4)

        try await store.delete(id: clip.id)
        #expect(try await store.embeddings(model: "test").isEmpty)
    }

    @Test("Items needing an embedding are reported for backfill")
    func reportsPendingEmbeddings() async throws {
        let store = try makeSQLiteStore()
        let clip = ClipItem(payload: .text("needs a vector"), contentHash: ContentHash(.text("needs a vector")))
        try await store.capture(clip)

        #expect(try await store.itemsWithoutEmbeddings(model: "test", limit: 10).count == 1)
        try await store.setEmbedding([1, 0], model: "test", itemID: clip.id)
        #expect(try await store.itemsWithoutEmbeddings(model: "test", limit: 10).isEmpty)
    }

    @Test("A database file survives being closed and reopened")
    func persistsAcrossOpens() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recall-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let blobs = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recall-test-blobs-\(UUID().uuidString)", isDirectory: true)

        do {
            let store = try SQLiteHistoryStore(url: url, keyStore: testKeyStore, blobDirectory: blobs)
            try await store.capture(ClipItem(payload: .text("durable"), contentHash: ContentHash(.text("durable"))))
        }

        let reopened = try SQLiteHistoryStore(url: url, keyStore: testKeyStore, blobDirectory: blobs)
        #expect(try await reopened.count == 1)
        // The in-memory search index is rebuilt from the decrypted rows at open.
        #expect(try await reopened.items(matching: HistoryQuery(text: "durable")).count == 1)
    }
}

@Suite("Expiry reaper")
struct ExpiryReaperTests {
    @Test("A sweep deletes exactly the items past their deadline")
    func sweepsOnDemand() async throws {
        let clock = MutableClock()
        let store = InMemoryHistoryStore()
        let reaper = ExpiryReaper(store: store, clock: clock, interval: 60)

        var secret = item("999888", createdAt: clock.now)
        secret.sensitivity = .secret
        secret.expiresAt = clock.now.addingTimeInterval(60)
        try await store.capture(secret)

        #expect(await reaper.sweep() == 0)
        clock.advance(by: 61)
        #expect(await reaper.sweep() == 1)
        #expect(try await store.count == 0)
    }
}
