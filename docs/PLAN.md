# Recall — Build Plan

A local-first, AI-integrated clipboard manager for macOS.

**Status:** scaffolded. The module graph, capture pipeline, both stores, secret
detection, the AI protocols and a working menu-bar shell are in place and under test.
Everything marked *planned* below is designed but not yet implemented.

---

## 1. Product thesis

Maccy is fast and free. Paste is beautiful. Raycast has the hotkey. Recall's claim is
narrower and sharper:

> **The clipboard you can search by meaning, and trust with your secrets.**

Two things carry the product, and both must be true on day one or neither matters:

1. **It never leaks.** Password managers are excluded, secrets self-destruct, nothing
   leaves the Mac. A clipboard manager is a keylogger with good manners — the privacy
   story is the product, not a feature of it.
2. **It finds things you can't remember the words for.** "CSS rounding" finds
   `border-radius: 8px`. That is the demo, and it has to work offline, instantly.

Everything else — OCR, snippets, transforms, edge triggering — is table stakes or
delight, and is scheduled accordingly.

## 2. Principles

| Principle | Consequence in the code |
| --- | --- |
| Local-first, no exceptions | No network-backed `LanguageModelProviding` implementation exists. The only outbound request in the app is link enrichment, and it is one user-visible toggle. |
| Capture is sacred and fast | The pasteboard poll does classification and secret detection only. Network, Vision and the LLM all run after the item is already on screen. |
| Fail open, never fail closed | No Apple Intelligence? AI menu items hide. No Accessibility grant? Items still copy, the user pastes by hand. The app is useful before any permission is granted. |
| Secrets are never written | Detection runs *before* the store is touched, so a credential is never on disk waiting to be deleted. |
| The user's explicit choice wins | A pinned item is never deleted automatically — not by expiry, retention or the history limit. Where the app would have deleted something, it warns instead. |
| Testable without a GUI | `PasteboardSnapshot` decouples the pipeline from AppKit; every store conforms to one protocol and the suite runs against both. |

## 3. Architecture

```
       NSPasteboard (polled, 0.2s)
                │
      PasteboardMonitor ──▶ PasteboardReader ──▶ PasteboardSnapshot
                                                        │
                                                CaptureService
                                    exclusions → normalize → classify → detect secrets
                                                        │
                                                   HistoryStore
                                      SQLiteHistoryStore | InMemoryHistoryStore
                                                        │
                        ┌───────────────────────────────┼────────────────────────┐
                        ▼                               ▼                        ▼
                 EnrichmentPipeline            SemanticSearch             ExpiryReaper
              (link meta, OCR, summary,      (NLEmbedding vectors,     (deletes secrets
               auto-tags — all async)         FTS + cosine blend)       every 5 seconds)
                                                        │
                                                     AppModel
                                                        │
                                            HistoryPanelView (SwiftUI)
                                                        │
                                                   PasteService
                                          (writes pasteboard, synthesises ⌘V)
```

Module boundaries, all zero-dependency:

| Module | Owns | Depends on |
| --- | --- | --- |
| `RecallCore` | `ClipItem`, `ClipPayload`, `ContentHash`, settings, logging | — |
| `RecallSecurity` | Secret rules, app exclusions, concealed-type policy | Core |
| `RecallCapture` | Pasteboard polling/reading, normalization, classification | Core, Security |
| `RecallStorage` | `HistoryStore` protocol, SQLite + in-memory stores, expiry reaper | Core |
| `RecallEnrichment` | Link metadata, Vision OCR, enrichment pipeline | Core |
| `RecallIntelligence` | Embeddings, semantic search, on-device LLM, transforms | Core, Storage |
| `RecallPaste` | Pasteboard writing, ⌘V synthesis, snippet matching | Core |
| `RecallOTP` | RFC 6238 TOTP/HOTP, base32, `otpauth://` and migration parsing, the XPC protocol and client | — |
| `RecallOTPService` | The sandboxed helper: Keychain seed store, Touch ID, code generation. Seeds never leave it | `RecallOTP` |
| `RecallUI` | `AppModel`, panel and row views | all of the above |
| `RecallApp` | Composition root, menu-bar scene, lifecycle | all of the above |

See [ARCHITECTURE.md](ARCHITECTURE.md) for the detail, and `adr/` for the decisions
that are expensive to revisit.

## 4. What exists today

Runnable now with `make run`; `swift test` covers all of it.

- **Capture** — polling monitor, multi-format reader (text, RTF, PNG/TIFF, file URLs,
  source app), whitespace/zero-width/line-ending normalization, URL and hex-colour
  classification.
- **Dedup** — SHA-256 `ContentHash` over payload content; a repeat copy promotes the
  existing row and bumps its use count instead of inserting a duplicate.
- **Security** — nine built-in secret rules (AWS, GitHub, `sk-` keys, PEM blocks, JWTs,
  OTPs, Luhn-checked card numbers, password assignments), ~25 excluded bundle IDs, and
  the `org.nspasteboard.ConcealedType` convention. Secrets get a 60s deadline; the
  reaper enforces it on a timer and at every launch.
