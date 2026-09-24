![Recall — a local-first, AI-integrated clipboard manager for macOS](docs/banner.jpg)

**English** · [فارسی](README.fa.md) · [Русский](README.ru.md) · [简体中文](README.zh-Hans.md)

Recall remembers everything you copy, lets you search it by *meaning* rather than by the
exact words, and treats anything that looks like a credential as radioactive.

![Recall's history panel: searching for "rounding" surfaces a CSS border-radius snippet that never contains the word](docs/demo.gif)

Searching for **rounding** finds the `border-radius` snippet — a word that appears nowhere
in it. No index of synonyms, no cloud service: an on-device embedding model and a query
expander that runs on your Mac.

---

## Contents

- [Why another clipboard manager](#why-another-clipboard-manager)
- [Search that earns the name](#search-that-earns-the-name)
- [Paste as…](#paste-as)
- [Secrets are treated as radioactive](#secrets-are-treated-as-radioactive)
- [Two-factor codes](#two-factor-codes)
- [Snippets and shortcodes](#snippets-and-shortcodes)
- [Todos](#todos)
- [Text out of pictures](#text-out-of-pictures)
- [The rest of it](#the-rest-of-it)
- [Keyboard](#keyboard)
- [What never leaves your Mac](#what-never-leaves-your-mac)
- [Install](#install)
- [Status](#status)
- [Support Recall](#support-recall)
- [License](#license)

---

## Why another clipboard manager

Because the interesting problems in a clipboard manager are not storage and a list.
They are:

- **You remember what a thing *was*, not what it *said*.** So search has to work on
  meaning.
- **A clipboard manager is the best-placed credential thief on the machine.** So it has to
  be built as if it were one, and refuse.
- **The model should run where the data is.** Sending your clipboard to an API to get a
  summary is a strange trade to make for a sentence.

Everything below follows from those three.

---

## Search that earns the name

Type what you half-remember. Recall scores an on-device embedding of your query against
every clip, after a coarse filter narrows the field so brute force stays viable as history
grows.

Query expansion is what makes the demo above work: sentence embeddings alone rank
*"rounding"* against a CSS rule below unrelated code. An on-device language model widens
the query first. This is measured, not assumed — there is a ranking evaluation harness
with the queries a person would actually type, scoring recall@3, and it caught a real
regression the day it was written.

Operators compose with all of it:

| Operator | Finds |
| --- | --- |
| `kind:image` | images only — also `text`, `link`, `color`, `file` |
| `app:Xcode` | clips copied out of a particular app |
| `since:yesterday` | anything newer than that |
| `is:pinned` | your pinned clips |

**Smart Collections** are saved questions, in a sidebar. Auto-tags feed them, and you can
write your own rules. Clearing history doesn't remove a collection — a question survives
its answers. A collection with no conditions is rejected rather than quietly matching
everything.

---

## Paste as…

Press **⌥⏎** on any clip to run it through an on-device model before it lands: a Markdown
table, a translation, a summary, JSON, Python.

The output streams into a preview, and nothing is pasted until you accept it. A transform
is a *guess* about intent, and pasting a guess into someone's document is how you lose
their trust.

There is no transform, no expansion and no AI menu for a clip marked secret.

---

## Secrets are treated as radioactive

A clipboard manager sees every password you copy. Recall is built on the assumption that
this is a liability rather than a feature.

### Detected on capture

**29 rules** run at capture time, before anything is written. Each one is a published,
fixed shape, so the false-positive rate is near zero:

| | |
| --- | --- |
| **Cloud & infra** | AWS access key, AWS secret key, Google API key, Cloudflare token, Kubernetes config |
| **Developer platforms** | GitHub token, GitLab token, npm token, Hugging Face token |
| **Payments & comms** | Stripe key, Twilio identifier, SendGrid key, Slack token, Discord bot token, Telegram bot token |
| **AI providers** | Anthropic API key, generic `sk-` / `pk-` API keys |
| **Keys & tokens** | Private key block, JSON web token |
| **Personal** | Card number, IBAN, national ID number, recovery phrase, app-specific password |
| **Text shapes** | URL with a password, database connection string, environment file, password assignment, one-time code |

A clip that matches is marked `secret`. It is **kept in memory only, never written to
disk**, concealed in the list, excluded from AI features, and **deleted 60 seconds later**
(configurable).

Recall also tells you *which* rule fired. A caution you cannot check is a caution you
learn to ignore. Any rule can be switched off individually.

### Never captured at all

Clips from **28 password managers and authenticators** — 1Password, Bitwarden, KeePassXC,
Dashlane, Enpass, LastPass, NordPass, Proton Pass, Strongbox, Secretive, Apple's Keychain
Access and Passwords, Authy and others — are dropped before they are read, as are
pasteboard items marked concealed by the app that wrote them. You can add your own.

### In-Memory Mode

Run the whole app in RAM. No database file, no blob directory, no encryption key.
Quitting erases everything.

### On disk

Everything else is an encrypted SQLite database: AES-GCM sealed bodies, blind indexes for
lookup, WAL journaling, `0700` on the directory.

---

## Two-factor codes

Recall generates TOTP and HOTP codes — the six digits an authenticator app gives you.
Press **⌘⇧A**.

This is the feature with the most reason *not* to exist in a clipboard manager, so it is
built to a different standard than the rest of the app.

### The seeds are not in the app

A 2FA seed is not a password. It mints valid codes forever, and it never rotates on its
own. So Recall does not hold one.

The seeds live in **a separate, sandboxed XPC helper process** with its own code
signature, its own container, and its own — far narrower — entitlements. While the main
app cannot be sandboxed (reading the pasteboard's source app and synthesising ⌘V both need
capabilities the sandbox doesn't grant), **the helper is**, and it surrenders everything it
does not need: no network, no file access, no Accessibility, no pasteboard, no camera.

The protocol between them has no call that returns a secret. Not a guarded one, not an
authenticated one — there is no such method to call, because the app has no business
holding a seed. It asks for a *code*; it receives a *code*.

Seeds are sealed with AES-GCM inside the helper's container, `0600`, in a single document
rewritten atomically so a half-written set is impossible.

> **Why not the Keychain?** It was the obvious home and it does not work without a paid
> signing identity. The data-protection keychain decides access by entitlement, which needs
> a real team identifier that an ad-hoc build does not have — it answers
> `errSecMissingEntitlement`. The file keychain decides access by an ACL tied to the
> calling code's signature, which changes on every build, so it tries to *ask the user* —
> and an XPC service has no UI to ask with, so it fails with `errSecInteractionNotAllowed`.
> The sealed container is weaker than a data-protection keychain item and much stronger
> than plaintext, and it is the best available without a Developer ID. See
> [ADR 0005](docs/adr/0005-two-factor-helper.md).

### Touch ID, by default

Authentication is **required by default**, because a security default the app can flip on
its own is not a default. Three policies:

- **Always** — every code, every time.
- **After a grace period** — 1, 5, 15, 30 or 60 minutes. The clock is held in memory only,
  so quitting Recall or restarting the helper starts the next code locked. A grace period
  that survived a restart would be one nobody chose.
- **Never** — anyone at the keyboard can read every code.

The choice lives in the helper, not in Recall's settings.

### Adding an account

- **Scan a QR code off your screen.** Drag out the region showing the enrolment QR and
  Recall reads it. No phone involved — the fastest path there is.
- **Copy an `otpauth://` link** and Recall offers to import it, rather than storing a clip
  that mints codes forever. `otpauth-migration://` links exported from Google
  Authenticator work too, including multiple accounts at once.
- **Enter a secret by hand**, for sites that only print the base32.

### Using a code

Codes appear with the seconds remaining. Copy one, or paste it straight into the app you
were in. Codes are held only as long as they are valid, and are dropped from memory when
the panel closes.

### The one thing it will not do

Recall **cannot** expand a shortcode or auto-paste into a password field, and does not try.
macOS turns on **Secure Event Input** there, which blocks the session event tap Recall
listens on. That is the operating system protecting you from exactly the kind of software
Recall is, and it is not bypassable — nor should it be.

---

## Snippets and shortcodes

Give a clip a shortcode — `:sig`, `:addr` — and typing it anywhere expands it. A
listen-only event tap watches for the code, then backspaces it and pastes the snippet,
restoring whatever was on your clipboard afterwards.

Pinning a clip offers to assign a shortcode, as a quiet link rather than a sheet that
interrupts the pin.

---

## Todos

The panel's third tab is a todo list. Type one and press Return; tick it off with Return
again, or with a click. Drag to reorder. Finished todos wait under **Done** until you
clear them.

Press **⌘T** on a clip in History to make it a todo. The todo keeps its own copy of the
text, because history deletes clips on its own schedule and a todo should not vanish
with one. While the clip is still around, **⌘⏎** pastes it straight from the todo. A clip
marked secret cannot become a todo.

Todos are sealed in the same encrypted database as history, and nothing about them is
stored in the clear, not even when they were written. Clearing history never touches
them. In In-Memory Mode they live in RAM and are gone when Recall quits.

---

## Text out of pictures

**⌘⇧⌥2** drags out a region of the screen, Vision reads it, and the text lands on your
clipboard *and* in history. It is backed by `screencapture`, so the selection UI is the one
you already know and the permission prompt is the system's own.

Copied images are OCR'd in the background, and the recognised text is fully searchable —
so a screenshot of an error message is findable by the error.

Language detection is automatic rather than pinned to English.

---

## The rest of it

- **Every format, rendered as what it is** — text, RTF, images, files, links and hex
  colours. Links are enriched with their title and favicon; colours show a swatch.
- **Pins** — the part of history you curate. A pinned clip is *never* removed
  automatically: not by the history limit, not by the retention cutoff, not by secret
  expiry. Where Recall would otherwise delete something, it warns instead.
- **Diff two clips** — ⌘D on one, ⌘D on another, and get a line or word-level diff. Useful
  for two versions of a config, or a paragraph you rewrote.
- **Quick Look** — ⌘Y, the real preview panel.
- **Paste stack** — collect clips with ⌘⌥⌃C and paste them in order.
- **Summaries** for long clips, with a visible "Reading…" state rather than a row that
  silently rewrites itself.
- **Auto-tags** from an on-device model, which feed Smart Collections.
- **Menu-bar app** — no Dock icon. Summon it, use it, it goes away.
- **In your language** — English, Persian (fully right-to-left), Russian and Simplified
  Chinese. Recall follows the system language, or pick one for it alone in **System
  Settings › General › Language & Region**.

---

## Keyboard

| Shortcut | Does |
| --- | --- |
| **⌘⇧V** | Show Recall |
| **⌘⇧A** | Two-factor codes |
| **⌘⇧⌥2** | Capture text from a screen region |
| **⌘⌥V** | Scratchpad |
| **⌘⌥⌃C** | Add to the paste stack |
| ↑ ↓ | Move through history |
| ⇞ ⇟ | Move a page at a time |
| ⌘↑ ⌘↓ | Jump to the first or last item |
| ⏎ | Paste |
| ⇥ | Cycle by kind |
| ⌃⇥ | Next tab: History, Codes, Todos |
| ⌥⏎ | Paste as… |
| ⌘P | Pin |
| ⌘Y | Quick Look |
| ⌘D | Compare two clips |
| ⌘T | Make the clip a todo |
| ⌘1…9 | Paste a numbered slot |
| ⌘⌥1…9 | Assign a clip to a slot |
| ⎋ | Clear the search, or dismiss |
| ⌘, | Settings |

---

## What never leaves your Mac

Every embedding, every summary, every tag and every transformation runs on-device. There
is no account, no telemetry, no analytics and no sync.

The single exception is **link enrichment**, which fetches the title and favicon of a URL
you copied — that is a request to the site in question, and nowhere else. It can be turned
off entirely in Settings, and the setting is wired to the enricher rather than being
decorative.

---

## Install

**Build it from source.** It is one command, and it is the supported path:

```bash
git clone https://github.com/cnazk/recall-mac.git
cd recall-mac
./Scripts/install.sh --build
```

Requires macOS 26 or later. No third-party dependencies.

The old bundle is *deleted* rather than written over: copying onto a live bundle leaves
stale files behind, and this project has lost days to packaging faults that no unit test
can see.

```bash
make test   # the full suite
make app    # build and sign .build/Recall.app
make run    # build and launch
```

> **Why no download?** Recall is signed ad-hoc, not with a Developer ID, because the
> project does not yet have an Apple Developer Program membership. A downloaded build is
> refused by Gatekeeper, and the usual workaround — telling you to strip the quarantine
> flag by hand — is a bad habit to teach for an app that reads your clipboard and asks for
> Accessibility. An ad-hoc signature is also pinned to the build hash, so macOS treats each
> release as a different app and drops the Accessibility grant on every update. Developer
> ID signing fixes both and is the next shipping milestone.

---

## Status

Phases 1–6 are built: trustworthy capture, the panel, search, the AI features, extraction
and workflows, one-time codes, and the polish pass. Phase 7 — shipping — is in progress.

- [docs/PLAN.md](docs/PLAN.md) — what is built, what is next, and the open questions
- [docs/FUTURE.md](docs/FUTURE.md) — candidates behind the plan, and what each needs decided
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the pieces fit
- [docs/adr/](docs/adr/) — the decisions that are expensive to reverse

### Known limits

Stated up front, with what happens next. Two of these are being fixed; two are not ours
to fix, and saying so is more useful than a promise that never lands.

| Limit | Status |
| --- | --- |
| **No download yet** — builds are ad-hoc signed and Gatekeeper refuses them | **Being fixed.** Developer ID signing and notarisation are the next shipping milestone; the release pipeline is already built and waiting for the certificate. |
| **The Accessibility grant is lost on every update** — an ad-hoc signature is pinned to the build hash, so macOS sees each build as a different app | **Fixed by the same change.** A Developer ID signature is stable across versions, and the grant survives. |
| **No Persian OCR** — macOS Vision ships no `fa` recogniser | **Not ours to fix.** Automatic language detection is on, and Arabic-script *search* is folded so Persian text you paste is findable. Recognition waits on Apple. |
| **Shortcodes do not expand in password fields** | **Working as intended.** macOS enables Secure Event Input there, which blocks the event tap Recall listens on. That is the OS protecting you from exactly the class of software Recall is, and Recall will not work around it. |

---

## Support Recall

Recall is free and open source, and it will stay that way. The app itself never asks for money:
there is no donate button, reminder or nag anywhere in it, so nothing gets between you and
your clipboard. If Recall is useful to you and you would like to support its development,
this is the place.

**Coffee Bede** — with an Iranian bank card: [coffeebede.com/cnazk](https://www.coffeebede.com/cnazk)

**Crypto** — copy each address rather than retyping it, and send only on the network named
above it. Coins sent on any other network are lost.

**TRON** — TRX, or TRC-20 tokens such as USDT

```
TLnL9hAHDUPXHioByrwQu656bTv22u3yfC
```

**Ethereum** — ETH, or ERC-20 tokens such as USDT

```
0x658A5337D273A73B3BBF72fD536086BBA7E1BB02
```

**Bitcoin**

```
bc1q8thgzqfg8uakvdfzykkhllq72hdmlwh2v5jtsw
```

**Solana** — SOL, or SPL tokens such as USDT

```
8w1efp2YQ4kv1eFWugXJ3fF3gfNJtcFpjz1jBVmGprgq
```

---

## License

Copyright (C) 2026 Sina Zaker

Recall is free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License as published by the Free Software Foundation, either version 3
of the License, or (at your option) any later version.

Recall is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
See the [GNU General Public License](LICENSE) for more details.
