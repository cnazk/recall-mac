import CryptoKit
import Foundation
import Testing
@testable import RecallCore
@testable import RecallStorage

private let keyA = SymmetricKey(data: Data(repeating: 1, count: 32))
private let keyB = SymmetricKey(data: Data(repeating: 2, count: 32))

private func temporaryURL(_ suffix: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("recall-\(suffix)-\(UUID().uuidString)")
}

@Suite("Sealing")
struct SealerTests {
    @Test("Sealed data round-trips")
    func roundTrips() throws {
        let sealer = Sealer(key: keyA)
        let plaintext = Data("border-radius: 8px".utf8)
        #expect(try sealer.open(try sealer.seal(plaintext)) == plaintext)
    }

    @Test("Ciphertext does not contain the plaintext")
    func hidesPlaintext() throws {
        let sealed = try Sealer(key: keyA).seal(Data("hunter2".utf8))
        #expect(sealed.range(of: Data("hunter2".utf8)) == nil)
    }

    @Test("Sealing twice produces different ciphertext")
    func nonceIsFresh() throws {
        let sealer = Sealer(key: keyA)
        let plaintext = Data("same input".utf8)
        #expect(try sealer.seal(plaintext) != sealer.seal(plaintext))
    }

    @Test("Another key cannot open it")
    func rejectsWrongKey() throws {
        let sealed = try Sealer(key: keyA).seal(Data("secret".utf8))
        #expect(throws: Sealer.Failure.self) {
            try Sealer(key: keyB).open(sealed)
        }
    }

    @Test("Tampered ciphertext is rejected rather than decrypted")
    func detectsTampering() throws {
        let sealer = Sealer(key: keyA)
        var sealed = try sealer.seal(Data("transfer $10".utf8))
        sealed[sealed.count - 1] ^= 0xFF
        #expect(throws: Sealer.Failure.self) {
            try sealer.open(sealed)
        }
    }

    @Test("The blind index is stable, keyed, and not the bare hash")
    func blindIndexProperties() {
        let a = Sealer(key: keyA)
        let b = Sealer(key: keyB)
        #expect(a.blindIndex("abc") == a.blindIndex("abc"))
        #expect(a.blindIndex("abc") != a.blindIndex("abd"))
        // Different keys must not produce the same index, or the key adds nothing.
        #expect(a.blindIndex("abc") != b.blindIndex("abc"))
    }
}

@Suite("Encryption at rest")
struct EncryptionAtRestTests {
    @Test("No copied text is readable in the database file")
    func databaseFileHasNoPlaintext() async throws {
        let url = temporaryURL("encrypted")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SQLiteHistoryStore(
            url: url,
            keyStore: EphemeralKeyStore(key: keyA),
            blobDirectory: temporaryURL("blobs")
        )

        let phrase = "correct-horse-battery-staple"
        var item = ClipItem(payload: .text(phrase), contentHash: ContentHash(.text(phrase)))
        item.tags = ["credentials"]
        item.summary = "a passphrase from a webcomic"
        try await store.capture(item)
        try await store.checkpoint()

        let raw = try Data(contentsOf: url)
        #expect(raw.range(of: Data(phrase.utf8)) == nil, "the clip text must not be on disk")
        #expect(raw.range(of: Data("credentials".utf8)) == nil, "tags must not be on disk")
        #expect(raw.range(of: Data("webcomic".utf8)) == nil, "the AI summary must not be on disk")
        // The bare content hash would let a holder of the file confirm a guessed string.
        #expect(raw.range(of: Data(item.contentHash.value.utf8)) == nil, "the dedup hash must be blinded")
    }

    @Test("A database cannot be read with the wrong key")
    func wrongKeyCannotRead() async throws {
        let url = temporaryURL("keyed")
        let blobs = temporaryURL("blobs")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SQLiteHistoryStore(url: url, keyStore: EphemeralKeyStore(key: keyA), blobDirectory: blobs)
        try await store.capture(ClipItem(payload: .text("private"), contentHash: ContentHash(.text("private"))))
        try await store.checkpoint()

        #expect(throws: (any Error).self) {
            _ = try SQLiteHistoryStore(url: url, keyStore: EphemeralKeyStore(key: keyB), blobDirectory: blobs)
        }
    }

    @Test("Embeddings are sealed too")
    func embeddingsAreSealed() async throws {
        let url = temporaryURL("vectors")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SQLiteHistoryStore(
            url: url, keyStore: EphemeralKeyStore(key: keyA), blobDirectory: temporaryURL("blobs")
        )
        let clip = ClipItem(payload: .text("vectorised"), contentHash: ContentHash(.text("vectorised")))
        try await store.capture(clip)

        let vector: [Float] = [0.25, 0.5, 0.75, 1.0]
        try await store.setEmbedding(vector, model: "test", itemID: clip.id)
        try await store.checkpoint()

        let raw = try Data(contentsOf: url)
        let rawVector = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        #expect(raw.range(of: rawVector) == nil, "vectors encode their text and must be sealed")

        // …and still round-trip through the key.
        let stored = try await store.embeddings(model: "test")
        #expect(stored.first?.vector == vector)
    }
}