- **Storage** — SQLite with FTS5 and an embeddings table, plus a byte-identical
  in-memory store for In-Memory Mode. Both pass the same test suite.
- **Intelligence** — `NLEmbedding` vectors with keyword/semantic blended ranking;
  Foundation Models wired behind `LanguageModelProviding` with six "Paste as…"
  transforms, summarization and a fixed auto-tag vocabulary.
- **Pinning (partial)** — `isPinned` on the item, a toggle on both stores, pinned-first
  ordering everywhere (history, search results), exemption from retention eviction, a
  `pinnedOnly` filter, and the pin badge in the row. What's missing is everything that
  makes it *feel* like pinning; see §6.
- **UI** — menu-bar panel, search field, kind filter, keyboard navigation, context menu.

## 5. Roadmap

Phases are ordered by risk: the things that would invalidate the architecture come
first, the delight comes last.

### Phase 1 — Trustworthy capture *(done)*
- [x] Module graph, zero third-party dependencies
- [x] Multi-format capture and normalization
- [x] Content-hash deduplication with promotion
- [x] App exclusions + concealed-type honouring
- [x] Secret detection and 60-second expiry
- [x] SQLite + in-memory stores behind one protocol
- [x] **Encryption at rest** — AES-GCM sealing under a Keychain key, a blind index for
      the dedup hash, sealed embeddings and blobs, and the full-text index moved into RAM
      so no plaintext index survives on disk ([ADR 0004](adr/0004-encryption-at-rest.md))
- [x] `purgeExpired` skips pinned items — a pinned item is never removed automatically
- [x] Settings persistence (`SettingsStore`) and a three-tab Settings window
- [x] Large-image offload to a sealed, content-addressed blob store, with an inline
      thumbnail generated at capture so history rows never read blobs back

### Phase 2 — The panel people live in *(done)*
- [x] Global hotkey (⌘⇧V) through Carbon's `RegisterEventHotKey`, which needs **no**
      permission at all — better than the planned `CGEventTap`, which would have demanded
      Accessibility just to open our own window
- [x] Panel as a floating `NSPanel`, hiding on deactivate, remembering the previous app
- [x] Full keyboard model: ↑↓ select, ⇥/⇧⇥ cycle kinds, ⏎ paste, ⇧⏎ plain text,
      ⌥⏎ "Paste as…", ⌫ delete, ⎋ dismiss, ⌘1–9 pinned slots
- [x] Focus handed back to the previous app before the synthesised ⌘V, with a delay that
      survives Spaces and Stage Manager switches
- [x] Detail pane: preview, provenance, collections, and the sensitivity warnings
- [x] **Pinning, finished** — `pin_order` (schema v3), drag-to-reorder, pinned rail with
      ⌘1–9, global ⌘⇧1–9, the "kept deliberately" caution and the In-Memory notice
- [x] Keyboard model extracted into `PanelKeyboard` and unit-tested — every binding,
      including that ⌫ must not delete an item while the search field has text
- [ ] *Deferred to Phase 7:* XCUITest for hotkey → select → paste, which needs the Xcode
      project (§9). Tracked there rather than left open here.

### Phase 3 — Search that earns the name *(done)*
- [x] Background embedding backfill with progress, and vectors from a superseded model
      discarded rather than mixed into a different coordinate space
- [x] Ranking evaluation harness — a fixture corpus with the queries a person would
      actually type, measuring recall@3. **It immediately found a real problem; see §6.5.**
- [x] Query expansion through the on-device model, which is what makes the headline
      demo work
- [x] Coarse pre-filter so vectors are only scored for items surviving the query's
      filters, which is what keeps brute force viable as history grows
- [x] Query operators: `kind:image`, `app:Xcode`, `since:yesterday`, `is:pinned`

### Phase 4 — AI that pays for itself *(done)*
- [x] "Paste as…" sheet (⌥⏎) with streaming output and a preview before it commits — a
      transform is a guess about intent, and pasting a guess into someone's document is
      how you lose their trust
- [x] Translation target-language picker, re-running on change
- [x] Summaries on capture for long clips, with a "Reading…" state in the row so it does
      not silently rewrite itself a second later
- [x] Smart Collections: sidebar backed by auto-tags, plus user-defined rules in Settings.
      A collection is a saved question, so clearing history does not remove them, and one
      with no conditions is rejected rather than matching everything
- [x] Guardrails: no transform, no expansion and no AI menu for a `.secret` item; 8,000
      character cap on model input; settings decode tolerantly so one added field cannot
      cost a user every other preference

### Phase 5 — Extraction and workflows *(done)*
- [x] Direct-to-clipboard OCR: ⌥⌘⇧2 drags out a region, Vision reads it, and the text
      lands on the clipboard *and* in history. Backed by `/usr/sbin/screencapture`, which
      already draws the selection UI everyone knows and handles its own permission prompt;
      a cancel leaves nothing behind
