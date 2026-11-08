#!/bin/bash
# Builds a Cloud Cost Map DMG ready to share: universal release bundle, then
# scripts/distribute.sh (Developer ID signature, notarization, DMG).
#
#   scripts/release.sh [version]      e.g. scripts/release.sh 1.0.0
#
# Version defaults to CFBundleShortVersionString in Resources/Info.plist, build
# number to the commit count (override with BUILD_NUMBER=…).
# Output: dist/Cloud-Cost-Map-<version>.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
export VERSION BUILD_NUMBER

echo "→ Cloud Cost Map $VERSION ($BUILD_NUMBER)"
UNIVERSAL=1 scripts/bundle.sh release
scripts/distribute.sh "build/Cloud Cost Map.app" "dist/Cloud-Cost-Map-$VERSION.dmg"
