#!/usr/bin/env bash
# Keeps Resources/Localizable.xcstrings in step with the source.
#
# The compiler already knows every localizable string — each `Text("…")`, each
# `String(localized: "…")` — and will write them out if asked. This asks, the same way
# Xcode does, and merges the result into the catalog with Apple's own tool. Nothing here
# guesses at strings by pattern-matching source text.
#
#   Scripts/strings.sh          add new strings to the catalog, mark removed ones stale
#   Scripts/strings.sh --check  fail if the source uses a string the catalog lacks
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$ROOT/Resources/Localizable.xcstrings"
# A build directory of its own: the extra compiler flag changes every module's build
# settings, and sharing .build would throw away the ordinary incremental build each time.
BUILD="$ROOT/.build/strings"
EXTRACTED="$BUILD/stringsdata"

# From clean every time. An incremental build only recompiles changed files, and only a
# recompiled file emits its strings — anything unchanged would silently go missing.
rm -rf "$BUILD"
mkdir -p "$EXTRACTED"

echo "==> Extracting strings"
swift build --build-path "$BUILD/build" \
	-Xswiftc -emit-localized-strings \
	-Xswiftc -emit-localized-strings-path -Xswiftc "$EXTRACTED" \
	>"$BUILD/build.log" 2>&1 || { cat "$BUILD/build.log"; exit 1; }

if [ "${1:-}" = "--check" ]; then
	# Compared by key rather than by diffing the file: Xcode versions disagree on the
	# catalog's formatting, and CI does not run the version this is developed on.
	python3 - "$CATALOG" "$EXTRACTED" <<'EOF'
import json, pathlib, sys
catalog = set(json.load(open(sys.argv[1]))["strings"])
used = set()
for path in pathlib.Path(sys.argv[2]).glob("*.stringsdata"):
    for entries in json.load(open(path))["tables"].values():
        used.update(entry["key"] for entry in entries)
missing = sorted(used - catalog)
if missing:
    print(f"{len(missing)} string(s) used in the source are missing from the catalog:")
    for key in missing:
        print(f"  {key!r}")
    print("Run Scripts/strings.sh, then translate them.")
    sys.exit(1)
print(f"All {len(used)} strings are in the catalog.")
EOF
	exit 0
fi

echo "==> Syncing $CATALOG"
args=()
for file in "$EXTRACTED"/*.stringsdata; do
	args+=(--stringsdata "$file")
done
xcrun xcstringstool sync "$CATALOG" "${args[@]}"
echo "==> Done. New strings need translating before they ship."