- [x] Image text search — OCR text is part of `indexableText`, so it reaches the in-memory
      index like any other text. Asserted in both stores
- [x] Snippet expansion: a listen-only event tap, `TypedBuffer` feeding
      `SnippetExpander`, then backspaces and a paste that restores the clipboard
- [x] Snippet management: a sheet from the panel's context menu, a read-only list in
      Settings, and the offer to add one that appears after pinning
- [x] Pinning offers to assign a shortcode — as a quiet link in the detail pane rather
      than a sheet that interrupts the pin

### Phase 5.5 — One-time codes *(done)*
Built as a separate sandboxed process rather than inside Recall — see
[ADR 0005](adr/0005-two-factor-helper.md).
- [x] `RecallOTP`: RFC 6238 TOTP/HOTP verified against every published test vector, plus
      base32 and `otpauth://` parsing
- [x] `com.recall.otp`: a sandboxed XPC helper holding the seeds in the Keychain,
      device-only and non-syncing. Recall receives codes, never secrets
- [x] Touch ID gate, **on by default**, with the default held by the helper
- [x] Import by copied `otpauth://` link, by QR region capture, by hand, and from a
      Google Authenticator `otpauth-migration://` export
- [x] Codes tab with the drain ring, type-to-filter, ⌘⇧A, and ⌘1–9 slots
- [x] Export every seed back out as `otpauth://` URIs, biometric-gated every time
- [x] A copied setup link is never written to history — it is offered to the helper

### Phase 6 — Delight *(done)*
- [x] Edge triggering, as a pure policy (`EdgeTriggerPolicy`) driven by a global mouse
      monitor. Dead zone while dragging, hot corners left to macOS, hysteresis on leaving
      the edge, and a cooldown so dismissing the panel does not reopen it
- [x] Floating always-on-top scratchpad: the same list with the opposite instinct to the
      panel — it stays until dismissed and remembers where it was put (⌥⌘V)
- [x] Drag-and-drop out of the history list, with images registered as a promise so the
      sealed blob is only read when the drop actually happens
- [x] Appearance settings (row density, source icons), a history size indicator that
      reads zero in In-Memory Mode, and first-run onboarding that explains both
      permissions *before* macOS asks for either

### Phase 7 — Shipping
- [ ] Xcode project (checked-in `project.yml` for XcodeGen) and XCUITest for
      hotkey → select → paste, carried over from Phase 2
- [ ] Developer ID signing + notarisation in CI
- [ ] Sparkle updates
- [ ] Crash reporting that cannot capture clipboard content
- [ ] Privacy page that states, in plain words, what never leaves the Mac

## 6. Pinning

Pins are the part of history a user *curates* rather than accumulates: the signature, the
staging DB connection string, the ticket ID they will paste forty times today. The
storage half of this is built. The interaction half is not.

**The governing rule: a pinned item is never removed automatically.** Not by the history
limit, not by the retention cutoff, and not by secret expiry. A pin is the user saying
"keep this", and the app does not overrule it. Where Recall would otherwise have deleted
something, it warns instead.

### Built already

| Behaviour | Where |
| --- | --- |
| `isPinned` on `ClipItem`, persisted as an indexed `pinned` column | `RecallCore/ClipItem.swift`, `RecallStorage/Schema.swift` |
| `setPinned(_:id:)` on both stores, `togglePin` on the model, Pin/Unpin in the context menu | `RecallStorage/`, `RecallUI/` |
| Pinned items sort above everything, in history *and* in search results | `InMemoryHistoryStore`, `SQLiteHistoryStore`, `SemanticSearch` |
| Pinned items are never evicted by the history limit or the retention cutoff, and don't count against the limit | `enforceRetention`, covered by a test in both stores |
| Pin badge in the row; `HistoryQuery.pinnedOnly` for a pinned-only view | `ItemRowView`, `HistoryQuery` |
| A re-copy promotes the existing row, so re-copying a pinned item keeps its pin | `capture` in both stores |

### To build

**Ordering.** Pins currently sort by `lastUsedAt`, which means the list reshuffles itself
as you use it — the opposite of what a pinned item is for. A pin should stay where the
user put it.

- [x] `pin_order INTEGER` column (shipped as migration **v3**), assigned on pin, `NULL` when unpinned
- [x] `ORDER BY pinned DESC, COALESCE(pin_order, …) ASC, last_used_at DESC`
- [x] `reorderPins(_ ids: [UUID])` on `HistoryStore`, one transaction for the ordering
- [x] Drag to reorder within the pinned group
- [x] Sparse ordering (`PinOrder.spacing`) so a single move is one row update

**Reach.** A pin the user still has to scroll to has not earned its place.

- [x] A pinned rail at the top of the panel, visually separated, that does not scroll
      away with the results
