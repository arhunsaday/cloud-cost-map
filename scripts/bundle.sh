#!/bin/bash
# Builds "Cloud Cost Map.app" from the Swift package.
# Usage: scripts/bundle.sh [debug|release]   (default: release)
# Output: build/Cloud Cost Map.app, ad-hoc signed so it runs locally.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Cloud Cost Map.app"

cd "$ROOT"
swift build -c "$CONFIG" --product CloudCostMap
BIN="$(swift build -c "$CONFIG" --show-bin-path)/CloudCostMap"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CloudCostMap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: enough to launch locally. Distribution needs a Developer ID
# identity and notarization (see README).
codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "✓ $APP"
