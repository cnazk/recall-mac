import CryptoKit
import Foundation
import RecallCore
import RecallPaste
import RecallStorage
import Testing
@testable import RecallUI

/// The store keeps pins and shortcodes perfectly well on its own — there are tests for
/// that next door. This suite covers the part between the keystroke and the store, which
/// is where a pin that "does not save" actually goes missing.
@Suite("Pinning through the model", .serialized)
@MainActor
struct PinFlowTests {
    private func temporaryURL(_ suffix: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recall-\(suffix)-\(UUID().uuidString)")
    }

    private func makeStore(at url: URL, blobs: URL) throws -> SQLiteHistoryStore {
        try SQLiteHistoryStore(
            url: url,
            keyStore: EphemeralKeyStore(key: SymmetricKey(data: Data(repeating: 9, count: 32))),
            blobDirectory: blobs
        )
    }

    private func makeModel(_ store: SQLiteHistoryStore) -> AppModel {
        AppModel(store: store, paste: PasteService(), settings: .default)
    }

    @Test("Pinning from the model reaches the disk")
    func pinReachesDisk() async throws {
        let url = temporaryURL("pin-flow")
        let blobs = temporaryURL("pin-flow-blobs")
        defer { try? FileManager.default.removeItem(at: url) }

        let item = ClipItem(payload: .text("pin me"), contentHash: ContentHash(.text("pin me")))

        let store = try makeStore(at: url, blobs: blobs)
        try await store.capture(item)
        let model = makeModel(store)
        await model.reload()
        await model.togglePin(item)

        #expect(model.pins.map(\.id) == [item.id], "the pin rail never saw it")

        try await store.checkpoint()

        // A second store and model over the same file is what a relaunch looks like.
        let relaunched = makeModel(try makeStore(at: url, blobs: blobs))
        await relaunched.reload()
        #expect(relaunched.pins.map(\.id) == [item.id], "the pin did not survive a relaunch")
    }

    @Test("Unpinning reaches the disk too")
    func unpinReachesDisk() async throws {
        let url = temporaryURL("unpin-flow")
        let blobs = temporaryURL("unpin-flow-blobs")
        defer { try? FileManager.default.removeItem(at: url) }

        let item = ClipItem(payload: .text("pin me"), contentHash: ContentHash(.text("pin me")))
        let store = try makeStore(at: url, blobs: blobs)
        try await store.capture(item)
        let model = makeModel(store)
        await model.reload()

        await model.togglePin(item)
        let pinned = try #require(model.pins.first)
        await model.togglePin(pinned)
        #expect(model.pins.isEmpty)
    }
}

/// Opening the panel must not lose your place: the arrows carry on from whatever was
/// selected last, rather than snapping back to the newest clip.
@Suite("Selection across opens", .serialized)
@MainActor
struct SelectionContinuityTests {
    private func temporaryURL(_ suffix: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recall-\(suffix)-\(UUID().uuidString)")
    }

    private func makeStore() throws -> SQLiteHistoryStore {
        try SQLiteHistoryStore(
            url: nil,
            keyStore: EphemeralKeyStore(key: SymmetricKey(data: Data(repeating: 3, count: 32))),
            blobDirectory: nil
        )
    }

    private func fill(_ store: SQLiteHistoryStore, _ model: AppModel, _ texts: [String]) async throws {
        for text in texts {
            let item = ClipItem(payload: .text(text), contentHash: ContentHash(.text(text)))
            try await store.capture(item)
        }
        await model.reload()
    }

    @Test("A selection survives closing and reopening the panel")
    func selectionSurvivesReopen() async throws {
        let store = try makeStore()
        let model = AppModel(store: store, paste: PasteService(), settings: .default)
        try await fill(store, model, ["one", "two", "three"])

        let chosen = try #require(model.items.dropFirst().first)
        model.selection = chosen.id

        model.panelDidOpen()
        await model.reload()

        #expect(model.selection == chosen.id, "reopening snapped the selection back")
    }

    /// A clip copied while the panel was shut arrives at the top. It must not steal the
    /// selection from whatever the user had chosen.
    @Test("A new clip does not take the selection")
    func newClipDoesNotStealSelection() async throws {
        let store = try makeStore()
        let model = AppModel(store: store, paste: PasteService(), settings: .default)
        try await fill(store, model, ["one", "two"])

        let chosen = try #require(model.items.last)
        model.selection = chosen.id

        try await fill(store, model, ["arrived while closed"])
        #expect(model.selection == chosen.id)
    }

    /// The one case where moving it is right: the selected clip is no longer there.
    @Test("A deleted selection falls back to the newest clip")
    func deletedSelectionFallsBack() async throws {
        let store = try makeStore()
        let model = AppModel(store: store, paste: PasteService(), settings: .default)
        try await fill(store, model, ["one", "two"])

        let chosen = try #require(model.items.first)
        model.selection = chosen.id
        await model.delete(chosen)

        #expect(model.selection != nil)
        #expect(model.selection == model.items.first?.id)
    }
}
