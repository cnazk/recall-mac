import CryptoKit
import Foundation
import RecallCore
import Testing
@testable import RecallStorage

/// Pins and shortcodes are the two things in Recall the user sets by hand, so they are
/// the two that must survive a relaunch. Nothing else in the history is worth re-creating.
@Suite("Pins and shortcodes survive a relaunch")
struct PinPersistenceTests {
    private let key = SymmetricKey(data: Data(repeating: 7, count: 32))

    private func temporaryURL(_ suffix: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recall-\(suffix)-\(UUID().uuidString)")
    }

    private func makeStore(_ url: URL, _ blobs: URL) throws -> SQLiteHistoryStore {
        try SQLiteHistoryStore(url: url, keyStore: EphemeralKeyStore(key: key), blobDirectory: blobs)
    }

    @Test("A pin is still there after the store is reopened")
    func pinSurvives() async throws {
        let url = temporaryURL("pins")
        let blobs = temporaryURL("pin-blobs")
        defer { try? FileManager.default.removeItem(at: url) }

        let item = ClipItem(payload: .text("keep me"), contentHash: ContentHash(.text("keep me")))
        do {
            let store = try makeStore(url, blobs)
            try await store.capture(item)
            try await store.setPinned(true, id: item.id)
            #expect(try await store.item(id: item.id)?.isPinned == true, "not even pinned in memory")
            try await store.checkpoint()
        }

        let reopened = try makeStore(url, blobs)
        let restored = try await reopened.item(id: item.id)
        #expect(restored?.isPinned == true, "the pin did not reach the disk")
        #expect(restored?.pinOrder != nil, "a pin with no ordinal has no place in the rail")
    }

    @Test("A shortcode is still there after the store is reopened")
    func shortcodeSurvives() async throws {
        let url = temporaryURL("codes")
        let blobs = temporaryURL("code-blobs")
        defer { try? FileManager.default.removeItem(at: url) }

        var item = ClipItem(payload: .text("my signature"), contentHash: ContentHash(.text("my signature")))
        item.snippetCode = ":sig"
        do {
            let store = try makeStore(url, blobs)
            try await store.capture(item)
            try await store.update(item)
            try await store.checkpoint()
        }

        let reopened = try makeStore(url, blobs)
        #expect(try await reopened.item(id: item.id)?.snippetCode == ":sig")
        #expect(try await reopened.snippets().count == 1, "expansion reads this list")
    }

    /// Retention and the history limit both delete, and a pin is the user saying keep it.
    @Test("Enforcing the history limit does not take the pins with it")
    func retentionSparesPins() async throws {
        let url = temporaryURL("retention")
        let blobs = temporaryURL("retention-blobs")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try makeStore(url, blobs)

        let old = Date(timeIntervalSince1970: 0)
        let pinned = ClipItem(payload: .text("pinned"), contentHash: ContentHash(.text("pinned")), createdAt: old)
        let ordinary = ClipItem(payload: .text("ordinary"), contentHash: ContentHash(.text("ordinary")), createdAt: old)
        try await store.capture(pinned)
        try await store.capture(ordinary)
        try await store.setPinned(true, id: pinned.id)

        _ = try await store.enforceRetention(limit: 1, olderThan: Date(timeIntervalSince1970: 1_000))

        #expect(try await store.item(id: pinned.id) != nil, "a pin was deleted by retention")
        #expect(try await store.item(id: ordinary.id) == nil)
    }
}

/// The bug behind "my pins do not save".
///
/// Enrichment reads a clip at capture and writes it back when the fetching, the OCR and
/// the model calls are done — seconds later, sometimes longer. It used to write the whole
/// item, which meant writing `isPinned: false` and `snippetCode: nil` as they were before
/// the user had touched either. Pinning a clip you had just copied worked, showed in the
/// rail, and was silently undone a few seconds later.
@Suite("Enrichment does not undo what the user did")
struct EnrichmentMergeTests {
    private let key = SymmetricKey(data: Data(repeating: 11, count: 32))

    private func makeStore() throws -> SQLiteHistoryStore {
        try SQLiteHistoryStore(url: nil, keyStore: EphemeralKeyStore(key: key), blobDirectory: nil)
    }

    @Test("A pin set while enrichment was in flight survives it")
    func pinSurvivesLateEnrichment() async throws {
        let store = try makeStore()
        let item = ClipItem(payload: .text("config"), contentHash: ContentHash(.text("config")))
        try await store.capture(item)

        // The user pins it while the background pass is away fetching.
        try await store.setPinned(true, id: item.id)

        // The pass finishes and reports what it found, holding its pre-pin copy.
        try await store.applyEnrichment(ClipEnrichment(of: item, summary: "a config file"), to: item.id)

        let after = try #require(try await store.item(id: item.id))
        #expect(after.isPinned, "enrichment unpinned it")
        #expect(after.pinOrder != nil)
        #expect(after.summary == "a config file", "the enrichment was dropped instead")
    }

    @Test("A shortcode assigned while enrichment was in flight survives it")
    func shortcodeSurvivesLateEnrichment() async throws {
        let store = try makeStore()
        let item = ClipItem(payload: .text("my signature"), contentHash: ContentHash(.text("my signature")))
        try await store.capture(item)

        var coded = item
        coded.snippetCode = ":sig"
        try await store.update(coded)

        try await store.applyEnrichment(ClipEnrichment(of: item, tags: ["notes"]), to: item.id)

        let after = try #require(try await store.item(id: item.id))
        #expect(after.snippetCode == ":sig", "enrichment erased the shortcode")
        #expect(after.tags == ["notes"])
    }

    /// Enrichment fills gaps; it does not get a second opinion on what is already there.
    @Test("What is already on the row wins")
    func doesNotOverwriteExistingValues() {
        var current = ClipItem(payload: .text("x"), contentHash: ContentHash(.text("x")))
        current.summary = "what the user kept"
        current.tags = ["code"]

        let merged = ClipEnrichment(summary: "a late guess", tags: ["notes"]).applied(to: current)
        #expect(merged.summary == "what the user kept")
        #expect(merged.tags == ["code", "notes"], "tags add rather than replace")
    }

    @Test("A clip deleted while the pass was working is not resurrected")
    func doesNotResurrectDeletedClips() async throws {
        let store = try makeStore()
        let item = ClipItem(payload: .text("gone"), contentHash: ContentHash(.text("gone")))
        try await store.capture(item)
        try await store.delete(id: item.id)

        try await store.applyEnrichment(ClipEnrichment(summary: "late"), to: item.id)
        #expect(try await store.item(id: item.id) == nil)
    }
}

private extension ClipEnrichment {
    /// The pipeline's output, as it arrives: a whole item that the pass has added to.
    init(of item: ClipItem, summary: String? = nil, tags: Set<String> = []) {
        var enriched = item
        enriched.summary = summary
        enriched.tags = tags
        self.init(of: enriched)
    }
}
