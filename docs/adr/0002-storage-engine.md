# ADR 0002 — SQLite via the system library, no ORM

**Status:** accepted

## Context

History needs full-text search, ordered queries over thousands of rows, vector storage,
and an in-memory mode with identical behaviour. The obvious candidates were SwiftData,
GRDB, and raw `libsqlite3`.

## Decision

Talk to the system `libsqlite3` through a ~200-line wrapper.

- **SwiftData** gives no FTS5 and no control over the on-disk format, which matters
  because encryption at rest is coming.
- **GRDB** is excellent and would have been the choice in most projects. It is rejected
  here for one reason: it puts third-party code in the process that handles every
  password the user copies. The surface we need is small enough that the trade is worth
  making, and it keeps the build fully offline with zero resolved dependencies.

Items are stored as JSON in a `body` column alongside denormalized, indexed columns for
anything queried. FTS5 is maintained by triggers.

## Consequences

- We own the SQL, the migrations, and any bugs in the wrapper.
- No compile-time query checking; the store's tests carry that weight instead.
- Encryption at rest stays open: SQLCipher can be dropped in under the same wrapper, or
  payloads can be sealed individually with `CryptoKit`.
