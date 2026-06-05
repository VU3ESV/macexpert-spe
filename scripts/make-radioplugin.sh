#!/bin/bash
# Build MacExpertExtension.appex and package it as `MacExpert.radioplugin` -- the installable
# bundle the Amateur Radio Suite browses + installs (zip of plugin.json + the .appex).
#
#   scripts/make-radioplugin.sh              # -> dist/MacExpert.radioplugin (+ its sha256)
#
# The .appex recompiles the app's own sources (see Xcode/project.yml); the standalone app and
# Package.swift are untouched. Running the installed plugin needs Developer-ID signing +
# extension approval; this produces an ad-hoc-signed package for the catalog/discovery flow.
set -euo pipefail
cd "$(dirname "$0")/.."

XCODE_DIR="Xcode"
PROJECT="$XCODE_DIR/MacExpertPlugin.xcodeproj"
SCHEME="MacExpertExtension"
DIST="dist"
PKG="$DIST/MacExpert.radioplugin"

# SwiftPM's bare-repo cache trips `safe.bareRepository=explicit` (a common global git
# setting) under xcodebuild; allow it for child git processes without touching config.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all

echo "==> Generating Xcode project from project.yml"
( cd "$XCODE_DIR" && xcodegen generate )

echo "==> Building $SCHEME (.appex)"
DERIVED="$(mktemp -d)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO build >/dev/null

APPEX="$(/usr/bin/find "$DERIVED/Build/Products" -name 'MacExpertExtension.appex' -maxdepth 3 | head -1)"
[ -n "$APPEX" ] || { echo "ERROR: MacExpertExtension.appex not found"; exit 1; }

echo "==> Assembling $PKG"
STAGE="$(mktemp -d)"
cp "Xcode/Extension/plugin.json" "$STAGE/plugin.json"
cp -R "$APPEX" "$STAGE/"

# Only manage our own package -- do NOT wipe $DIST.
mkdir -p "$DIST"
rm -f "$PKG"
PKG_ABS="$PWD/$PKG"
( cd "$STAGE" && ditto -c -k --norsrc --noextattr . "$PKG_ABS" )
rm -rf "$STAGE" "$DERIVED"

SHA="$(shasum -a 256 "$PKG" | awk '{print $1}')"
echo "OK: built $PKG"
echo "    sha256: $SHA"
