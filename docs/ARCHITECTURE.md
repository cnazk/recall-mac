# Architecture

## Capture path (hot)

The only code that runs on every copy. Budget: well under a millisecond, no I/O.

1. `PasteboardMonitor` polls `NSPasteboard.general.changeCount` every 0.2s on a utility
   queue. macOS offers no change notification, so polling is the only option. Writes the
   app makes itself are recorded in `selfWrittenChangeCounts` and skipped, otherwise
   pasting would re-capture the thing just pasted.
2. `PasteboardReader` checks the concealed-type markers **before reading any bytes**,
   then reads the richest representations available and resolves the frontmost app.
   Attribution has to happen here — by the time the panel opens, the frontmost app is
   Recall.
3. `CaptureService` applies exclusions, normalizes text, classifies the payload, and runs
   secret detection against the *raw text* rather than the classified payload — a clip
   can classify as a colour and still be a one-time code (`483920` is both).
4. `HistoryStore.capture` hashes and either inserts or promotes.

## Enrichment path (cold)

Runs on a detached utility task, after the item is already visible:

link metadata → OCR → summary → auto-tags → embedding → `store.update` → UI reload.

Each step is independent and failure-tolerant: a dead link or an unavailable model costs
one field, not the item. Items marked `.secret` skip enrichment entirely — they are about
to be deleted, and running a model over a credential is exactly the wrong move.

## Storage

`HistoryStore` is an `actor` protocol with two implementations that the test suite
exercises identically, so In-Memory Mode can never silently diverge from the real thing.

The SQLite schema keeps queryable metadata in real columns and the whole `ClipItem` as
JSON in `body`, sealed with AES-GCM. New model fields need a migration only when they must
be *queried*, not merely stored. Embeddings live in a child table with `ON DELETE
CASCADE`, so deleting an item cannot leave its vector behind.

Because the disk holds ciphertext, FTS5 has nothing to index: the text index and the tag
map live in a separate in-memory database, rebuilt from decrypted rows at launch. A query
with text or tags resolves to a set of ids in memory first, then narrows the SQL.

Images over 512 KB are sealed into a content-addressed blob store beside the database and
replaced in the row by a thumbnail generated at capture. List queries return unhydrated
rows — `item(id:)` reads the full bytes back, which is the paste path.

Migrations are an append-only array indexed by `PRAGMA user_version`. Once a version
ships, its SQL is frozen.

## Search

Keyword and semantic results are merged rather than chosen between. Keyword hits enter at
~1.0 and decay by rank; semantic hits are scaled by 0.9 and floored at 0.35 cosine
similarity. The effect: an exact substring match always outranks a semantic one — typing
`border` and *not* getting the clip containing the word "border" would feel broken, however
good the semantic hit.

## Concurrency

Swift 6 language mode, strict concurrency, across every target.

- Stores and search are `actor`s.
- `AppModel` and `PasteService` are `@MainActor`.
- `PasteboardMonitor` is `@unchecked Sendable` and confines its state to a private queue.
- `NLEmbeddingProvider` is `@unchecked Sendable` behind a lock, because `NLEmbedding`
  is not `Sendable` and is never handed out.

## Startup

The store is opened off the main thread. Reading the encryption key can put a Keychain
dialog in front of the user, and doing that synchronously at launch wedges an agent app
that has no window to show it in — see the plan, §7.5. A watchdog surfaces what the app is
waiting for in the menu rather than leaving it looking broken.

## Security posture

| Control | Where |
| --- | --- |
| Password-manager exclusion list | `RecallSecurity/AppExclusionPolicy.swift` |
| `org.nspasteboard.ConcealedType` honoured before reading bytes | `RecallCapture/PasteboardReader.swift` |
| Secret detection before persistence | `RecallCapture/CaptureService.swift` |
| 60-second expiry, swept on a timer and at launch | `RecallStorage/ExpiryReaper.swift` |
| In-Memory Mode | `RecallStorage/InMemoryHistoryStore.swift` |
| No clipboard content in logs — ever | `RecallCore/Log.swift`, `privacy: .public` used only for non-content |
| No cloud calls for AI | `RecallIntelligence/LanguageModelProvider.swift` has no remote implementation |
| Snippet tap is listen-only, opt-in, and keeps 32 characters | `RecallPaste/SnippetWatcher.swift`, `TypedBuffer` |

| AES-GCM sealing of every row body, blob and embedding | `RecallStorage/Crypto/Sealer.swift` |
| Key in the Keychain, device-only, never synced | `RecallStorage/Crypto/KeyStore.swift` |
| Blind index so the file cannot confirm a guessed string | `Sealer.blindIndex` |
| Full-text index and tags held in RAM, never written to disk | `RecallStorage/SearchIndex.swift` |

The plaintext floor — what stays queryable without the key — is listed in
[ADR 0004](adr/0004-encryption-at-rest.md).
