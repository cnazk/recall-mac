# ADR 0003 — Developer ID, not the Mac App Store

**Status:** accepted

## Context

Two core behaviours are incompatible with the App Sandbox as it stands:

1. **Source-app attribution.** Knowing which app a clip came from needs
   `NSWorkspace.frontmostApplication`, which a sandboxed app cannot rely on.
2. **Auto-paste.** Synthesising ⌘V needs Accessibility trust and `CGEvent` posting.

Both are central: app attribution is how the history list stays readable, and
paste-on-Return is the interaction the whole product is built around.

## Decision

Ship outside the Mac App Store, signed with a Developer ID certificate and notarised.
The App Sandbox is off; the hardened runtime is on.

## Consequences

- No Mac App Store listing, so no App Store discovery and self-hosted updates (Sparkle).
- The app must handle a denied Accessibility grant gracefully — copy-only, no nagging —
  because some users will never grant it, and that must remain a usable product.
- Users judge the app by its signature and notarisation, so CI signing is a shipping
  requirement, not a nicety.
