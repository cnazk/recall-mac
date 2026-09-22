#!/usr/bin/env bash
# Assembles Recall.app from the SwiftPM executable.
#
# SwiftPM builds a bare Mach-O; macOS needs a bundle for LSUIElement, entitlements and
# the Accessibility/permission prompts to behave. Until the project moves to an Xcode
# target, this script is the app build.
set -euo pipefail

CONFIGURATION="${CONFIGURATION:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build/$CONFIGURATION"
APP="$ROOT/.build/Recall.app"

echo "==> Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product recall-app
swift build -c "$CONFIGURATION" --product recall-otp-service

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/recall-app" "$APP/Contents/MacOS/Recall"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# SwiftPM emits a resource bundle per target that has resources. Missing one is not a
# cosmetic problem: it used to take the whole app down at launch.
for resource_bundle in "$BUILD_DIR"/*.bundle; do
	[ -e "$resource_bundle" ] || continue
	echo "==> Bundling $(basename "$resource_bundle")"
	cp -R "$resource_bundle" "$APP/Contents/Resources/"
done

# The two-factor helper: a sandboxed XPC service inside the app. Seeds live in this
# process and nowhere else, so it is built and signed separately, with its own — far
# narrower — entitlements.
HELPER="$APP/Contents/XPCServices/com.recall.otp.xpc"
mkdir -p "$HELPER/Contents/MacOS"
cp "$BUILD_DIR/recall-otp-service" "$HELPER/Contents/MacOS/com.recall.otp"
cp "$ROOT/Resources/OTPHelper-Info.plist" "$HELPER/Contents/Info.plist"

echo "==> Signing helper (ad-hoc, sandboxed)"
codesign --force --sign - \
	--identifier com.recall.otp \
	--entitlements "$ROOT/Resources/OTPHelper.entitlements" \
	--options runtime \
	"$HELPER"

# Ad-hoc signature with a stable identifier, so macOS remembers the Accessibility grant
# across rebuilds instead of re-prompting every run.
echo "==> Signing (ad-hoc)"
codesign --force --sign - \
	--identifier com.recall.app \
	--entitlements "$ROOT/Resources/Recall.entitlements" \
	--options runtime \
	"$APP"

echo "==> Built $APP"
