import Foundation
import RecallCore

/// Content-addressed storage for payloads too big to sit in the database.
///
/// Screenshots are megabytes; inlining them bloats every query that touches the row and
/// makes the database slow in exactly the case where the user copies most often. Blobs
/// are sealed with the same key as the rest of the history — an encrypted database
/// beside a directory of plaintext screenshots would be pointless.
///
/// Addressing is content-derived, so two identical screenshots share one file, which
/// mirrors how deduplication works one level up. The caller supplies the name — the store
/// never sees the raw digest, because the file *names* are a keyed digest rather than the
/// plaintext hash (see ``SQLiteHistoryStore``).
struct BlobStore: Sendable {
    enum Failure: Error, CustomStringConvertible {
        case missing(String)

        var description: String {
            switch self {
            case .missing(let id): "blob \(id) is missing from the store"
            }
        }
    }

    private let directory: URL
    private let sealer: Sealer

    /// `FileManager.default` is used for the work itself; it is thread-safe for these
    /// operations and is not stored, which keeps this value `Sendable`.
    private var fileManager: FileManager { .default }

    init(directory: URL, sealer: Sealer) throws {
        self.directory = directory
        self.sealer = sealer
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
    }

    /// Writes `data` under `id`. Storing the same bytes twice is a no-op.
    @discardableResult
    func store(_ data: Data, named id: String) throws -> String {
        let url = url(for: id)
        guard !fileManager.fileExists(atPath: url.path) else { return id }
        try sealer.seal(data).write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return id
    }

    func load(_ id: String) throws -> Data {
        let url = url(for: id)
        guard fileManager.fileExists(atPath: url.path) else { throw Failure.missing(id) }
        return try sealer.open(try Data(contentsOf: url))
    }

    func delete(_ id: String) throws {
        let url = url(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func deleteAll() throws {
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Removes any blob no row still points at — belt and braces against a crash between
    /// deleting a row and deleting its file.
    @discardableResult
    func removeOrphans(keeping live: Set<String>) throws -> Int {
        var removed = 0
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] {
            let id = (name as NSString).deletingPathExtension
            guard !live.contains(id) else { continue }
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            removed += 1
        }
        return removed
    }

    private func url(for id: String) -> URL {
        directory.appendingPathComponent("\(id).blob")
    }
}
