import Foundation
import RecallCore

/// Disk-backed history, encrypted at rest.
///
/// Nothing that describes what was copied is readable on disk. The `ClipItem` is sealed
/// with AES-GCM under a key held in the Keychain; the search text and tags live in an
/// in-memory index rebuilt at launch; the dedup hash is a keyed blind index; and images
/// past a size threshold are sealed into the blob store rather than inlined.
///
/// What remains in the clear is what has to be queried without doing a full decrypt —
/// timestamps, kind, the pinned and sensitivity flags, snippet shortcodes. See
/// `docs/adr/0004-encryption-at-rest.md` for why that floor is where it is.
public actor SQLiteHistoryStore: HistoryStore, TodoStore {
    /// Images larger than this are offloaded to the blob store.
    public static let imageInlineByteLimit = 512 * 1024

    private let database: SQLiteDatabase
    private let databaseURL: URL?
    private let blobDirectory: URL
    private let sealer: Sealer
    private let blobs: BlobStore
    private let index: SearchIndex
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// The default location for the history database.
    public static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        try directoryURL(fileManager: fileManager).appendingPathComponent("history.sqlite")
    }

    static func directoryURL(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let directory = support.appendingPathComponent("Recall", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        return directory
    }

    /// - Parameters:
    ///   - url: `nil` opens a private temporary database (used by tests).
    ///   - keyStore: where the encryption key comes from. Tests pass an ephemeral one so
    ///     the suite never touches the real Keychain.
    ///   - blobDirectory: defaults to `Blobs/` beside the database.
    public init(
        url: URL?,
        keyStore: any KeyStoring = KeychainKeyStore(),
        blobDirectory: URL? = nil
    ) throws {
        let database = try SQLiteDatabase(path: url?.path)
        try Schema.migrate(database)

        let sealer = try Sealer(keyStore: keyStore)
        let index = try SearchIndex()
        let blobDirectory = try blobDirectory ?? Self.defaultBlobDirectory(for: url)
        let blobs = try BlobStore(directory: blobDirectory, sealer: sealer)

        // Built before the actor exists, from locals, so the store is never observable in
        // a state where the index does not match the database.
        try Self.rebuildIndex(database: database, sealer: sealer, index: index, blobs: blobs)

        self.database = database
        self.databaseURL = url
        self.blobDirectory = blobDirectory
        self.sealer = sealer
        self.index = index
        self.blobs = blobs
    }

    private static func defaultBlobDirectory(for url: URL?) throws -> URL {
        guard let url else {
            // A temporary database gets a temporary blob directory of its own.
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("recall-blobs-\(UUID().uuidString)", isDirectory: true)
        }
        return url.deletingLastPathComponent().appendingPathComponent("Blobs", isDirectory: true)
    }

    /// Decrypts every row to rebuild the in-memory index, and sweeps blobs no row points
    /// at any more — the one place that catches a crash between deleting a row and
    /// deleting its file.
    private static func rebuildIndex(
        database: SQLiteDatabase,
        sealer: Sealer,
        index: SearchIndex,
        blobs: BlobStore
    ) throws {
        try index.removeAll()
        var liveBlobs: Set<String> = []

        let decoder = JSONDecoder()
        let items = try database.query("SELECT body FROM items;") { row in
            try decoder.decode(ClipItem.self, from: try sealer.open(row.data(0)))
        }

        for item in items {
            try index.index(id: item.id, text: item.indexableText, tags: item.tags, app: item.source)
            if case .image(let image) = item.payload, let blobID = image.blobID {
                liveBlobs.insert(sealer.blindIndex(blobID))
            }
        }

        let orphans = try blobs.removeOrphans(keeping: liveBlobs)
        if orphans > 0 {
            Log.storage.info("Removed \(orphans, privacy: .public) orphaned blob(s)")
        }
    }

    @discardableResult
    public func capture(_ item: ClipItem) throws -> CaptureOutcome {
        if var existing = try itemByHash(item.contentHash) {
            existing.lastUsedAt = item.createdAt
            existing.useCount += 1
            existing.expiresAt = item.expiresAt
            existing.source = item.source ?? existing.source
            try write(existing)
            return .promoted(existing)
        }
        try write(item)
        return .inserted(item)
    }

    public func items(matching query: HistoryQuery) throws -> [ClipItem] {
        var sql = "SELECT body FROM items"
        var bindings: [SQLiteValue] = []
        var conditions: [String] = []

        // Text and tag matching happen in the in-memory index, because the disk holds
        // neither the words nor the tags. The result narrows the SQL to a set of ids.
        if let candidates = try candidateIDs(for: query) {
            guard !candidates.isEmpty else { return [] }
            let placeholders = candidates.map { _ in "?" }.joined(separator: ", ")
            conditions.append("id IN (\(placeholders))")
            bindings.append(contentsOf: candidates.map { .text($0.uuidString) })
        }

        if query.pinnedOnly {
            conditions.append("pinned = 1")
        }
        if let since = query.since {
            conditions.append("created_at >= ?")
            bindings.append(.date(since))
        }
        if let kinds = query.kinds, !kinds.isEmpty {
            let placeholders = kinds.map { _ in "?" }.joined(separator: ", ")
            conditions.append("kind IN (\(placeholders))")
            bindings.append(contentsOf: kinds.map { .text($0.rawValue) })
        }

        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        // Pinned items hold their user-assigned position; everything else is by recency.
        sql += " ORDER BY pinned DESC, COALESCE(pin_order, 9223372036854775807) ASC, last_used_at DESC LIMIT ? OFFSET ?"
        bindings.append(.integer(Int64(query.limit)))
        bindings.append(.integer(Int64(query.offset)))

        // Rows are returned unhydrated: a list renders from thumbnails, and reading every
        // full-size screenshot off the disk to draw a 28-point icon would be absurd.
        return try database.query(sql, bindings) { try decode($0.data(0)) }
    }

    /// `nil` means "no text or tag filter", which is different from "matched nothing".
    private func candidateIDs(for query: HistoryQuery) throws -> Set<UUID>? {
        let text = query.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !(text ?? "").isEmpty
        guard hasText || !query.tags.isEmpty || query.sourceApp != nil else { return nil }

        var candidates: Set<UUID>?

        if hasText, let text {
            candidates = Set(try index.search(text, limit: max(query.limit + query.offset, 200)))
        }
        if !query.tags.isEmpty {
            let tagged = try index.items(taggedAnyOf: query.tags)
            candidates = candidates.map { $0.intersection(tagged) } ?? tagged
        }
        if let app = query.sourceApp {
            let fromApp = try index.items(fromApp: app)
            candidates = candidates.map { $0.intersection(fromApp) } ?? fromApp
        }
        return candidates ?? []
    }

    public func snippets() throws -> [ClipItem] {
        try database.query("SELECT body FROM items WHERE snippet_code IS NOT NULL;") {
            try decode($0.data(0))
        }
    }

    /// Returns the item with its full payload loaded — use this on the paste path.
    public func item(id: UUID) throws -> ClipItem? {
        guard let item = try storedItem(id: id) else { return nil }
        return try hydrate(item)
    }

    public func markUsed(id: UUID, at date: Date) throws {
        guard var item = try storedItem(id: id) else { return }
        item.lastUsedAt = date
        item.useCount += 1
        try write(item)
    }

    public func setPinned(_ pinned: Bool, id: UUID) throws {
        guard var item = try storedItem(id: id) else {
            // Was a bare `return`. A pin that silently does nothing because the row could
            // not be read is indistinguishable from a pin that worked.
            Log.storage.error("Cannot pin \(id, privacy: .public): no such row")
            return
        }
        item.isPinned = pinned
        // A new pin goes to the end of the pinned group; unpinning drops the ordinal.
        item.pinOrder = pinned ? try nextPinOrder() : nil
        try write(item)
    }

    public func reorderPins(_ ids: [UUID]) throws {
        try database.transaction {
            for (position, id) in ids.enumerated() {
                guard var item = try storedItem(id: id), item.isPinned else { continue }
                item.pinOrder = (position + 1) * PinOrder.spacing
                try write(item)
            }
        }
    }

    /// Sparse ordinals, so moving one pin rewrites one row rather than all of them.
    private func nextPinOrder() throws -> Int {
        let highest = try database.query(
            "SELECT COALESCE(MAX(pin_order), 0) FROM items WHERE pinned = 1;"
        ) { Int($0.int(0)) }.first ?? 0
        return highest + PinOrder.spacing
    }

    public func update(_ item: ClipItem) throws {
        try write(item)
    }

    public func applyEnrichment(_ enrichment: ClipEnrichment, to id: UUID) throws {
        guard !enrichment.isEmpty else { return }
        guard let item = try storedItem(id: id) else {
            // The clip was deleted or expired while the pass was working, which is
            // ordinary rather than exceptional.
            return
        }
        try write(enrichment.applied(to: item))
    }

    public func delete(id: UUID) throws {
        try deleteRows(ids: [id])
    }

    public func deleteAll() throws {
        try database.transaction {
            try database.execute("DELETE FROM items;")
        }
        try index.removeAll()
        try blobs.deleteAll()
    }

    @discardableResult
    public func purgeExpired(asOf date: Date) throws -> Int {
        // Pinned items are exempt from every automatic deletion path, this one included.
        let doomed = try ids(
            where: "pinned = 0 AND expires_at IS NOT NULL AND expires_at <= ?",
            bindings: [.date(date)]
        )
        try deleteRows(ids: doomed)
        return doomed.count
    }

    @discardableResult
    public func enforceRetention(limit: Int, olderThan cutoff: Date?) throws -> Int {
        var doomed: Set<UUID> = []

        if let cutoff {
            doomed.formUnion(try ids(where: "pinned = 0 AND created_at < ?", bindings: [.date(cutoff)]))
        }
        doomed.formUnion(try ids(
            where: """
            pinned = 0 AND id NOT IN (
                SELECT id FROM items WHERE pinned = 0 ORDER BY last_used_at DESC LIMIT ?
            )
            """,
            bindings: [.integer(Int64(limit))]
        ))

        try deleteRows(ids: Array(doomed))
        return doomed.count
    }

    /// Size of the database, its write-ahead log, and the blob store.
    public var footprint: Int64 {
        get throws {
            var total: Int64 = 0
            for url in [databaseURL, blobDirectory].compactMap({ $0 }) {
                total += Self.size(of: url)
            }
            return total
        }
    }

    /// Recursive byte count; a missing path contributes nothing rather than failing.
    private static func size(of url: URL) -> Int64 {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }

        if isDirectory.boolValue {
            let contents = (try? manager.contentsOfDirectory(atPath: url.path)) ?? []
            return contents.reduce(0) { $0 + size(of: url.appendingPathComponent($1)) }
        }

        // The write-ahead log and shared-memory files sit beside the database and count.
        let siblings = [url, url.appendingPathExtension("wal"), url.appendingPathExtension("shm")]
        return siblings.reduce(0) { total, candidate in
            let attributes = try? manager.attributesOfItem(atPath: candidate.path)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// Flushes the write-ahead log into the database file.
    ///
    /// Only needed by tests that inspect the raw bytes on disk — in normal use SQLite
    /// checkpoints on its own.
    public func checkpoint() throws {
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    public var count: Int {
        get throws {
            try database.query("SELECT COUNT(*) FROM items;") { Int($0.int(0)) }.first ?? 0
        }
    }

    // MARK: - Embeddings

    /// Stores (or replaces) the embedding for an item.
    ///
    /// Vectors are sealed like everything else: an embedding is a lossy but very real
    /// encoding of the text it came from, and leaving them in the clear beside an
    /// encrypted database would undo much of the point.
    public func setEmbedding(_ vector: [Float], model: String, itemID: UUID, at date: Date = .now) throws {
        let plain = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        try database.run(
            """
            INSERT INTO embeddings (item_id, model, dimensions, vector, created_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(item_id) DO UPDATE SET
                model = excluded.model, dimensions = excluded.dimensions,
                vector = excluded.vector, created_at = excluded.created_at;
            """,
            [
                .text(itemID.uuidString), .text(model), .integer(Int64(vector.count)),
                .blob(try sealer.seal(plain)), .date(date),
            ]
        )
    }

    /// All stored embeddings for a model, for brute-force nearest-neighbour search.
    public func embeddings(model: String) throws -> [(itemID: UUID, vector: [Float])] {
        try database.query(
            "SELECT item_id, vector FROM embeddings WHERE model = ?;",
            [.text(model)]
        ) { row in
            let id = UUID(uuidString: row.string(0) ?? "") ?? UUID()
            let data = try sealer.open(row.data(1))
            let vector = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return (id, vector)
        }
    }

    /// Drops vectors produced by any other model. Coordinates from two models are not
    /// comparable, so keeping both would silently corrupt ranking.
    @discardableResult
    public func deleteEmbeddings(exceptModel model: String) throws -> Int {
        try database.run("DELETE FROM embeddings WHERE model != ?;", [.text(model)])
        return database.changes
    }

    /// How many items still need a vector for `model`.
    public func pendingEmbeddingCount(model: String) throws -> Int {
        try database.query(
            "SELECT COUNT(*) FROM items WHERE id NOT IN (SELECT item_id FROM embeddings WHERE model = ?);",
            [.text(model)]
        ) { Int($0.int(0)) }.first ?? 0
    }

    public func itemsWithoutEmbeddings(model: String, limit: Int) throws -> [ClipItem] {
        try database.query(
            """
            SELECT body FROM items
            WHERE id NOT IN (SELECT item_id FROM embeddings WHERE model = ?)
            ORDER BY last_used_at DESC LIMIT ?;
            """,
            [.text(model), .integer(Int64(limit))]
        ) { try decode($0.data(0)) }
            .filter { !$0.indexableText.isEmpty }
    }

    // MARK: - Todos

    /// Todos are not history: clearing history, retention and expiry never touch them.
    /// A todo is something the user wrote down on purpose, like a pin.
    public func todos() throws -> [TodoItem] {
        try allTodos().sorted(by: TodoItem.displayOrder)
    }

    public func saveTodo(_ todo: TodoItem) throws {
        try writeTodo(todo)
    }

    public func reorderTodos(_ ids: [UUID]) throws {
        let byID = Dictionary(uniqueKeysWithValues: try allTodos().map { ($0.id, $0) })
        try database.transaction {
            for (position, id) in ids.enumerated() {
                guard var todo = byID[id], !todo.isDone else { continue }
                todo.order = (position + 1) * TodoItem.orderSpacing
                try writeTodo(todo)
            }
        }
    }

    public func deleteTodo(id: UUID) throws {
        try database.run("DELETE FROM todos WHERE id = ?;", [.text(id.uuidString)])
    }

    @discardableResult
    public func deleteCompletedTodos() throws -> Int {
        let done = try allTodos().filter(\.isDone)
        try database.transaction {
            for todo in done {
                try database.run("DELETE FROM todos WHERE id = ?;", [.text(todo.id.uuidString)])
            }
        }
        return done.count
    }

    // MARK: - Private

    private func allTodos() throws -> [TodoItem] {
        try database.query("SELECT body FROM todos;") { row in
            try decoder.decode(TodoItem.self, from: try sealer.open(row.data(0)))
        }
    }

    private func writeTodo(_ todo: TodoItem) throws {
        try database.run(
            """
            INSERT INTO todos (id, body) VALUES (?, ?)
            ON CONFLICT(id) DO UPDATE SET body = excluded.body;
            """,
            [.text(todo.id.uuidString), .blob(try sealer.seal(try encoder.encode(todo)))]
        )
    }

    private func allItems() throws -> [ClipItem] {
        try database.query("SELECT body FROM items;") { try decode($0.data(0)) }
    }

    private func storedItem(id: UUID) throws -> ClipItem? {
        try database.query("SELECT body FROM items WHERE id = ?;", [.text(id.uuidString)]) {
            try decode($0.data(0))
        }.first
    }

    private func itemByHash(_ hash: ContentHash) throws -> ClipItem? {
        try database.query(
            "SELECT body FROM items WHERE content_hash = ?;",
            [.text(sealer.blindIndex(hash.value))]
        ) { try decode($0.data(0)) }.first
    }

    private func ids(where condition: String, bindings: [SQLiteValue]) throws -> [UUID] {
        try database.query("SELECT id FROM items WHERE \(condition);", bindings) {
            UUID(uuidString: $0.string(0) ?? "")
        }.compactMap { $0 }
    }

    private func deleteRows(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }

        // Read the rows first: once they are gone we no longer know which blobs they
        // owned, and an orphaned blob is an encrypted screenshot nothing will ever clean
        // up except the sweep at next launch.
        let doomedBlobs = try ids.compactMap { id -> String? in
            guard let item = try storedItem(id: id), case .image(let image) = item.payload else { return nil }
            return image.blobID.map(blobFileName(for:))
        }

        try database.transaction {
            for id in ids {
                try database.run("DELETE FROM items WHERE id = ?;", [.text(id.uuidString)])
            }
        }
        for id in ids {
            try index.remove(id: id)
        }
        for blob in doomedBlobs {
            try blobs.delete(blob)
        }
    }

    /// Writes an item, offloading a large image first, and keeps the in-memory index in
    /// step. The index is updated from the *pre-offload* item, so search still sees the
    /// OCR text of an image whose bytes now live in a file.
    private func write(_ item: ClipItem) throws {
        let stored = try offloadingLargePayload(item)
        let body = try sealer.seal(try encoder.encode(stored))

        try database.run(
            """
            INSERT INTO items (
                id, content_hash, kind, created_at, last_used_at, use_count, pinned,
                sensitivity, expires_at, snippet_code, pin_order, body
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                content_hash = excluded.content_hash, kind = excluded.kind,
                last_used_at = excluded.last_used_at, use_count = excluded.use_count,
                pinned = excluded.pinned, sensitivity = excluded.sensitivity,
                expires_at = excluded.expires_at, snippet_code = excluded.snippet_code,
                pin_order = excluded.pin_order, body = excluded.body;
            """,
            [
                .text(stored.id.uuidString),
                .text(sealer.blindIndex(stored.contentHash.value)),
                .text(stored.kind.rawValue),
                .date(stored.createdAt),
                .date(stored.lastUsedAt),
                .integer(Int64(stored.useCount)),
                .bool(stored.isPinned),
                .text(stored.sensitivity.rawValue),
                .date(stored.expiresAt),
                .text(stored.snippetCode),
                stored.pinOrder.map { SQLiteValue.integer(Int64($0)) } ?? .null,
                .blob(body),
            ]
        )

        try index.index(id: stored.id, text: stored.indexableText, tags: stored.tags, app: stored.source)
    }

    /// Moves an oversized image into the blob store, returning the item to persist.
    private func offloadingLargePayload(_ item: ClipItem) throws -> ClipItem {
        guard case .image(let image) = item.payload,
              !image.isOffloaded,
              image.data.count > Self.imageInlineByteLimit
        else { return item }

        let digest = ContentHash.digest(of: image)
        _ = try blobs.store(image.data, named: blobFileName(for: digest))

        var offloaded = item
        offloaded.payload = .image(image.offloaded(blobID: digest))
        return offloaded
    }

    /// Reads an offloaded image back in.
    private func hydrate(_ item: ClipItem) throws -> ClipItem {
        guard case .image(let image) = item.payload, image.isOffloaded, let blobID = image.blobID else {
            return item
        }
        var hydrated = item
        hydrated.payload = .image(image.hydrated(with: try blobs.load(blobFileName(for: blobID))))
        return hydrated
    }

    /// Blobs are named by a keyed digest, not by the content hash itself: a directory of
    /// files named after the SHA-256 of their plaintext would let anyone confirm which
    /// images you had copied without decrypting a single byte.
    private func blobFileName(for digest: String) -> String {
        sealer.blindIndex(digest)
    }

    private func decode(_ data: Data) throws -> ClipItem {
        try decoder.decode(ClipItem.self, from: try sealer.open(data))
    }
}