@Suite("Blob offload")
struct BlobOffloadTests {
    /// Bigger than `imageInlineByteLimit`, and incompressible enough to stay that way.
    private func largeImage() -> ImagePayload {
        var bytes = Data(count: SQLiteHistoryStore.imageInlineByteLimit + 1_024)
        for index in bytes.indices { bytes[index] = UInt8(index % 251) }
        return ImagePayload(
            data: bytes,
            thumbnail: Data(repeating: 9, count: 512),
            uti: "public.png",
            pixelWidth: 2_048,
            pixelHeight: 1_536
        )
    }

    @Test("A large image is offloaded, and list rows carry only the thumbnail")
    func offloadsLargeImages() async throws {
        let blobs = temporaryURL("blobs")
        let store = try SQLiteHistoryStore(url: nil, keyStore: EphemeralKeyStore(key: keyA), blobDirectory: blobs)

        let image = largeImage()
        let item = ClipItem(payload: .image(image), contentHash: ContentHash(.image(image)))
        try await store.capture(item)

        let listed = try #require(try await store.items(matching: .recent).first)
        guard case .image(let listedImage) = listed.payload else { Issue.record("expected an image"); return }
        #expect(listedImage.isOffloaded)
        #expect(listedImage.data.isEmpty, "the list must not carry megabytes per row")
        #expect(listedImage.previewData?.count == 512, "the thumbnail keeps the row renderable")

        // The paste path hydrates.
        let hydrated = try #require(try await store.item(id: item.id))
        guard case .image(let full) = hydrated.payload else { Issue.record("expected an image"); return }
        #expect(full.data == image.data)
    }

    @Test("A small image stays inline")
    func keepsSmallImagesInline() async throws {
        let store = try SQLiteHistoryStore(
            url: nil, keyStore: EphemeralKeyStore(key: keyA), blobDirectory: temporaryURL("blobs")
        )
        let image = ImagePayload(data: Data(repeating: 3, count: 1_024), uti: "public.png", pixelWidth: 32, pixelHeight: 32)
        let item = ClipItem(payload: .image(image), contentHash: ContentHash(.image(image)))
        try await store.capture(item)

        let stored = try #require(try await store.items(matching: .recent).first)
        guard case .image(let storedImage) = stored.payload else { Issue.record("expected an image"); return }
        #expect(!storedImage.isOffloaded)
        #expect(storedImage.data.count == 1_024)
    }

    @Test("Blob files are encrypted and named without revealing their content hash")
    func blobsAreSealed() async throws {
        let blobs = temporaryURL("blobs")
        let store = try SQLiteHistoryStore(url: nil, keyStore: EphemeralKeyStore(key: keyA), blobDirectory: blobs)

        let image = largeImage()
        try await store.capture(ClipItem(payload: .image(image), contentHash: ContentHash(.image(image))))

        let files = try FileManager.default.contentsOfDirectory(atPath: blobs.path)
        #expect(files.count == 1)

        let plainDigest = ContentHash.digest(of: image)
        #expect(files[0].contains(plainDigest) == false, "file names must not be the plaintext digest")

        let onDisk = try Data(contentsOf: blobs.appendingPathComponent(files[0]))
        #expect(onDisk.range(of: image.data) == nil, "blob contents must be sealed")
    }

    @Test("Deleting an item deletes its blob")
    func deletingRemovesBlob() async throws {
        let blobs = temporaryURL("blobs")
        let store = try SQLiteHistoryStore(url: nil, keyStore: EphemeralKeyStore(key: keyA), blobDirectory: blobs)

        let image = largeImage()
        let item = ClipItem(payload: .image(image), contentHash: ContentHash(.image(image)))
        try await store.capture(item)
        #expect(try FileManager.default.contentsOfDirectory(atPath: blobs.path).count == 1)

        try await store.delete(id: item.id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: blobs.path).isEmpty)
    }

    @Test("Clearing history clears the blob store with it")
    func deleteAllRemovesBlobs() async throws {
        let blobs = temporaryURL("blobs")
        let store = try SQLiteHistoryStore(url: nil, keyStore: EphemeralKeyStore(key: keyA), blobDirectory: blobs)

        let image = largeImage()
        try await store.capture(ClipItem(payload: .image(image), contentHash: ContentHash(.image(image))))
        try await store.deleteAll()

        #expect(try FileManager.default.contentsOfDirectory(atPath: blobs.path).isEmpty)
    }
}

@Suite("Tag filtering")
struct TagFilterTests {
    @Test("Tags filter through the in-memory index")
    func filtersByTag() async throws {
        let store = try SQLiteHistoryStore(
            url: nil, keyStore: EphemeralKeyStore(key: keyA), blobDirectory: temporaryURL("blobs")
        )

        var code = ClipItem(payload: .text("let x = 1"), contentHash: ContentHash(.text("let x = 1")))
        code.tags = ["code"]
        var receipt = ClipItem(payload: .text("Total: $42"), contentHash: ContentHash(.text("Total: $42")))
        receipt.tags = ["receipts"]

        try await store.capture(code)
        try await store.capture(receipt)

        let tagged = try await store.items(matching: HistoryQuery(tags: ["code"]))
        #expect(tagged.count == 1)
        #expect(tagged.first?.id == code.id)

        #expect(try await store.items(matching: HistoryQuery(tags: ["emails"])).isEmpty)
    }
}
