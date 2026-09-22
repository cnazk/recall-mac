import Foundation
import Testing
@testable import RecallCore

@Suite("Hex colour parsing")
struct HexColorTests {
    @Test("Parses 3, 6 and 8 digit forms")
    func parsesForms() throws {
        let short = try #require(HexColor(parsing: "#f80"))
        #expect(short.raw == "#ff8800")

        let long = try #require(HexColor(parsing: "FF8800"))
        #expect(abs(long.red - 1.0) < 0.001)
        #expect(abs(long.green - 0.533) < 0.01)
        #expect(long.alpha == 1)

        let withAlpha = try #require(HexColor(parsing: "#ff880080"))
        #expect(abs(withAlpha.alpha - 0.502) < 0.01)
    }

    @Test("Rejects non-colours")
    func rejectsGarbage() {
        #expect(HexColor(parsing: "hello") == nil)
        #expect(HexColor(parsing: "#ff88") == nil)
        #expect(HexColor(parsing: "") == nil)
    }
}

@Suite("Content hashing")
struct ContentHashTests {
    @Test("Identical text hashes identically")
    func stableForSameText() {
        #expect(ContentHash(.text("hello")) == ContentHash(.text("hello")))
    }

    @Test("Different kinds never collide")
    func kindIsPartOfTheHash() {
        let url = URL(string: "https://example.com")!
        #expect(ContentHash(.text(url.absoluteString)) != ContentHash(.url(url)))
    }

    @Test("Rich text with different formatting is a different clip")
    func formattingMatters() {
        let plain = "hello"
        let a = ClipPayload.richText(rtf: Data("{\\rtf1 bold}".utf8), plain: plain)
        let b = ClipPayload.richText(rtf: Data("{\\rtf1 italic}".utf8), plain: plain)
        #expect(ContentHash(a) != ContentHash(b))
    }

    @Test("File lists hash order-independently")
    func fileOrderDoesNotMatter() {
        let one = FileReference(url: URL(fileURLWithPath: "/tmp/a"))
        let two = FileReference(url: URL(fileURLWithPath: "/tmp/b"))
        #expect(ContentHash(.files([one, two])) == ContentHash(.files([two, one])))
    }
}

@Suite("Expiry")
struct ExpiryTests {
    @Test("An item expires exactly at its deadline")
    func expiresAtDeadline() {
        let now = Date(timeIntervalSince1970: 1_000)
        let item = ClipItem(
            payload: .text("123456"),
            contentHash: ContentHash(.text("123456")),
            createdAt: now,
            sensitivity: .secret,
            expiresAt: now.addingTimeInterval(60)
        )

        #expect(!item.hasExpired(asOf: now.addingTimeInterval(59)))
        #expect(item.hasExpired(asOf: now.addingTimeInterval(60)))
    }

    @Test("Items without a deadline never expire")
    func normalItemsSurvive() {
        let item = ClipItem(payload: .text("x"), contentHash: ContentHash(.text("x")))
        #expect(!item.hasExpired(asOf: .distantFuture))
    }
}

@Suite("Settings persistence")
struct SettingsStoreTests {
    /// A private defaults domain, so the suite never touches the user's real settings.
    private func makeStore() throws -> (SettingsStore, UserDefaults) {
        let suiteName = "com.recall.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (SettingsStore(defaults: defaults, key: "settings"), defaults)
    }

    @Test("An empty store returns the defaults")
    func defaultsWhenEmpty() throws {
        let (store, _) = try makeStore()
        #expect(store.load() == RecallSettings.default)
    }

    @Test("Settings round-trip")
    func roundTrips() throws {
        let (store, _) = try makeStore()

        var settings = RecallSettings.default
        settings.storageMode = .inMemory
        settings.secretTimeToLive = 30
        settings.userExcludedBundleIDs = ["com.example.vault"]
        settings.retention = nil
        store.save(settings)

        #expect(store.load() == settings)
    }

    @Test("Corrupt stored settings fall back to the defaults rather than failing to launch")
    func survivesCorruption() throws {
        let (store, defaults) = try makeStore()
        defaults.set(Data("not json".utf8), forKey: "settings")
        #expect(store.load() == RecallSettings.default)
    }

    @Test("Resetting clears the stored value")
    func resets() throws {
        let (store, _) = try makeStore()
        var settings = RecallSettings.default
        settings.historyLimit = 42
        store.save(settings)
        store.reset()
        #expect(store.load() == RecallSettings.default)
    }

    @Test("Only the storage mode needs a relaunch")
    func identifiesRestartRequiringChanges() {
        var changed = RecallSettings.default
        changed.historyLimit = 99
        #expect(!changed.requiresRestart(comparedTo: .default))

        changed.storageMode = .inMemory
        #expect(changed.requiresRestart(comparedTo: .default))
    }
}
