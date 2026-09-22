# Recall

A local-first, AI-integrated clipboard manager for macOS.

Recall remembers everything you copy, lets you search it by *meaning* rather than by the
exact words, and treats anything that looks like a credential as radioactive.

![Recall's history panel: searching for "rounding" surfaces a CSS border-radius snippet that never contains the word](docs/demo.gif)

Searching for **rounding** finds the `border-radius` snippet — a word that appears nowhere
in it.

- **Multi-format** — text, RTF, images, files, links and hex colours, each rendered as
  what it is.
- **Semantic search** — look for "CSS rounding", find the `border-radius` snippet.
- **Paste as…** — run a clip through an on-device model before it lands: Markdown table,
  translation, summary, JSON, Python.
- **Secrets self-destruct** — 2FA codes, card numbers and API keys are detected on
  capture and deleted after 60 seconds.
- **Never captures from your password manager** — 1Password, Bitwarden, Keychain and
  authenticators are excluded out of the box.
- **In-Memory Mode** — run entirely in RAM; quitting erases everything.
- **Nothing leaves your Mac** — every embedding and transformation is on-device.

## Build

Requires macOS 26+ and Xcode 27 (Swift 6). No third-party dependencies.

```bash
./Scripts/install.sh --build
```

Builds the bundle and installs it into `/Applications`. The old copy is deleted rather
than written over: copying onto a live bundle leaves stale files behind, and this project
has lost days to packaging faults that no unit test can see (PLAN §7.5, §7.8).

```bash
make test   # run the suite
make app    # build and sign .build/Recall.app
make run    # build and launch
```

Recall is a menu-bar app: no Dock icon.

## Documentation

- [docs/PLAN.md](docs/PLAN.md) — what is built, what is next, and the open questions
- [docs/FUTURE.md](docs/FUTURE.md) — candidates behind the plan, and what each needs decided
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the pieces fit
- [docs/adr/](docs/adr/) — the decisions that are expensive to reverse

## License

Copyright (C) 2026 Sina Zaker

Recall is free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License as published by the Free Software Foundation, either version 3
of the License, or (at your option) any later version.

Recall is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
See the [GNU General Public License](LICENSE) for more details.
