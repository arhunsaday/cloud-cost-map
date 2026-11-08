#!/bin/bash
# Turns a built .app into a DMG anyone can download and open: Developer ID
# signature with the hardened runtime, notarization of the app and the DMG,
# tickets stapled to both so the first launch works offline too.
#
#   scripts/distribute.sh path/to/App.app path/to/output.dmg
#
# One-time setup on the Mac (README › Distribution):
#   - a "Developer ID Application" certificate in the login keychain
#   - xcrun notarytool store-credentials notary
#
# Environment:
#   DEVELOPER_ID     identity to sign with; default: the only "Developer ID Application" identity found
#   NOTARY_PROFILE   notarytool keychain profile; default: notary
#   NOTARY_KEYCHAIN  keychain holding that profile (CI); default: the login keychain
#   ENTITLEMENTS     entitlements plist for the app; default: none
#   NOTARIZE=0       sign only, for a quick check; such a DMG is blocked on other Macs
#
# This file is identical in timelet and cloud-cost-map.
set -euo pipefail

usage="usage: distribute.sh <App.app> <output.dmg>"
APP="${1:?$usage}"
DMG="${2:?$usage}"
APP="${APP%/}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"
NOTARIZE="${NOTARIZE:-1}"
NAME="$(basename "$APP" .app)"

[ -d "$APP" ] || { echo "✗ No app at $APP" >&2; exit 1; }

if [ -z "${DEVELOPER_ID:-}" ]; then
  ids="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | sort -u)"
  count="$(printf '%s' "$ids" | grep -c . || true)"
  if [ "$count" = 0 ]; then
    echo "✗ No \"Developer ID Application\" certificate in the keychain. See README › Distribution." >&2
    exit 1
  elif [ "$count" != 1 ]; then
    echo "✗ Several Developer ID identities. Choose one with DEVELOPER_ID=\"…\":" >&2
    echo "$ids" >&2
    exit 1
  fi
  DEVELOPER_ID="$ids"
fi
echo "→ Signing as $DEVELOPER_ID"

notary_args=(--keychain-profile "$NOTARY_PROFILE")
[ -n "${NOTARY_KEYCHAIN:-}" ] && notary_args+=(--keychain "$NOTARY_KEYCHAIN")

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sign() {
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$@"
}

notarize() {
  echo "→ Notarizing $(basename "$1") (usually 1–5 minutes)"
  local out id
  out="$(xcrun notarytool submit "$1" "${notary_args[@]}" --wait 2>&1)" || true
  echo "$out"
  if ! grep -q 'status: Accepted' <<<"$out"; then
    id="$(sed -n 's/^ *id: //p' <<<"$out" | head -1)"
    [ -n "$id" ] && xcrun notarytool log "$id" "${notary_args[@]}" >&2 || true
    echo "✗ Notarization failed" >&2
    exit 1
  fi
}

# 1. App: nested code first (inside-out), then the bundle.
while IFS= read -r -d '' item; do
  sign "$item"
done < <(find "$APP/Contents" -depth \( -name '*.dylib' -o -name '*.framework' -o -name '*.bundle' \
  -o -name '*.appex' -o -name '*.xpc' -o -name '*.app' \) -print0)

if [ -n "${ENTITLEMENTS:-}" ]; then
  sign --entitlements "$ENTITLEMENTS" "$APP"
else
  sign "$APP"
fi
codesign --verify --strict --deep --verbose=2 "$APP"

if [ "$NOTARIZE" != 0 ]; then
  ditto -c -k --keepParent "$APP" "$WORK/$NAME.zip"
  notarize "$WORK/$NAME.zip"
  xcrun stapler staple "$APP"
fi

# 2. DMG: the app next to a link to /Applications.
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"

# hdiutil sometimes fails with "Resource busy" on CI runners; a retry fixes it.
for attempt in 1 2 3; do
  if hdiutil create -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null; then
    break
  fi
  [ "$attempt" = 3 ] && { echo "✗ hdiutil failed" >&2; exit 1; }
  sleep 5
done

codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"

if [ "$NOTARIZE" != 0 ]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  spctl --assess --type execute --verbose=2 "$APP"
else
  echo "⚠ NOTARIZE=0: signed but not notarized, other Macs will block this DMG"
fi

echo "✓ $DMG"
echo "  SHA-256 $(shasum -a 256 "$DMG" | awk '{print $1}')"
