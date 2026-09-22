# Future Features

Candidates that are **not** in the phased plan and **not** built. [PLAN.md](PLAN.md) is
the commitment; this is the queue behind it.

Each entry says what the feature is, why it earns its place, what it leans on that already
exists, and what has to be decided before it can be built. Anything marked **Undecided**
should not be started until that question is answered — building it first is how a
feature ends up with the wrong shape baked in.

| Feature | Leans on | Effort | Status |
| --- | --- | --- | --- |
| [Paste stack](#1-paste-stack) | `PasteService`, panel | Medium | **Built** — behind a setting |
| [Auto-clean copied code](#2-auto-clean-copied-code) | `TextNormalizer` | Small | Ready to build |
| [Per-app rules](#3-per-app-rules) | `AppExclusionPolicy`, settings | Medium | Ready to build |
| [Quick Look](#4-quick-look) | Panel, `BlobStore` | Small | **Built** |
| [Shortcuts actions and a CLI](#5-shortcutsapp-actions-and-a-recall-cli) | `HistoryStore`, `PasteService` | Medium–Large | One decision open |
| [Diff two clips](#6-diff-two-clips) | Panel selection | Small | Ready to build |
| [Pause capture](#7-pause-capture) | `PasteboardMonitor` | Small | **Built** |
| [Profiles](#8-profiles) | `HistoryStore`, `KeyStore`, ADR 0004 | Large | Decided — ready to build |
| [More detector formats](#9-more-formats-for-secretdetector) | `SecretRule` | Small each | **Built** — every rule toggleable |

---

## 1. Paste stack

Copy three things in a row, then paste them one after another in order, without going back
to the panel between each one. The feature people who have lived with Emacs' kill-ring
miss in every other clipboard manager.

**Leans on:** `PasteService` already owns writing and the synthetic ⌘V, and
`PasteboardMonitor.ignoreNextChange` already stops Recall re-capturing its own writes. The
stack itself is a small amount of state on top.

### Settled, and built

Off by default, behind **Settings → General → "Paste several items in order"**. With it on:

- **⌃⌥⌘C queues** the last thing copied; the panel's context menu queues the selected item.
  Only explicit adds go on the stack, so a stray copy never displaces what was queued.
- **⌃⌥⌘V pastes** the next one and removes it. First in, first out.
- **⌘V is never touched.** No event tap, and nothing surprising happens to the shortcut
  every other app relies on — which is why the "Recall intercepts ⌘V" option was dropped.
- **A HUD shows what is next** and how many remain, appearing with the stack and vanishing
  when it drains.
- **It expires after ten idle minutes**, checked on every access rather than only on a
  timer, so a stale queue can never fire a paste from twenty minutes ago.
- **Credentials are never queued.** A `.secret` item is refused, the same way it is refused
  by the transforms.

Re-queuing something already in the stack moves it to the back rather than duplicating it,
and the stack holds at most 24 items.

---

## 2. Auto-clean copied code

Strip the things that come along when you copy code out of a terminal, a blog post or a
diff: `$ ` and `>>> ` prompts, leading line numbers, `+`/`-` diff markers, and the soft
wrapping documentation sites insert.

**Leans on:** `TextNormalizer`, which already exists, already runs on the capture path, and
already has the rule that it only removes characters the user did not mean to copy.

**Notes**

- It must be reversible in the UI: the row shows "cleaned", and the detail pane offers the
  original. Silently altering what someone copied is the one thing a clipboard manager
  must not do.
- It should only fire when the clip looks like code or terminal output — every line
  prefixed the same way, or a fenced block. A paragraph of prose that happens to start
  with `$` is prose.
- Line-number stripping needs a guard: `1. First item` is a list, not line one.

---

## 3. Per-app rules

Rules keyed on the app a clip came from, or the app being pasted into:

- Always paste plain text into this app (Slack, Mail).
- Never capture from this app (extends today's exclusions with the user's own list, which
  already exists — this makes it a first-class rule rather than a bundle-ID field).
- Auto-tag anything from this app (`Xcode` → `#code`).
- Always use this transform when pasting here.

**Leans on:** `AppExclusionPolicy`, `SourceApp` on every item, `SmartCollection` (rules are
the same shape as a collection's conditions).

**Notes**

- Paste-side rules need to know the destination app, which is `NSWorkspace.frontmostApplication`
  at paste time — already captured by `PanelController.previousApplication`.
- The rules editor is the hard part, not the rules. Keep it to a list of
  *when → then* rows, not a query builder.

---

## 4. Quick Look

Space bar on the selected item opens the system preview, like Finder. Images, PDFs and
files preview natively; text gets a large plain-text panel.

**Leans on:** the panel's existing selection, and `BlobStore` for the full-size bytes of an
offloaded image.

**Built.** Space previews the selection; ⌘Y does the same for when the search field is in
use, since space has to type a space there — the same compromise the delete binding makes.
Also on the context menu, in the panel and the scratchpad.

- Files preview where they already are. Nothing is written.
- Everything else is staged in a per-preview directory at `0700` with the file at `0600`,
  and the whole directory is deleted when the panel closes, when the next preview replaces
  it, and at quit. A staged copy that outlives its preview is a hole straight through
  encryption at rest.
- Filenames are derived from the content but stripped of anything that could escape the
  directory they are written into.
- A `.secret` item is refused outright — including a sensitive *file*, which would have
  written nothing but would still have shown the contents.
- `QLPreviewPanel` asks the responder chain who owns it, and a plain `NSHostingView`
  answers no, which opens an empty panel. Both windows now use a hosting view that
  answers yes.

---

## 5. Shortcuts.app actions and a `recall` CLI

Expose the store to automation: search history, fetch the *n*th item, paste an item,
expand a snippet, add a two-factor account. Shortcuts actions cover the graphical route;
a `recall` binary covers the scripting one (`recall search "border-radius" --json`).

**Leans on:** `HistoryStore` and `PasteService` are already actors with clean APIs. The CLI
is a thin front end over the same package.

### Decision open

**How does a second process read an encrypted history?** The database is sealed under a
Keychain key bound to the app's code signature (ADR 0004), and the CLI is a different
binary. Either:

- The CLI talks to the running app over XPC and holds no key of its own — consistent with
  [ADR 0005](adr/0005-two-factor-helper.md), and it means automation inherits whatever the
  app's state is (including a locked profile), or
- The CLI gets its own Keychain access, which doubles the number of things that can read
  your clipboard history.

The first is almost certainly right. It also means `recall` does nothing when Recall is not
running, which is a real limitation worth naming up front.

---

## 6. Diff two clips

Select two items, see what changed. Copy a config before and after, a JSON response before
and after, two versions of a paragraph.

**Leans on:** multi-selection in the panel — the only genuinely new UI is the diff view.

### Built

- **⌘D marks a clip, ⌘D on another opens the diff.** Multi-selection in the list turned
  out not to be needed, and adding it would have meant reworking click-to-select /
  click-again-to-paste, which is load-bearing. A marked clip shows a banner saying what
  to do next; Escape backs out of the comparison before it closes the panel.
- **The context menu offers "Compare with <the other one>"** when a different clip is
  already selected or marked, so the feature is findable without knowing the shortcut.
- **Word-level for prose, line-level for code**, chosen by `TextDiff.granularity`. Two
  single-line clips are compared by word; anything indented or closing on a brace or
  semicolon is compared by line; long wrapped paragraphs go back to words, because a line
  diff there marks a whole paragraph changed over one corrected word.
- **Built on `CollectionDifference`** — Myers in the standard library. The unchanged runs
  it leaves out are reconstructed, because context is what makes a diff readable.
- **"Copy the Diff" and "Copy the Newer Version"**, as called for below.
- **Secrets are never comparable.** A diff prints the parts that did not change, which for
  a credential is most of it. Images compare by their recognised text, so two screenshots
  of the same document diff as documents.

**Notes**

- A diff is always read older-to-newer regardless of which clip was picked first, or
  picking them in the other order would invert every sign.

---

## 7. Pause capture

Stop recording for fifteen minutes, an hour, or until turned back on. The menu bar icon
changes while paused, so the state is never ambiguous.

### Built

- **Menu bar → Pause Capture**, with the three durations. While paused the menu says so in
  words ("Paused — resumes in 14 minutes") and offers **Resume Capture**.
- **The icon changes shape**, not just its fill: `pause.circle` rather than the clipboard.
  A different fill is not legible at 16pt, and the icon is the only signal when the menu
  is shut.
- **⌥⇧⌘P toggles it**, for the moment just before copying something you would rather
  Recall did not keep. Pausing from the shortcut is open-ended; the durations are a menu
  affordance.
- **The panel carries a banner** while paused, with its own Resume button — the panel is
  where you would first notice history has stopped growing.
- **Nothing is persisted.** Every launch starts recording. A clipboard manager that
  silently stopped recording three days ago is a bug report, not a feature.

**What building it turned up**

`PasteboardMonitor.stop()` was *not* enough, which is what the entry assumed. The monitor
tracks the pasteboard's change count, and a stopped monitor stops updating it — so the
first poll after resuming sees a change count it has never seen and captures whatever is
on the clipboard *right then*. Pausing, copying a password, and resuming would have
recorded the password: strictly worse than not having the feature. `resume()` therefore
re-baselines the change count before restarting. `PipelineIntegrationTests` covers it, and
the test was checked against the unfixed code to be sure it actually fails.

The timer is torn down rather than short-circuited inside `poll`, so a paused Recall is not
reading the pasteboard at all. "Paused" should mean the app is not looking, not that it
looks and discards.

Region capture (⌥⇧⌘2) still puts its text on the clipboard while paused — it is an
explicit request — but writes nothing to history, so the icon never claims one thing while
the app does another.

---

## 8. Profiles

Several separate clipboard histories, switched between — *Work*, *Personal*, *Client X* —
with some of them **locked** until unlocked deliberately.

This is the largest idea here and the most interesting, because Recall's encryption already
does most of the work.

**Shape**

- A profile is its own database file, its own blob directory, and **its own encryption
  key**. Not a tag or a filter over one store — a separate store, so "locked" means
  genuinely unreadable rather than hidden.
- One profile is active. Capture goes to the active profile only; there is no mirroring,
  because a clip landing in two histories is exactly the confusion profiles exist to
  prevent.
- A locked profile's key is not in memory. Unlocking asks for Touch ID (the same
  `LocalAuthentication` path the two-factor helper already uses) and holds the key for a
  configurable window.
- Pins, snippets and collections are per-profile. Two-factor accounts are not — they live
  in the helper and are global.

**Leans on:** `HistoryStore` is already a protocol with two implementations, so a third
arrangement (several stores, one active) is a composition change rather than a rewrite.
`KeychainKeyStore` already takes a service and account, so per-profile keys are a
parameter, not new machinery.

### Decisions, settled

1. **Search crosses unlocked profiles**, and every result from another profile is marked
   as such in the row — the profile's name on the item, not a subtle tint, because the
   failure this guards against is pasting a personal clipping into a work document without
   noticing. Locked profiles are never searched: their keys are not in memory, so there is
   nothing to search. The behaviour is a setting (**"Search other unlocked profiles"**) so
   anyone who wants hard separation can have it.
2. **An unlocked profile re-locks on profile switch and on quit.** Switching away is the
   moment the user has finished with that context, and quitting is the moment "locked"
   has to mean locked. Neither is configurable: a lock with an exception is a preference,
   not a lock.

The remaining open questions are ergonomic rather than architectural: the switching
shortcut (⌃⌘1…9 is the obvious shape), whether In-Memory becomes a per-profile setting
(it probably should — a *Scratch* profile is better than today's global switch), and how
the menu bar shows which profile is active (a one-letter badge is likely enough, and it
has to be shown, or people will paste into the wrong context and blame the app).

**Also needs answering before building**

- Does switching profiles need a shortcut (⌃⌘1…9), a menu, or both?
- What happens to an In-Memory profile — is "temporary" a per-profile setting rather than
  a global one? (It probably should be: a *Scratch* profile that never touches disk is a
  better version of today's global switch.)
- Does the menu bar icon show which profile is active? It has to, or people will paste into
  the wrong context and blame the app. A one-letter badge is likely enough.

---

## 9. More formats for `SecretDetector`

**Built.** The detector now carries 26 rules, and every one can be switched off
individually in **Settings → Privacy → "What counts as sensitive"**, where each shows a
plain-language summary of what it matches. The disabled set is what is stored, not the
enabled set, so a rule added in a later version is on by default — a detector that quietly
stops covering new formats is worse than useless.

Two rules earn their place by being *checked* rather than pattern-matched:

- **Recovery phrases** validate against the official 2,048-word BIP-39 list **and** verify
  the phrase's own checksum, so they effectively cannot fire on prose. Twelve real words
  in the wrong order are correctly ignored. This matters more than the rest combined: a
  seed phrase is the one secret here whose loss is total and unrecoverable.
- **IBANs** are validated with the standard's mod-97 check, so a mistyped one is ignored
  rather than flagged.

**National identifiers** fire only when labelled (`SSN: …`), since nine digits on their
own is an order number as often as it is a person.

The original list of candidates follows, for reference.

**High confidence, unmistakable shape — safe to add now**

| Format | Pattern |
| --- | --- |
| Stripe | `sk_live_`, `rk_live_`, `pk_live_` + 24+ chars |
| Slack | `xox[baprs]-` + digits and hyphens |
| GitLab | `glpat-` + 20 |
| Google API | `AIza` + 35 |
| Hugging Face | `hf_` + 34 |
| Anthropic | `sk-ant-` + long tail |
| npm | `npm_` + 36 |
| Twilio | `SK` + 32 hex, or `AC` + 32 hex |
| SendGrid | `SG.` + two base64 segments |
| Discord bot | base64 id `.` 6 chars `.` 27 chars |
| Telegram bot | digits `:` 35 alphanumerics |
| Cloudflare | `v1.0-` + long hex |
| OpenSSH private key | `-----BEGIN OPENSSH PRIVATE KEY-----` |
| Apple app-specific password | `xxxx-xxxx-xxxx-xxxx`, lowercase letters only |
| Basic-auth URL | `scheme://user:password@host` |
| Database URL | `postgres://`, `mysql://`, `mongodb+srv://` with a password segment |
| `.env` blob | three or more `KEY=value` lines where a key matches `SECRET|TOKEN|PASSWORD|KEY` |
| Kubernetes config | `apiVersion: v1` with `client-key-data:` or `token:` |
| BIP-39 seed phrase | 12 or 24 words **all present in the BIP-39 wordlist** — the wordlist check is what makes this safe, and losing a wallet to a clipboard leak is as bad as it gets |

**Worth having, but need care**

- **IBAN** — has a checksum (mod-97), so it can be validated like the card rule rather
  than guessed at. Safe once checksummed.
- **US SSN / UK NI number** — shape alone is noisy; require a nearby label ("SSN", "NI")
  to fire.
- **Private keys in JSON** — Google service-account files contain `"private_key": "-----BEGIN`,
  which the PEM rule already catches; the JSON wrapper only matters for the label.

**Deliberately not**

- Email addresses and phone numbers. People copy these constantly on purpose; auto-expiring
  them would make the app useless. They belong in *redaction* (an explicit "Paste redacted"
  action) rather than in detection.

---

## Sequencing, if it were mine

1. **Pause capture** and **auto-clean code** — small, and both improve the app the day
   they ship.
2. **Paste stack**, once its shape is settled.
3. **Per-app rules** and **Quick Look**.
4. **Profiles** — the biggest, and the one that would most change what Recall *is*. Worth
   doing after Phase 7, when the surface has stopped moving.
5. **Shortcuts and the CLI** — best built once profiles exist, or the automation API will
   need reshaping around them a release later.
