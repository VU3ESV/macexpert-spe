#!/bin/bash
# Build, sign, notarize, and (optionally) publish a MacExpert release.
#
# Single source of truth for releases — the GitHub Actions release
# workflow was deleted 2026-06-28 because it could only ever produce
# ad-hoc-signed artifacts (the signing-cert secrets were never set on
# the repo, and pushing them was a worse tradeoff than just releasing
# locally). This script now does the full flow that the CI workflow
# used to do (build + embed the ExtensionKit plugin, sign inside-out
# with Developer ID + hardened runtime + secure timestamp, notarize +
# staple the .app and the .dmg, package the .radioplugin) entirely
# against the local keychain.
#
# Usage:
#   ./release.sh                                # build + sign + zip/dmg/plugin → dist/
#   ./release.sh --notarize                     # also Apple-notarize + staple
#   ./release.sh --tag vX.Y.Z                   # also git-tag the current commit
#   ./release.sh --tag vX.Y.Z --push            # tag + push + GitHub release
#   ./release.sh --tag vX.Y.Z --push --notarize # full release flow
#
# Output (universal arm64+x86_64, signed with Developer ID Application):
#   dist/MacExpert-<version>-macOS.zip          # the .app
#   dist/MacExpert-<version>-macOS.dmg          # mountable DMG
#   dist/MacExpert-<version>.radioplugin        # Amateur Radio Suite plugin
#   dist/SHA256SUMS                             # checksums for all three
#
# Apple-notarized + stapled (with --notarize) so first-launch on a
# fresh Mac doesn't show the Gatekeeper "unidentified developer" prompt
# and the embedded extension registers in the Amateur Radio Suite on
# other Macs.
#
# --notarize requires a one-time stored credential profile named
# "MacExpert-Notary" in your keychain:
#   xcrun notarytool store-credentials "MacExpert-Notary" \
#     --apple-id YOUR_APPLE_ID --team-id CHVNJ85C9F \
#     --password YOUR_APP_SPECIFIC_PASSWORD
# (App-specific password from https://account.apple.com/account/manage)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$SCRIPT_DIR"
APP="$(dirname "$SCRIPT_DIR")/MacExpert.app"
DIST="$PKG_DIR/dist"
ENTITLEMENTS="$PKG_DIR/Xcode/Extension/MacExpert.entitlements"
PROJECT="$PKG_DIR/Xcode/MacExpertPlugin.xcodeproj"
SCHEME="MacExpertExtension"
APPEX_NAME="MacExpertExtension.appex"

TAG=""
DO_PUSH=0
DO_NOTARIZE=0
NOTARY_PROFILE="${NOTARY_PROFILE:-MacExpert-Notary}"

while [ $# -gt 0 ]; do
    case "$1" in
        --tag)      TAG="$2"; shift 2 ;;
        --push)     DO_PUSH=1; shift ;;
        --notarize) DO_NOTARIZE=1; shift ;;
        *)          echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Resolve the Developer ID identity once — the same one build-app.sh
# would auto-select, but we need it explicitly here to sign the
# extension as a separate codesign invocation.
IDENTITY="$(security find-identity -v -p codesigning | \
    sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
[ -n "$IDENTITY" ] || { echo "ERROR: no Developer ID Application identity in keychain" >&2; exit 1; }
echo "Identity: $IDENTITY"

# 1. Derive the version string from the tag (if given) or short SHA +
# dirty. Must happen BEFORE build-app.sh so the value gets baked into
# the bundle's Info.plist (build-app.sh reads VERSION from env and
# defaults to 0.0.0-dev; the old release.sh derived VERSION after
# build-app.sh ran, so every release v2.0.5..v2.0.9 has 0.0.0-dev in
# CFBundleShortVersionString even though the filename has the tag).
if [ -n "$TAG" ]; then
    VERSION="${TAG#v}"
else
    cd "$PKG_DIR"
    SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    DIRTY=""
    if ! git diff --quiet 2>/dev/null; then DIRTY="-dirty"; fi
    VERSION="dev-$SHA$DIRTY"
fi
export VERSION

# 2. Build the .app (SKIP_SIGN — we sign inside-out below so the
# embedded extension + the .app are sealed under the same hardened-
# runtime envelope).
SKIP_SIGN=1 "$SCRIPT_DIR/build-app.sh"

# 3. Build and embed the ExtensionKit extension.
echo "==> Building $APPEX_NAME"
# SwiftPM's bare-repo cache trips `safe.bareRepository=explicit` (a
# common global git setting) under xcodebuild; allow it for child git
# processes without touching repo config.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all
( cd "$PKG_DIR/Xcode" && xcodegen generate >/dev/null )
DERIVED="$(mktemp -d)"
# CODE_SIGNING_ALLOWED=NO: we sign with our local identity below so
# extension + app are notarized as a single unit.
xcrun xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO build >/tmp/macexpert-xcodebuild.log
APPEX="$(/usr/bin/find "$DERIVED/Build/Products" -name "$APPEX_NAME" -maxdepth 3 | head -1)"
[ -n "$APPEX" ] || { echo "ERROR: $APPEX_NAME not built; see /tmp/macexpert-xcodebuild.log" >&2; exit 1; }

echo "==> Embedding $APPEX_NAME"
mkdir -p "$APP/Contents/Extensions"
rm -rf "$APP/Contents/Extensions/$APPEX_NAME"
cp -R "$APPEX" "$APP/Contents/Extensions/"
rm -rf "$DERIVED"

# 4. Sign inside-out (extension first, then app) — hardened runtime +
# secure timestamp on both. The .app's signature seals the embedded
# extension; if you sign the app first then modify it, the seal breaks.
echo "==> Signing extension + app (hardened runtime, secure timestamp)"
codesign --force -s "$IDENTITY" -o runtime --timestamp \
    --entitlements "$ENTITLEMENTS" "$APP/Contents/Extensions/$APPEX_NAME"
