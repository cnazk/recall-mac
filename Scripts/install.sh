#!/usr/bin/env bash
# Installs Recall.app into /Applications, cleanly.
#
# The old bundle is *deleted* rather than copied over. Copying over a live bundle leaves
# stale files behind — a resource bundle that moved, a previous XPC helper, an old
# signature — and the app then fails in ways that look like code bugs. This project has
# already lost days to packaging faults that unit tests cannot see (PLAN §7.5, §7.8), so
# the install step is not allowed to be a source of new ones.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILT="$ROOT/.build/Recall.app"
DEST="/Applications/Recall.app"

if [ "${1:-}" = "--build" ]; then
	"$ROOT/Scripts/bundle.sh"
fi

[ -d "$BUILT" ] || { echo "No bundle at $BUILT — run Scripts/bundle.sh first." >&2; exit 1; }

echo "==> Quitting any running copy"
osascript -e 'tell application "Recall" to quit' 2>/dev/null || true
sleep 1
pkill -f "Recall.app/Contents/MacOS/Recall" 2>/dev/null || true
pkill -f "com.recall.otp" 2>/dev/null || true
sleep 1
pkill -9 -f "Recall.app/Contents/MacOS/Recall" 2>/dev/null || true

echo "==> Removing $DEST"
rm -rf "$DEST"

echo "==> Installing"
cp -R "$BUILT" "$DEST"
# The quarantine flag is for downloads; a bundle built on this machine has not been
# anywhere, and leaving it set makes Gatekeeper prompt about our own build.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "==> Verifying signature"
codesign --verify --strict "$DEST"

if [ "${1:-}" = "--no-launch" ] || [ "${2:-}" = "--no-launch" ]; then
	echo "==> Installed $DEST (not launched)"
	exit 0
fi

echo "==> Launching"
open -a "$DEST" ${RECALL_ARGS:+--args $RECALL_ARGS}
echo "==> Installed and launched $DEST"