- [x] ⌘1–⌘9 pastes pinned slot 1–9 directly from the panel, without arrowing to it
- [x] ⌘P toggles the pin on the selection; ⌥⌘1–9 assigns a slot
- [x] Global ⌘⇧1–9 to paste a pin *without opening the panel at all* — the fastest path
      in the product, and the reason to pin something in the first place
- [x] Pins survive search: typing a query filters the results list, not the rail

**Never auto-removed.** The store half of this rule is in place: `purgeExpired` skips
pinned items in both stores, and two tests hold all three deletion paths to it. The
warnings that replace the deletion are not.

- [x] `purgeExpired` skips pinned items, asserted in the dual-store suite
- [x] Pinning a secret clears the countdown and replaces the timer badge with a small
      inline caution: *"Pinned — this looks like a credential and will be kept until you
      remove it."* Quiet, one line, dismissible, never a modal
- [x] The same caution appears in the detail pane, with the rule that fired (`otp`,
      `credit-card`, `aws.access-key`) so the user can judge a false positive
- [x] Unpinning a still-sensitive item restores a fresh 60-second countdown rather than
      deleting it on the spot — no action should ever destroy data as a side effect
- [x] Retention and the history limit already skip pinned items; a test asserts each of
      the three deletion paths leaves pins alone, so the rule cannot rot

**Edges.**

- [x] Pinning offers to assign a snippet shortcode (`:sig`) — a link in the detail pane,
      not a sheet that interrupts the pin
- [x] **Pin limit — decided: soft-unlimited, first nine addressable.** A hard cap would
      mean refusing to keep something the user asked to keep, which contradicts §6's rule.
      Pins past nine lose only their shortcut, and the rail keeps scrolling
- [x] "Clear History…" says plainly that everything *except* pinned items is deleted
- [x] Pinned items in the detail pane show "pinned" rather than a relative timestamp,
      which is meaningless for something kept deliberately

### Decisions, settled

1. **Pinning defeats expiry.** A pinned item is never automatically removed — see above.
   The residual risk is real and accepted: a pinned credential sits in the history
   database until the user deletes it, which is exactly why encryption at rest (Phase 1)
   has to land before this ships to anyone. The warning is the mitigation, not a
   formality: it has to name what was detected, or it teaches users to ignore it.
2. **Pins do not survive In-Memory Mode, and the app says so up front.** No sidecar file:
   In-Memory Mode's promise is that nothing touches the disk, and carving out an
   exception — even for explicit user choices — makes that promise something you have to
   read the small print to understand. Instead:
   - [ ] The pinned rail carries a persistent, low-key label while In-Memory Mode is on:
         *"Pins are temporary — In-Memory Mode clears everything when Recall quits."*
   - [ ] Pinning the first item in a session confirms once: *"This pin will be lost when
         you quit. Turn off In-Memory Mode to keep pins."* with a "Don't ask again" box
   - [ ] Switching *into* In-Memory Mode while pins exist warns before it takes effect
         and says how many pins will be discarded
   - [ ] Quitting with pins in In-Memory Mode does **not** prompt — a warned user being
         asked again at quit is nagging, and quit must stay instant
3. **Pins do not outrank relevance in an active search.** Pinned-first ordering stays in
   the browsing list and drops to a tiebreaker once a query is typed. Pins live in the
   rail, which is visible either way.

### How it is tested

The store-level rules extend the existing dual-store suite, so they hold for In-Memory
Mode and SQLite alike. Two tests already assert the never-auto-removed rule: a pinned
secret outlives its deadline, and a pinned item survives expiry, the retention cutoff and
the history limit applied in turn. Ordering and slot assignment join them as they land;
drag reordering and the shortcuts go to XCUITest in Phase 2.

## 6.5. What the ranking harness found

The plan listed "`NLEmbedding` may not carry *CSS rounding* → `border-radius`" as a risk,
with the eval harness as the thing that would decide it. The harness decided: **it does
not.**

Measured on the fixture corpus, cosine similarity of `NLEmbedding` sentence vectors:

| Query | Clip | Similarity |
| --- | --- | --- |
| "CSS rounding" | `border-radius: 8px;` | **0.201** |
| "CSS rounding" | `def parse(x): return int(x)` (unrelated) | 0.256 |
| "flight details" | `AA219 · SFO → BOS · departs 14:05` | 0.488 |

The right answer scores *below* an unrelated Python snippet. Sentence embeddings carry
prose similarity — "flight details" → an itinerary works well — but not technical
synonymy, which is exactly the case §1 promises.

Recall@3 over the five vocabulary-mismatch queries in the corpus:

| Configuration | recall@3 |
| --- | --- |
| Embeddings + keyword only | 0.60 |
| \+ on-device query expansion | **0.80** |

### The fix

`QueryExpanding` asks the on-device model what words would literally appear in the thing
being looked for — "CSS rounding" becomes `border-radius, corner-radius, rounded` — and
searches for those too, scored strictly below any literal hit. It needs no model download,
stays on device, and is cached per query.

Three things this deliberately does *not* do:

