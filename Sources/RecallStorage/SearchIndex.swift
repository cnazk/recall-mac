import Foundation
import RecallCore

/// The full-text index, held in RAM.
///
/// FTS5 cannot index ciphertext, and an on-disk index of the plaintext would hand away
/// exactly what the encryption is there to protect — the words you copied. So the index
/// lives in a private in-memory database, built from decrypted rows at launch and
/// maintained as items come and go. It never touches the disk, and it dies with the
/// process.
///
/// Cost: a rebuild at every launch, which is milliseconds for the default 5,000-item
/// history. If that ever stops being true, the answer is a smaller resident window, not
/// a plaintext file.
final class SearchIndex {
    private let database: SQLiteDatabase

    init() throws {
        self.database = try SQLiteDatabase(path: nil)
        try database.execute(
            """
            CREATE VIRTUAL TABLE items_fts USING fts5(
                item_id UNINDEXED,
                text,
                tokenize='unicode61 remove_diacritics 2'
            );

            -- Tags are AI-derived labels for content, so they are no more allowed on
            -- disk than the content is. They live here beside the text index.
            CREATE TABLE item_tags (
                item_id TEXT NOT NULL,
                tag TEXT NOT NULL,
                PRIMARY KEY (item_id, tag)
            );

            -- Which app a clip came from is a statement about the user, so it is not on
            -- disk either; `app:` searches resolve here.
            CREATE TABLE item_apps (
                item_id TEXT PRIMARY KEY NOT NULL,
                app TEXT NOT NULL
            );
            """
        )
    }

    func index(id: UUID, text: String, tags: Set<String>, app: SourceApp? = nil) throws {
        try remove(id: id)
        if !text.isEmpty {
            // Indexed folded, and queried folded in `ftsQuery`. See ``SearchText``: the
            // index is a comparison surface, not a copy of the clip, so it is free to
            // hold a spelling nobody typed.
            try database.run(
                "INSERT INTO items_fts (item_id, text) VALUES (?, ?);",
                [.text(id.uuidString), .text(SearchText.normalized(text))]
            )
        }
        for tag in tags {
            try database.run(
                "INSERT OR IGNORE INTO item_tags (item_id, tag) VALUES (?, ?);",
                [.text(id.uuidString), .text(tag)]
            )
        }
        if let app {
            let label = [app.localizedName, app.bundleIdentifier].compactMap { $0 }.joined(separator: "\u{1F}")
            try database.run(
                "INSERT OR REPLACE INTO item_apps (item_id, app) VALUES (?, ?);",
                [.text(id.uuidString), .text(label.lowercased())]
            )
        }
    }

    func remove(id: UUID) throws {
        try database.run("DELETE FROM items_fts WHERE item_id = ?;", [.text(id.uuidString)])
        try database.run("DELETE FROM item_tags WHERE item_id = ?;", [.text(id.uuidString)])
        try database.run("DELETE FROM item_apps WHERE item_id = ?;", [.text(id.uuidString)])
    }

    func removeAll() throws {
        try database.execute("DELETE FROM items_fts;")
        try database.execute("DELETE FROM item_tags;")
        try database.execute("DELETE FROM item_apps;")
    }

    /// Item ids whose source app name or bundle id contains `name`.
    func items(fromApp name: String) throws -> Set<UUID> {
        let ids = try database.query(
            "SELECT item_id FROM item_apps WHERE app LIKE ?;",
            [.text("%\(name.lowercased())%")]
        ) { UUID(uuidString: $0.string(0) ?? "") }
        return Set(ids.compactMap { $0 })
    }

    /// Item ids carrying any of `tags`.
    func items(taggedAnyOf tags: Set<String>) throws -> Set<UUID> {
        guard !tags.isEmpty else { return [] }
        let placeholders = tags.map { _ in "?" }.joined(separator: ", ")
        let ids = try database.query(
            "SELECT DISTINCT item_id FROM item_tags WHERE tag IN (\(placeholders));",
            tags.sorted().map { .text($0) }
        ) { UUID(uuidString: $0.string(0) ?? "") }
        return Set(ids.compactMap { $0 })
    }

    /// Item ids matching the query, best match first.
    func search(_ text: String, limit: Int) throws -> [UUID] {
        let query = Self.ftsQuery(for: text)
        guard !query.isEmpty else { return [] }
        return try database.query(
            """
            SELECT item_id FROM items_fts
            WHERE items_fts MATCH ?
            ORDER BY rank
            LIMIT ?;
            """,
            [.text(query), .integer(Int64(limit))]
        ) { row in
            UUID(uuidString: row.string(0) ?? "")
        }.compactMap { $0 }
    }

    /// Turns user input into a prefix FTS5 query, quoting each token so punctuation in a
    /// search string cannot be read as FTS syntax.
    ///
    /// Folded first, and it has to be the same fold the text was indexed with, or Persian
    /// typed on a Persian keyboard will not find Persian read out of an image.
    static func ftsQuery(for text: String) -> String {
        SearchText.normalized(text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { "\"\($0)\"*" }
            .joined(separator: " AND ")
    }
}
