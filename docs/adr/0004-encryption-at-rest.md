# ADR 0004 — Encryption at rest with CryptoKit, not SQLCipher

**Status:** accepted

## Context

A month of clipboard history is one of the most sensitive files on a Mac. It has to be
unreadable to anything but Recall holding the Keychain key. Two options:

- **SQLCipher** encrypts the whole database file. FTS5 keeps working unchanged, because
  SQLite sees plaintext and the encryption happens at the page layer. The cost is a
  third-party C dependency compiled into the process that handles every password the user
  copies — precisely what ADR 0002 declined to do.
- **CryptoKit** sealing of each row's body, with a 256-bit key in the Keychain. No
  dependency, hardware-accelerated AES-GCM, and every row authenticated. The cost is that
  SQLite can no longer see the text, so FTS5 cannot index it.

## Decision

CryptoKit, and move the full-text index into memory.

- The whole `ClipItem` is JSON-encoded and sealed with AES-GCM into the `body` column.
- The search index is an in-memory SQLite/FTS5 database, rebuilt from decrypted rows at
  launch. It never touches the disk and dies with the process.
- Tags live beside it in the same in-memory database, for the same reason: a tag is a
  statement about content.
- The dedup hash is stored as a **blind index** — HMAC-SHA256 of the content hash under
  the same key. Equal content still compares equal, but holding the file no longer lets
  anyone confirm "did they copy *this* exact string?".
- Embeddings are sealed too. A vector is a lossy but real encoding of its text.
- Blobs are sealed with the same key, and their file names are a keyed digest, so the
  directory listing does not reveal which images were copied.
- The key is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and not synchronizable:
  it never reaches iCloud Keychain or an encrypted backup.

## The plaintext floor

These columns stay readable, because they are what queries need without a key:

`id`, `kind`, `created_at`, `last_used_at`, `use_count`, `pinned`, `sensitivity`,
`expires_at`, `snippet_code`, and the embeddings table's `model` and `dimensions`.

The todos table adds nothing to this list: it holds an `id` and a sealed body. A todo
list is small enough to decrypt whole and sort in memory, so no column has to be
queryable, and not even when a todo was written or finished is readable on disk.

So an attacker with the file learns *that* you copied 4,000 things, when, how often you
reused them, which were images, and which shortcodes you defined — but not a single word
of what any of it said. That trade is deliberate and is the line to defend: anything that
describes content goes behind the key.

## Consequences

- Launch decrypts every row to rebuild the index. Milliseconds at the default 5,000-item
  history; if it ever stops being milliseconds the answer is a smaller resident window,
  never a plaintext index on disk.
- Losing the Keychain key makes history permanently unreadable. That is also the feature:
  `KeychainKeyStore.destroy()` is how "erase everything irrecoverably" is implemented.
- Tests never touch the real Keychain — `KeyStoring` is injected, and the suite uses
  `EphemeralKeyStore`.
- A future move to SQLCipher remains possible under the same wrapper, but would only be
  worth it if the in-memory index becomes the bottleneck.