- It never outranks what the user typed. Expansion sits at 0.8, literal hits at 1.0.
- It degrades to nothing. No Apple Intelligence means no expansion, not a broken search.
- It is not a substitute for a better encoder. A Core ML sentence encoder behind
  `EmbeddingProvider` is still the right long-term answer for the semantic half; the
  harness now exists to prove whether a given one is actually better.

`RankingEvalTests` asserts the ceiling as well as the floor: if embeddings alone ever
answer every hard query, the test fails on purpose so the finding gets revisited.

## 7. One-time codes (TOTP generation)

Recall generates the 2FA codes itself, so the round trip through a separate authenticator
app — unlock phone, read six digits, type them before they rotate — collapses into the
paste the user was already doing.

### Why this is a bigger decision than it looks

Every other feature in Recall reads things the user copied. This one has Recall *hold a
credential*. A TOTP seed is a permanent secret: whoever has it can mint valid codes
forever. Putting seeds in the same app that records your clipboard concentrates risk —
a single compromise could yield both the password (out of history) and the second factor,
which is precisely what 2FA exists to prevent.

That risk is accepted deliberately, not designed away, and the design pays for it:

- **Seeds never enter the history database.** They live in the login Keychain as generic
  password items, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, iCloud sync off. The
  history row holds a Keychain reference and the issuer label — nothing that can generate
  a code.
- **Seeds are never a `ClipItem`.** When an `otpauth://` URI is copied, Recall offers to
  import it and the clip is dropped, not stored — the same path an excluded app takes.
- **Revealing or pasting a code requires Touch ID** (`LocalAuthentication`), on by
  default, with a grace period the user sets.
- **Generated codes are not history.** A pasted code is written straight to the
  pasteboard with the monitor's `ignoreNextChange`, so it never becomes a clip, and the
  pasteboard is cleared after 30 seconds unless overwritten first.
- **Seeds are never logged, never in a crash report, never in a backup of the app's
  Application Support directory.**

### Design

**Import.** Three routes, in order of how people actually have their seeds:

- [ ] Copy an `otpauth://totp/Issuer:account?secret=…` URI → Recall recognises it on
      capture and offers *"Add to Recall"* instead of storing it
- [ ] **Screen-capture the QR code** — the ⌘⇧2 region capture from Phase 5 already exists
      for OCR; pointing `VNDetectBarcodesRequest` at the same bitmap turns "drag a box
      over the setup QR on screen" into the fastest import path anywhere, with no phone
      involved
- [ ] Manual entry: issuer, account, base32 secret, with digits/period/algorithm behind a
      disclosure triangle

**Generation.** RFC 6238, implemented in a new `RecallOTP` module against `CryptoKit`'s
`HMAC`:

- [ ] HMAC-SHA1/SHA256/SHA512, 6–8 digits, configurable period (default 30s)
- [ ] Verified against the RFC 6238 test vectors — a table test, checked in, which is the
      whole reason to implement this rather than take a dependency
- [ ] HOTP (counter-based) support, since a few services still use it
- [ ] Clock-skew tolerance on verify paths only; generation always uses local time

**Interaction.**

- [ ] A **Codes** tab in the panel: issuer, account, the current code, and a ring that
      drains over the period. Codes are not in the history list — they are not history.
- [ ] Return pastes the code and dismisses; the ring colour turns amber under 5 seconds
      left, and Recall regenerates rather than pasting a code about to expire
- [ ] Type-to-filter by issuer, so "git" + Return pastes the GitHub code
- [ ] Global ⌘⇧A opens straight to Codes with the field focused
- [ ] Pinned codes get ⌘1–9 slots, exactly like pinned clips

**Interactions with what already exists.**

- The `otp` secret rule still fires on codes copied from *elsewhere*; a code Recall
  generated is written with `ignoreNextChange` and never reaches the detector.
- Authenticator apps stay on the exclusion list. Recall being an authenticator does not
  make other authenticators safe to capture from.
- Recall excludes itself, so a code it pastes can never round-trip into history.
- The AI never sees a seed or a code: `.secret` items already skip enrichment, and codes
  are not items at all.

**Settings.**

- [ ] The whole feature is off until the user adds their first seed — no dormant
      credential store in an app that was installed to manage a clipboard
- [ ] Export: every seed back out as `otpauth://` URIs, Touch ID gated. An authenticator
      that holds your seeds hostage is a worse authenticator.
- [ ] Removing a seed is immediate, confirmed, and irreversible

### Open questions

1. ~~Inside Recall, or a sibling app?~~ **Decided: neither — a separate *process*.** A
   sandboxed XPC helper inside `Recall.app` owns the seeds; Recall gets codes. The user
   never sees the boundary, and a compromise of Recall cannot mint future codes.
   [ADR 0005](adr/0005-two-factor-helper.md).
2. ~~Touch ID: default on or off?~~ **Decided: on**, with the default held by the helper
   rather than by Recall's settings — a security default the app can flip on its own is
   not a default.