codesign --force -s "$IDENTITY" -o runtime --timestamp "$APP"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | head -3

# 5. Produce the .zip + .dmg + .radioplugin.
mkdir -p "$DIST"
ZIP="$DIST/MacExpert-${VERSION}-macOS.zip"
DMG="$DIST/MacExpert-${VERSION}-macOS.dmg"
PLUGIN="$DIST/MacExpert-${VERSION}.radioplugin"
rm -f "$ZIP" "$DMG" "$PLUGIN"

echo "==> Zipping app"
# ditto keeps the bundle's symlinks and signature intact — `zip -r`
# doesn't. --norsrc keeps AppleDouble `._*` entries out of the zip
# (v2.0.9's --sequesterRsrc zip carried 31 of them); a non-Apple
# unzipper can write those into the bundle and break its seal.
ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/MacExpert")"
echo "Built $ZIP ($(du -h "$ZIP" | cut -f1), $ARCHS)"

# 6. Optional Apple notarization + stapling of the .app.
if [ "$DO_NOTARIZE" = "1" ]; then
    echo "==> Notarizing app (~1-5 min)"
    if ! xcrun notarytool submit "$ZIP" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait 2>&1 | tee /tmp/macexpert-notary.log; then
        echo "ERROR: notarytool submit failed. See /tmp/macexpert-notary.log" >&2
        exit 1
    fi
    if ! grep -q "status: Accepted" /tmp/macexpert-notary.log; then
        echo "ERROR: notarization not accepted. Fetching log..." >&2
        SUB_ID="$(grep '  id:' /tmp/macexpert-notary.log | head -1 | awk '{print $2}')"
        if [ -n "$SUB_ID" ]; then
            xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE"
        fi
        exit 1
    fi
    echo "==> Stapling notarization ticket to .app"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl -a -t exec -vv "$APP" 2>&1 | head -3 || true
    # Re-zip so the published .zip carries the stapled ticket.
    echo "==> Re-zipping stapled .app"
    rm -f "$ZIP"
    ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
fi

# The published zip (stapled, if --notarize) must carry no AppleDouble
# sidecars: an unzipper that turns them into files breaks the signature.
SIDECARS="$(zipinfo -1 "$ZIP" | grep -c -E '(^|/)(\._|__MACOSX)' || true)"
[ "$SIDECARS" = "0" ] || { echo "ERROR: $ZIP contains $SIDECARS AppleDouble entries" >&2; exit 1; }

# 7. Build the DMG. Sign it; with --notarize, also notarize + staple
# it so `hdiutil mount` doesn't trigger a Gatekeeper prompt.
echo "==> Building DMG"
hdiutil create -volname "MacExpert" -srcfolder "$APP" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
codesign --force -s "$IDENTITY" --timestamp "$DMG"
if [ "$DO_NOTARIZE" = "1" ]; then
    echo "==> Notarizing DMG (~1-5 min)"
    if ! xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait | \
            tee /tmp/macexpert-notary-dmg.log; then
        echo "ERROR: DMG notarization submit failed" >&2
        exit 1
    fi
    if ! grep -q "status: Accepted" /tmp/macexpert-notary-dmg.log; then
        echo "ERROR: DMG notarization not accepted" >&2
        exit 1
    fi
    xcrun stapler staple "$DMG"
fi

# 8. Build the .radioplugin (Amateur Radio Suite installable: zip of
# plugin.json + the signed extension). Mirrors what scripts/make-
# radioplugin.sh used to do, now folded inline.
echo "==> Building .radioplugin"
STAGE="$(mktemp -d)"
cp "$PKG_DIR/Xcode/Extension/plugin.json" "$STAGE/plugin.json"
cp -R "$APP/Contents/Extensions/$APPEX_NAME" "$STAGE/"
( cd "$STAGE" && ditto -c -k --norsrc --noextattr . "$PLUGIN" )
rm -rf "$STAGE"

# 9. SHA256SUMS for all three artifacts.
( cd "$DIST" && shasum -a 256 \
    "MacExpert-${VERSION}-macOS.zip" \
    "MacExpert-${VERSION}-macOS.dmg" \
    "MacExpert-${VERSION}.radioplugin" \
    > SHA256SUMS )

echo
echo "Built:"
ls -lh "$ZIP" "$DMG" "$PLUGIN" "$DIST/SHA256SUMS"

# 10. Optionally tag the current commit and create the GitHub release.
if [ -n "$TAG" ]; then
    cd "$PKG_DIR"
    if git rev-parse "$TAG" >/dev/null 2>&1; then
        echo "Tag $TAG already exists — skipping tag creation."
    else
        echo "Tagging $TAG ..."
        git tag -a "$TAG" -m "Release $TAG"
    fi

    if [ "$DO_PUSH" = "1" ]; then
        echo "Pushing tag $TAG ..."
        git push origin "$TAG"

        if ! command -v gh >/dev/null 2>&1; then
            echo "WARNING: gh CLI not installed; skipped GitHub release. Upload manually." >&2
            exit 0
        fi
        if gh release view "$TAG" >/dev/null 2>&1; then
            echo "Release $TAG already exists; uploading assets..."
            gh release upload "$TAG" "$ZIP" "$DMG" "$PLUGIN" "$DIST/SHA256SUMS" --clobber
        else
            echo "Creating GitHub release $TAG ..."
            gh release create "$TAG" \
                --title "$TAG" \
                --generate-notes \
                "$ZIP" "$DMG" "$PLUGIN" "$DIST/SHA256SUMS"
        fi
    fi
fi

echo "==> Done."
