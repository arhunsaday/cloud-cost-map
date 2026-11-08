#!/bin/bash
# Builds "Cloud Cost Map.app" from the Swift package.
# Usage: scripts/bundle.sh [debug|release]   (default: release)
# Output: build/Cloud Cost Map.app, ad-hoc signed so it runs locally.
#
# Environment:
#   UNIVERSAL=1    arm64 + x86_64 binary (release builds for distribution)
#   VERSION        CFBundleShortVersionString; default: the value in Resources/Info.plist
#   BUILD_NUMBER   CFBundleVersion; default: the value in Resources/Info.plist
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Cloud Cost Map.app"

cd "$ROOT"
ARGS=(-c "$CONFIG" --product CloudCostMap)
[ "${UNIVERSAL:-0}" = 1 ] && ARGS+=(--arch arm64 --arch x86_64)
swift build "${ARGS[@]}"
BIN="$(swift build "${ARGS[@]}" --show-bin-path)/CloudCostMap"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CloudCostMap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

PLIST="$APP/Contents/Info.plist"
[ -n "${VERSION:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
[ -n "${BUILD_NUMBER:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"

# Ad-hoc signature: enough to launch locally. scripts/distribute.sh replaces it
# with a Developer ID signature for sharing.
codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "✓ $APP"
