# ADR 0005 — Two-factor seeds live in a separate, sandboxed process

**Status:** accepted

## Context

Recall generates 2FA codes so the round trip through a phone collapses into the paste the
user was already doing. That means holding TOTP seeds — permanent secrets that mint valid
codes forever.

Recall is a bad place to keep them. By [ADR 0003](0003-distribution-and-sandboxing.md) it
is **unsandboxed by necessity**, it reads everything the user copies, and with snippet
expansion enabled it holds an event tap. Seeds in that process mean one compromise yields
the clipboard history, the keystrokes *and* the second factor — the exact combination 2FA
exists to prevent.

The plan framed this as "inside Recall, or a sibling app?" Both answers are bad: inside
concentrates the risk, and a sibling app throws away the reason to build the feature.

## Decision

Split by **what crosses the boundary**, not by what the user sees.

A sandboxed XPC service, `com.recall.otp`, bundled inside `Recall.app`, owns the seeds and
does the generating. Recall asks it for a *code*: six digits, one account at a time, on a
user action, after Touch ID. There is deliberately no call in `OTPServiceProtocol` that
returns a secret — except export, which is biometric-gated every time.

Consequences of that shape:

- A compromise of Recall yields, at most, the codes the user explicitly asked for in the
  last thirty seconds. It cannot enumerate accounts' seeds or mint future codes.
- The helper gives up everything it does not need: sandboxed, no network, no files, no
  Accessibility, no pasteboard. Recall cannot be sandboxed; the process holding the seeds
  can, and is.
- Both ends check a code-signing requirement. A bundled XPCService is only launched by
  launchd on behalf of its containing app, but a helper that accepts any caller is worse
  than no helper, so the check is made anyway.
- A copied `otpauth://` link is never stored in history. Writing it as a "secret" with a
  sixty-second countdown would still have put a permanent seed on disk.

## What proving it turned up

The helper has a `--selftest` flag, run from the built bundle, because this design rests
on assumptions that only hold when the code is signed and sandboxed. It immediately earned
its keep:

1. **Sandbox + data-protection keychain fails ad-hoc** with `errSecMissingEntitlement`
   (-34018). That keychain needs `keychain-access-groups`, which needs a real team
   identifier; an ad-hoc development signature has none. The helper now probes once and
   falls back to the file keychain, where the sandbox already scopes items to this
   process. A Developer ID build gets the better keychain; `--selftest` prints which one a
   given build is on, so this is never a guess.
2. **The file keychain refuses to return item data for a multi-item query** (`errSecParam`).
   Listing accounts now fetches attributes first and reads each seed individually — one
   code path that works on both keychains.

3. **Neither keychain works from the running helper**, which took until the app was
   actually used to discover. The data-protection keychain is out for the reason above.
   The file keychain decides access by an ACL tied to the calling code's signature — and
   the helper's signature changes with every build, so the ACL never matches and the
   Keychain wants to ask the user. An XPC service has no UI to ask with, so the call fails
   with `errSecInteractionNotAllowed` (-25308). It only ever worked when the helper was
   run by hand from a terminal, which inherits a UI session — so `--selftest` passed
   while the real thing did not. A self-test that exercises a different path from the
   product is a self-test that lies.

   Seeds now live in an AES-GCM sealed file in the helper's own sandbox container, with
   the key beside it. The directory is `0700` and both files `0600`, and no other
   sandboxed application can reach into that container. That is weaker than a
   data-protection keychain item and stronger than plaintext, and it is the best available
   without a signing identity. `SeedStore.migrateIfNeeded` carries across anything an
   earlier build left in the Keychain and is where the move *back* belongs once Recall has
   a Developer ID.

## Consequences

- A second signed target, its own Info.plist and entitlements, and bundling into
  `Contents/XPCServices/`. `Scripts/bundle.sh` does this and signs each separately.
- The Xcode project (open question 5) moves earlier: XPC services are painful without one.
- Touch ID is **on by default**, and the default is stored in the helper, not in Recall's
  settings — a security default the app could flip on its own is not a default.
