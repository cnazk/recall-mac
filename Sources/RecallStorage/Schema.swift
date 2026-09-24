import Foundation

/// Schema migrations, applied in order and tracked with `PRAGMA user_version`.
///
/// Every migration is append-only: once a version ships, its SQL is frozen.
enum Schema {
    static let migrations: [String] = [
        // v1 — items plus an on-disk full-text index.
        """
        CREATE TABLE items (
            id TEXT PRIMARY KEY NOT NULL,
            content_hash TEXT NOT NULL UNIQUE,
            kind TEXT NOT NULL,
            created_at REAL NOT NULL,
            last_used_at REAL NOT NULL,
            use_count INTEGER NOT NULL DEFAULT 0,
            pinned INTEGER NOT NULL DEFAULT 0,
            sensitivity TEXT NOT NULL,
            expires_at REAL,
            snippet_code TEXT UNIQUE,
            source_bundle_id TEXT,
            tags TEXT NOT NULL DEFAULT '',
            indexable_text TEXT NOT NULL DEFAULT '',
            body BLOB NOT NULL
        );

        CREATE INDEX items_recency ON items (pinned DESC, last_used_at DESC);
        CREATE INDEX items_kind ON items (kind);
        CREATE INDEX items_expiry ON items (expires_at) WHERE expires_at IS NOT NULL;

        CREATE VIRTUAL TABLE items_fts USING fts5(
            indexable_text,
            content='items',
            content_rowid='rowid',
            tokenize='unicode61 remove_diacritics 2'
        );

        CREATE TRIGGER items_fts_insert AFTER INSERT ON items BEGIN
            INSERT INTO items_fts(rowid, indexable_text) VALUES (new.rowid, new.indexable_text);
        END;

        CREATE TRIGGER items_fts_delete AFTER DELETE ON items BEGIN
            INSERT INTO items_fts(items_fts, rowid, indexable_text) VALUES ('delete', old.rowid, old.indexable_text);
        END;

        CREATE TRIGGER items_fts_update AFTER UPDATE ON items BEGIN
            INSERT INTO items_fts(items_fts, rowid, indexable_text) VALUES ('delete', old.rowid, old.indexable_text);
            INSERT INTO items_fts(rowid, indexable_text) VALUES (new.rowid, new.indexable_text);
        END;

        CREATE TABLE embeddings (
            item_id TEXT PRIMARY KEY NOT NULL REFERENCES items(id) ON DELETE CASCADE,
            model TEXT NOT NULL,
            dimensions INTEGER NOT NULL,
            vector BLOB NOT NULL,
            created_at REAL NOT NULL
        );
        """,

        // v2 — encryption at rest.
        //
        // Everything that describes *what was copied* leaves the disk in the clear:
        // the body is sealed, the search text and tags move to an in-memory index, and
        // the dedup hash becomes a keyed blind index so that holding the file no longer
        // lets you confirm "did they copy this exact string?".
        //
        // What stays readable is what has to be queried without a key: timestamps, the
        // kind, the pinned and sensitivity flags, and the user's own snippet shortcodes.
        // That is a deliberate, documented floor — see docs/adr/0004-encryption-at-rest.md.
        //
        // v1 never shipped, so this drops the old table rather than carrying a re-seal
        // pass for rows that cannot exist. A shipped v1 would have required the opposite.
        """
        DROP TRIGGER IF EXISTS items_fts_insert;
        DROP TRIGGER IF EXISTS items_fts_delete;
        DROP TRIGGER IF EXISTS items_fts_update;
        DROP TABLE IF EXISTS items_fts;
        DROP TABLE IF EXISTS embeddings;
        DROP TABLE IF EXISTS items;

        CREATE TABLE items (
            id TEXT PRIMARY KEY NOT NULL,
            content_hash TEXT NOT NULL UNIQUE,
            kind TEXT NOT NULL,
            created_at REAL NOT NULL,
            last_used_at REAL NOT NULL,
            use_count INTEGER NOT NULL DEFAULT 0,
            pinned INTEGER NOT NULL DEFAULT 0,
            sensitivity TEXT NOT NULL,
            expires_at REAL,
            snippet_code TEXT UNIQUE,
            body BLOB NOT NULL
        );

        CREATE INDEX items_recency ON items (pinned DESC, last_used_at DESC);
        CREATE INDEX items_kind ON items (kind);
        CREATE INDEX items_expiry ON items (expires_at) WHERE expires_at IS NOT NULL;

        CREATE TABLE embeddings (
            item_id TEXT PRIMARY KEY NOT NULL REFERENCES items(id) ON DELETE CASCADE,
            model TEXT NOT NULL,
            dimensions INTEGER NOT NULL,
            vector BLOB NOT NULL,
            created_at REAL NOT NULL
        );
        """,

        // v3 — user-defined pin order. Pins keep the place the user put them in rather
        // than reshuffling by recency, so the ordinal has to be queryable and therefore
        // stays in the clear. It says nothing about content.
        """
        ALTER TABLE items ADD COLUMN pin_order INTEGER;
        CREATE INDEX items_pin_order ON items (pin_order) WHERE pin_order IS NOT NULL;
        """,

        // v4 — todos. Nothing but the id is in the clear: the list is small enough to
        // decrypt whole and sort in memory, so no column has to be queryable, and not
        // even when a todo was made or finished leaves the disk readable.
        """
        CREATE TABLE todos (
            id TEXT PRIMARY KEY NOT NULL,
            body BLOB NOT NULL
        );
        """,
    ]

    /// Brings `database` up to the latest version.
    static func migrate(_ database: SQLiteDatabase) throws {
        let current = try database.query("PRAGMA user_version;") { Int($0.int(0)) }.first ?? 0
        guard current < migrations.count else { return }

        for version in current..<migrations.count {
            try database.transaction {
                try database.execute(migrations[version])
                try database.execute("PRAGMA user_version = \(version + 1);")
            }
        }
    }
}
