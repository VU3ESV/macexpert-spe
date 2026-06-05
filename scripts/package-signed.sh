#!/usr/bin/env bash
# Build MacExpert.app with the MacExpertExtension ExtensionKit extension EMBEDDED and
# Developer-ID signed, then build the .zip + .dmg and (when notary creds are present)
# notarize + staple them.
#
# This is what makes an installed app register its extension for the Amateur Radio Suite to
# host out-of-process — an ad-hoc-signed extension will NOT register on another Mac. Used by
# the release workflow; also runnable locally.
#
# Signing is GATED on secrets — with none set it falls back to ad-hoc so the build still
# succeeds (but an ad-hoc app's extension will NOT register on another Mac).
#
#   VERSION=0.1.1 scripts/package-signed.sh
#
# Env — signing (from CI secrets):
#   MACOS_CERT_P12_BASE64   base64 of the MacExpert Developer ID Application .p12 (cert + key)
#   MACOS_CERT_PASSWORD     the .p12 export password
#   KEYCHAIN_PASSWORD       password for the temp keychain (any value)
# Env — notarization (optional; needs the signing cert too):
#   NOTARY_APPLE_ID         Apple ID email
#   NOTARY_TEAM_ID          team id (Y6FT52BKDA)
#   NOTARY_PASSWORD         app-specific password for that Apple ID
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"
# build-app.sh writes MacExpert.app next to the repo checkout (one level up).
APP="$(cd .. && pwd)/MacExpert.app"
APPEX_NAME="MacExpertExtension.appex"
ENTITLEMENTS="Xcode/Extension/MacExpert.entitlements"
PROJECT="Xcode/MacExpertPlugin.xcodeproj"
SCHEME="MacExpertExtension"
DIST="dist"
ZIP="$DIST/MacExpert-${VERSION}-macOS.zip"
DMG="$DIST/MacExpert-${VERSION}-macOS.dmg"
TMP="${RUNNER_TEMP:-$(mktemp -d)}"
# SwiftPM's bare-repo cache trips a common global git setting under xcodebuild.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all

echo "==> Building standalone universal app"
# SKIP_SIGN=1: build-app.sh writes the bundle + Info.plist but does NOT sign — we embed the
# .appex below and sign the whole thing inside-out (with entitlements) + notarize ourselves.
SKIP_SIGN=1 ./build-app.sh
[ -d "$APP" ] || { echo "ERROR: $APP not found after build-app.sh"; exit 1; }

echo "==> Building the extension (.appex)"
( cd Xcode && xcodegen generate >/dev/null )
DERIVED="$(mktemp -d)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build >/dev/null
APPEX="$(find "$DERIVED/Build/Products" -name "$APPEX_NAME" | head -1)"
[ -n "$APPEX" ] || { echo "ERROR: $APPEX_NAME not found"; exit 1; }

echo "==> Embedding $APPEX_NAME under Contents/Extensions/"
mkdir -p "$APP/Contents/Extensions"
rm -rf "$APP/Contents/Extensions/$APPEX_NAME"
cp -R "$APPEX" "$APP/Contents/Extensions/"
rm -rf "$DERIVED"

# --- import the signing cert into a throwaway keychain (CI) -----------------------------
IDENTITY=""
if [ -n "${MACOS_CERT_P12_BASE64:-}" ]; then
  echo "==> Importing Developer ID certificate into a temporary keychain"
  KC="$TMP/ars-signing.keychain-db"
  KCPW="${KEYCHAIN_PASSWORD:-ars-ci-temp}"
  security create-keychain -p "$KCPW" "$KC"
  security set-keychain-settings -lut 21600 "$KC"
  security unlock-keychain -p "$KCPW" "$KC"
  echo "$MACOS_CERT_P12_BASE64" | base64 --decode > "$TMP/cert.p12"
  security import "$TMP/cert.p12" -k "$KC" -P "${MACOS_CERT_PASSWORD:-}" -T /usr/bin/codesign
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPW" "$KC" >/dev/null
  # Make the temp keychain searchable (keep the existing ones too).
  security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
  rm -f "$TMP/cert.p12"
  # In the fresh keychain there is exactly one Developer ID identity, so name-selection is unambiguous.
  IDENTITY="$(security find-identity -v -p codesigning "$KC" | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi

# codesign with a few retries — Apple's secure-timestamp service is intermittently unavailable
# ("The timestamp service is not available."), which would otherwise fail the whole release.
cs() {
  local n=1
  until codesign "$@"; do
    [ "$n" -ge 4 ] && return 1
    echo "  codesign attempt $n failed — retrying in 15s…" >&2; sleep 15; n=$((n + 1))
  done
}

# --- sign inside-out (extension first, then the app) ------------------------------------
if [ -n "$IDENTITY" ]; then
  echo "==> Signing with: $IDENTITY"
  cs --force -s "$IDENTITY" -o runtime --timestamp \
    --entitlements "$ENTITLEMENTS" "$APP/Contents/Extensions/$APPEX_NAME"
  cs --force -s "$IDENTITY" -o runtime --timestamp "$APP"
else
  echo "==> WARNING: no MACOS_CERT_P12_BASE64 — ad-hoc signing (extension will NOT register on other Macs)"
  codesign --force -s - "$APP/Contents/Extensions/$APPEX_NAME"
  codesign --force -s - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

# --- helper: submit to the notary service ----------------------------------------------
notarize() {  # $1 = path to a .zip or .dmg to submit
  xcrun notarytool submit "$1" \
    --apple-id "$NOTARY_APPLE_ID" --team-id "${NOTARY_TEAM_ID:-}" --password "$NOTARY_PASSWORD" --wait
}
HAVE_NOTARY=0
if [ -n "$IDENTITY" ] && [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
  HAVE_NOTARY=1
fi

# Notarize the APP and staple it first, so the bundle carries its ticket even offline and
# once copied out of the DMG (not just while the DMG is mounted).
if [ "$HAVE_NOTARY" = 1 ]; then
  echo "==> Notarizing the app + stapling (a few minutes)…"
  AZIP="$(mktemp -d)/app.zip"
  ditto -c -k --keepParent "$APP" "$AZIP"
  notarize "$AZIP"
  xcrun stapler staple "$APP"
fi

echo "==> Building distributables (.zip + .dmg)"
mkdir -p "$DIST"
rm -f "$ZIP" "$DMG"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
hdiutil create -volname "MacExpert" -srcfolder "$APP" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null

# Codesign the DMG container too (so `spctl -t open` accepts it and it mounts without a
# Gatekeeper prompt), then notarize + staple the DMG itself.
if [ -n "$IDENTITY" ]; then
  echo "==> Codesigning the DMG"
  cs --force -s "$IDENTITY" --timestamp "$DMG"
fi
if [ "$HAVE_NOTARY" = 1 ]; then
  echo "==> Notarizing the DMG + stapling (a few minutes)…"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  echo "==> Notarized + stapled (app + DMG)."
else
  echo "==> Skipping notarization (no NOTARY_* secrets) — signed but not notarized."
fi
echo "==> Done: $ZIP and $DMG"