3. ~~Import from Google Authenticator's export?~~ **Decided: yes, built.** The payload is
   a protobuf, decoded by a ~100-line reader written from the published schema rather than
   a library — a dependency in the process that handles 2FA seeds is a dependency that can
   exfiltrate them. Tested by encoding fixtures with a *separate* writer, since encoding
   with the same code that decodes would prove nothing.

## 7.5. What running the app found

Three bugs that every unit test missed, because they were in the wiring rather than in
any one unit. All three are fixed; the first is the reason the integration tests in
`RecallCaptureTests` now exist.

**1. The app captured nothing, and said nothing.** Opening the encrypted store reads the
key from the Keychain, synchronously, inside `applicationDidFinishLaunching`. A rebuilt
binary has a new code signature, so macOS puts up an ACL dialog — and an agent app with no
window has nowhere to show it. The app sat there: no capture, no panel, no log line, alive
and useless.

Fixes: the store now opens off the main thread; a watchdog puts *"Waiting for permission
to use your keychain…"* in the menu after three seconds; the data-protection keychain is
tried first, since access there is decided by signature and entitlement rather than by an
interactive prompt; and `KeyStoreError.timedOut` explains what to click and why it
happened.

**2. Recall would have re-captured everything it pasted.** The monitor's
`ignoreNextChange` hook was wired to a `PasteService` the app created, while `AppModel`
quietly built its own. The hook was dead code. `PasteService` is now injected, and a test
asserts a self-write is not captured back.

