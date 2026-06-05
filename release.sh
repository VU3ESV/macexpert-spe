#!/bin/bash
# Build, sign, zip, and (optionally) publish a MacExpert release.
#
# Usage:
#   ./release.sh                                # build + sign + zip
#   ./release.sh --notarize                     # also Apple-notarize + staple
#   ./release.sh --tag vX.Y.Z                   # also git tag the current commit
#   ./release.sh --tag vX.Y.Z --push            # tag + create GitHub release
#   ./release.sh --tag vX.Y.Z --push --notarize # full release flow
#
# Output: dist/MacExpert-<version>-universal.zip containing MacExpert.app
# The .app is a universal (arm64 + x86_64) binary, signed with the
# Developer ID Application identity from build-app.sh. With --notarize
# the .app is also Apple-notarized and stapled, so first launch on a
# fresh Mac doesn't show the Gatekeeper "unidentified developer" prompt.
#
# --notarize requires a one-time stored credential profile named
# "MacExpert-Notary" in your keychain:
#   xcrun notarytool store-credentials "MacExpert-Notary" \
#     --apple-id YOUR_APPLE_ID --team-id CHVNJ85C9F \
#     --password YOUR_APP_SPECIFIC_PASSWORD
# (App-specific password from https://account.apple.com/account/manage)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$SCRIPT_DIR"
APP_DIR="$(dirname "$SCRIPT_DIR")/MacExpert.app"
DIST_DIR="$PKG_DIR/dist"

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

# 1. Build + sign via build-app.sh.
"$SCRIPT_DIR/build-app.sh"

# 2. Derive a version string from the tag (if given) or short SHA + dirty.
if [ -n "$TAG" ]; then
    VERSION="${TAG#v}"
else
    cd "$PKG_DIR"
    SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    DIRTY=""
    if ! git diff --quiet 2>/dev/null; then DIRTY="-dirty"; fi
    VERSION="dev-$SHA$DIRTY"
fi

ZIP_PATH="$DIST_DIR/MacExpert-$VERSION-universal.zip"
mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH"

# 3. Zip the .app bundle. ditto preserves resource forks, signature
# metadata, and HFS extended attributes — `zip -r` doesn't.
echo "Packaging $ZIP_PATH ..."
ditto -c -k --keepParent --sequesterRsrc "$APP_DIR" "$ZIP_PATH"

ARCHS="$(lipo -archs "$APP_DIR/Contents/MacOS/MacExpert")"
SIZE_HUMAN="$(du -h "$ZIP_PATH" | cut -f1)"
echo
echo "Built: $ZIP_PATH ($SIZE_HUMAN, $ARCHS)"

# 3b. Optional Apple notarization. Submits the zipped .app to Apple's
# notary service, waits for the verdict (~1-5 min), then staples the
# notarization ticket to the .app and re-zips the stapled bundle so
# the published artifact carries the ticket. Once stapled, Gatekeeper
# accepts the app on a fresh Mac without internet access.
if [ "$DO_NOTARIZE" = "1" ]; then
    echo
    echo "Notarizing (this can take a few minutes)..."
    if ! xcrun notarytool submit "$ZIP_PATH" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait 2>&1 | tee /tmp/macexpert-notary.log; then
        echo "ERROR: notarytool failed. See /tmp/macexpert-notary.log" >&2
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
    echo "Stapling ticket to .app..."
    xcrun stapler staple "$APP_DIR"
    echo "Verifying staple..."
    xcrun stapler validate "$APP_DIR"
    spctl -a -t exec -vv "$APP_DIR" 2>&1 | head -3

    # Re-zip so the published artifact contains the stapled ticket.
    echo "Re-packaging $ZIP_PATH (stapled) ..."
    rm -f "$ZIP_PATH"
    ditto -c -k --keepParent --sequesterRsrc "$APP_DIR" "$ZIP_PATH"
    SIZE_HUMAN="$(du -h "$ZIP_PATH" | cut -f1)"
    echo "Notarized & stapled: $ZIP_PATH ($SIZE_HUMAN)"
fi

# 4. Optionally tag the current commit and create the GitHub release.
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

        if command -v gh >/dev/null 2>&1; then
            echo "Creating GitHub release $TAG ..."
            NOTES="MacExpert $TAG — universal (arm64 + x86_64), Developer ID signed."$'\n\n'"Built from $(git rev-parse HEAD)."
            if gh release view "$TAG" >/dev/null 2>&1; then
                echo "Release $TAG already exists; uploading asset..."
                gh release upload "$TAG" "$ZIP_PATH" --clobber
            else
                gh release create "$TAG" "$ZIP_PATH" \
                    --title "MacExpert $TAG" \
                    --notes "$NOTES"
            fi
        else
            echo "gh CLI not installed; skipped GitHub release. Upload manually:"
            echo "  $ZIP_PATH"
        fi
    fi
fi
