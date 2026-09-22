# ADR 0001 — All AI runs on device

**Status:** accepted

## Context

Recall's differentiators — semantic search, "Paste as…", summaries, auto-tagging — are
the kind of features normally served by a hosted model. But the data involved is the
user's clipboard: passwords they moved between apps, contracts, private code. A
clipboard manager that posts that to a server is a different, much worse product.

## Decision

Every embedding and every transformation runs on device. `LanguageModelProviding` and
`EmbeddingProvider` have no remote implementations, and adding one would be a
product-level decision, not a refactor.

Concretely: `NLEmbedding` for vectors today (zero setup, ships with the OS, works
offline), Apple's Foundation Models framework for generation, and a Core ML encoder
behind the same protocol if evaluation shows `NLEmbedding` is not good enough.

The one network call in the app is fetching a title and favicon for a copied link, which
is user-visible, off-switchable, and never sends clipboard content anywhere — it requests
the URL the user copied.

## Consequences

- AI features are unavailable on Intel Macs and when Apple Intelligence is off. They hide
  rather than degrade; there is no fallback to a cloud call.
- Quality is capped by what fits on device. Accepted.
- The privacy claim is verifiable by anyone with Little Snitch, which is the point.