**3. Unit tests all passed throughout.** That is the actual lesson. `RecallCaptureTests`
now drives the real `PasteboardMonitor` against the real `NSPasteboard` (borrowing and
restoring the user's clipboard), which is the only kind of test that could have caught
either bug.

Verified against the running app afterwards: text and URLs captured and classified, link
metadata fetched, and `border-radius`, `developer.apple.com` and `foundationmodels` all
absent from the database file on disk while `kind`, `pinned` and `sensitivity` remain
queryable — the plaintext floor from [ADR 0004](adr/0004-encryption-at-rest.md), exactly
as specified.

## 7.6. The event tap, and why this one is different

Snippet expansion is the only feature in Recall that watches anything outside Recall. That
deserves stating plainly rather than burying in a settings footnote:

- **Off until asked.** `snippetExpansionEnabled` defaults to false. Accessibility is
  requested only when the user turns it on, never at launch.
- **Listen-only.** The tap is created with `.listenOnly`, so Recall cannot swallow, delay
  or alter a keystroke on its way to the app being typed into. It can watch; it cannot
  intervene.
- **It keeps 32 characters.** `TypedBuffer` holds only enough to match the longest
  shortcode, drops the oldest characters past that, and empties the moment the user
  presses Return or Escape, moves the cursor, or uses any ⌘ or ⌃ shortcut. The size cap is
  asserted by a test whose failure message says what it is protecting against.
- **Nothing typed is ever stored.** The buffer is a value on one object in memory. It
  never reaches the database, the index, a log line or a model.
- **Expanding restores the clipboard.** A snippet paste puts back whatever was there
  before, so using `:sig` does not cost the user the thing they had copied.

The honest caveat: an event tap is an event tap. A user who does not want one should leave
this off, and everything else in Recall keeps working — which is why it is a switch and
not a prerequisite.

## 7.7. What Phase 6 could not verify

Edge triggering is the first feature in Recall that cannot be checked end to end from
here, and that is worth stating rather than quietly claiming it works.

- **The policy is tested.** `EdgeTriggerPolicy` is a pure state machine with ten tests
  covering the dwell, the drag dead zone, hot-corner exclusion, re-arming on leaving the
  edge, and the cooldown.
- **The monitor is proven.** A standalone probe confirmed that
  `NSEvent.addGlobalMonitorForEvents` delivers `mouseMoved` with `AXIsProcessTrusted()`
  false — 212 events in five seconds. Global *mouse* monitoring genuinely needs no
  permission, unlike keyboard monitoring. That assumption is now measured, not inherited
  from documentation.
- **The join between them is not.** Driving the cursor to a screen edge requires
  synthesising mouse events, which requires Accessibility permission. Attempting it
  without that permission had the events silently dropped: the pointer never got closer
  than 1,243 px to the edge, which is what exposed the test rig rather than the feature.

So the first real cursor-at-the-edge test is a human moving a mouse, or the XCUITest that
arrives with the Xcode project in Phase 7. Until then, treat edge triggering as built and
unit-tested but not interactively exercised.

## 8. Testing strategy

| Layer | How it is tested | Where |
| --- | --- | --- |
| Model, hashing, expiry | Unit tests, pure values | `RecallCoreTests` |
| Secret rules | Table-driven positives *and* negatives across all 26 rules — false positives matter as much as misses. Recovery phrases are checked against the real wordlist and checksum | `RecallSecurityTests` |
| Paste stack | Order, draining, idle expiry, capacity and re-queuing, as pure value semantics | `RecallPasteTests` |
| Capture pipeline | `PasteboardSnapshot` fixtures, no AppKit needed | `RecallCaptureTests` |
| Stores | One suite run against both implementations, so they cannot drift | `RecallStorageTests` |
| Ranking | *Planned:* fixture corpus with expected results per query | `RecallIntelligenceTests` |
| Pin durability | Each of the three deletion paths (expiry, retention, limit) asserted to leave pins alone, in both stores | `RecallStorageTests` |
| Keyboard model | Every panel binding, as a pure mapping from keystroke to command | `RecallUITests` |
| Edge triggering | The policy — dwell, drag dead zone, hot corners, re-arming, cooldown. The pointer itself cannot be driven from CI without Accessibility (§7.7) | `RecallUITests` |
| TOTP | Every published RFC 4226 and RFC 6238 vector, plus import parsing and a migration fixture built by an independent writer | `RecallOTPTests` |
| Helper, signed and sandboxed | `--selftest` on the built bundle: keychain round-trip, code generation, biometric default | `com.recall.otp --selftest` |
| Typed buffer | Accumulation, backspace, the size cap, and shortcode matching across a typing correction | `RecallPasteTests` |
| Region capture | Cancel and failure paths, by pointing the runner at `/usr/bin/true` and `/usr/bin/false` | `RecallEnrichmentTests` |
| Wiring | The live `PasteboardMonitor` against the real `NSPasteboard`, including that a self-write is not re-captured | `RecallCaptureTests` |
| Panel behaviour | *Planned:* XCUITest for hotkey → select → paste | — |

The AI is tested through `LanguageModelProviding` stubs; no test depends on Apple
Intelligence being available on the machine running it.

## 9. Risks and open decisions

| Risk | Why it matters | Position |
| --- | --- | --- |
| Metadata is still readable on disk | Timestamps, kinds, pinned/sensitivity flags and snippet codes stay in the clear so they can be queried without the key. | Deliberate and documented as the plaintext floor ([ADR 0004](adr/0004-encryption-at-rest.md)). Anything describing *content* is sealed. |
| Sandbox vs. capability | Source-app attribution and ⌘V synthesis are incompatible with the App Sandbox. | Ship Developer ID + notarised, outside the Mac App Store. [ADR 0003](adr/0003-distribution-and-sandboxing.md). |
| Accessibility permission | Users are rightly suspicious; some will refuse. | The app must be fully useful without it. Auto-paste degrades to copy-only, and we ask only when the user turns it on. The panel hotkey needs no permission at all. |
| Keychain prompt on every rebuild | The encryption key is bound to the code signature, so each dev build re-prompts — and an agent app cannot show that dialog well (§7.5). | Startup is off the main thread with a watchdog and a plain-language message. Production builds have a stable Developer ID signature and prompt once. |
| Polling cost | A 0.2s timer runs forever. | Measured at launch; drop to 0.5s on battery. Revisit if it ever shows up in Energy Impact. |
| Embedding quality | **Confirmed, not hypothetical**: `NLEmbedding` scores "CSS rounding" against `border-radius` *below* unrelated code (§6.5). | On-device query expansion lifts recall@3 from 0.60 to 0.80 and ships now. A Core ML encoder behind `EmbeddingProvider` remains the long-term answer, and the harness can now judge one. |
| Apple Intelligence availability | Unavailable on Intel Macs and when the user has it off. | AI features hide rather than degrade into a cloud call. |
| False-positive secret detection | An item silently vanishing after 60s is alarming. | Rules require high confidence; the row shows a timer badge and why it fired, and undo is Phase 2. |
| Pinning half-lands | The storage rules hold the never-auto-removed rule, but the interaction — ordering, rail, slots, and the warnings that stand in for deletion — is not built. | Finish it in Phase 2 as one piece (§6). |
| A pinned credential lives forever | Pinned items are never auto-removed, so a user who pins a detected secret keeps it in the database indefinitely. | Deliberate, and now sealed at rest; the inline warning names what was detected. |
| TOTP seeds concentrate risk | Holding the second factor in the app that holds clipboard history means one compromise can yield both. | **Resolved by construction**: the seeds live in a sandboxed helper process that Recall can only ask for codes ([ADR 0005](adr/0005-two-factor-helper.md)). |
| Keychain re-prompts after every rebuild | Bit the smoke tests twice: the app creates its history file, then blocks invisibly on the ACL dialog, so it looks alive but captures nothing. | Watchdog message in the menu (§7.5). For development, `security delete-generic-password -s com.recall.app -a history-encryption-key` resets it; production has a stable signature and prompts once. |
| Large images in SQLite | Screenshots are megabytes; inline BLOBs bloat the DB and slow queries. | Blob store keyed by content hash. Phase 1. |

**Open questions for you:**

1. **Distribution**: Developer ID direct download is assumed. Mac App Store would force
   giving up source-app attribution and auto-paste — is that trade ever acceptable?
3. **Price and licence**: free/open, one-off, or subscription? It changes whether Sparkle
   and a licence server are in scope.
4. **Xcode project**: the SwiftPM + `bundle.sh` setup builds a real signed `.app` today.
   Moving to an `.xcodeproj` (via XcodeGen, checked-in `project.yml`) buys easier
   notarisation and XCUITest. Worth doing at Phase 2, or sooner?

## 10. Beyond the plan

Ideas that are not commitments live in [FUTURE.md](FUTURE.md): the paste stack, per-app
rules, Quick Look, a Shortcuts and CLI surface, clip diffing, pausing capture, profiles
with separately encrypted and lockable histories, and the next batch of detector rules.
Each entry there names what has to be decided before it can be started.

## 11. Getting started

```bash
make test   # run the suite
make app    # build and ad-hoc-sign .build/Recall.app
make run    # build and launch (menu-bar icon, no Dock icon)
```

First launch asks for nothing. Accessibility is requested only when auto-paste is
turned on.

## 7.8 What a day of running the packaged app found

Five bugs, none of which any test caught, and two of which I misdiagnosed on the way.

**Opening the store blocked a cooperative thread.** §7.5 moved the store open off the main
thread with `Task.detached`, which runs on Swift's cooperative pool — a pool sized to the
core count that must never be blocked. Unlocking the encryption key can sit in a
synchronous Keychain call for as long as it takes the user to answer a dialog. The app
launched, drew its menu, and then did nothing at all: every hot key, menu item and
captured clip goes through `Task { @MainActor in … }`. It now opens on a plain GCD queue,
which is built for blocking calls.

**`MenuBarExtra` crashes on every use.** Activating one of its buttons goes through
SwiftUI's `ButtonAction.callAsFunction`, which calls `MainActor.assumeIsolated`; that
faults inside a menu tracking session. The reports contain no Recall code at all. The menu
is an `NSStatusItem` and an `NSMenu` now, with a target that is deliberately not
`@MainActor` — a `@MainActor` class's `@objc` methods carry the same compiler-inserted
check.

**Closures in `@MainActor` types inherit isolation**, and when AppKit calls them from
non-isolated code the compiler puts that same check in the prologue. Removing an
`assumeIsolated` from a closure *body* therefore changes nothing, which cost a round of
fixes to learn. The mouse monitor, the event tap and the Carbon handler are built from
`nonisolated` factories now, verified by disassembling the release binary.

**`hidesOnDeactivate` hid the panel instantly.** It hides a window whenever its
*application* is inactive, and Recall is an `.accessory` agent that is essentially never
active. The hot key looked dead. The scratchpad already had this right.

**⌥⌘V was never wired up.** A `MenuBarExtra` button's `.keyboardShortcut` only fires while
the app is active, so the chord the menu advertised had nothing listening for it
system-wide. It is a Carbon registration now; the paste stack moved to ⌃⌥⌘V.

**On method.** Two theories were presented with more confidence than the evidence
supported — that a background-thread pasteboard read was corrupting the heap, and that the
macOS 15 deployment target was behind the SwiftUI crash. Both changes were correct on
their own merits and neither was the cause. What actually worked was sampling the wedged
process, disassembling the shipped binary, and building minimal probes to decide whether a
given failure was Recall's or the platform's. A crash report says where a process died,
not what killed it.

**Instrumentation kept.** The app logs one line when a main-actor task first runs and a
fault if none has run after two seconds, and `--heartbeat` keeps checking. Capture logs
the kind of each clip — never content. `--in-memory` forces RAM-only storage for a run,
which is how the keychain can be taken out of the picture while testing.

### 7.9 The one that was underneath all of it

`PanelController.makePanel` set `collectionBehavior` to
`[.canJoinAllSpaces, .fullScreenAuxiliary, .moveToActiveSpace]`. The first and last of
those are **mutually exclusive**, and `-[NSWindow setCollectionBehavior:]` raises
`NSInternalInconsistencyException` when both are set.

AppKit does not let that crash. HIServices catches the exception and **suspends the thread
that raised it** — the sampled process shows the thread as
`SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION`. That thread was running a main-actor
job, so the main actor was never released, and every later `Task { @MainActor in … }`
queued behind it forever. Recall kept running and kept drawing its menu while silently
doing nothing: no hot keys, no menu items, no capture, no crash report.

So the first ⌘⇧V after launch killed the app, and everything after it looked like a
different bug. This was present since Phase 6 and no test could see it, because the panel
had never actually been opened in a packaged run.

Found by adding `--show-panel`, which opens the panel three seconds after launch. The
panel is otherwise reachable only by a global hot key or a menu click, and neither can be
driven without Accessibility — so the one code path that mattered was the one that could
not be exercised. The flag stays for that reason, alongside `--in-memory` and
`--heartbeat`.

`CollectionBehaviorTests` now asserts that neither window sets more than one Space option.
