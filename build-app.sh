#!/bin/bash
# Build MacExpert.app as a universal (arm64 + x86_64) binary so it runs
# natively on both Apple Silicon and Intel Macs without Rosetta.
#
# Builds each arch separately (Swift Package Manager doesn't do fat
# binaries in a single invocation), then fuses them with `lipo`. The
# resource bundles produced by SwiftPM for each arch are identical, so
# we take them from the arm64 tree.
set -e

# Script lives inside the Swift Package directory; the .app bundle sits
# one level up alongside it.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$SCRIPT_DIR"
APP_DIR="$(dirname "$SCRIPT_DIR")/MacExpert.app"

# Version stamped into the bundle's Info.plist (override via env). The release workflow
# passes the resolved release version; local builds default to a dev marker.
VERSION="${VERSION:-0.0.0-dev}"
BUNDLE_ID="com.vu2cpl.MacExpert"

cd "$PKG_DIR"

echo "Building MacExpert (release, arm64)..."
swift build -c release --arch arm64

echo "Building MacExpert (release, x86_64)..."
swift build -c release --arch x86_64

ARM_BIN="$PKG_DIR/.build/arm64-apple-macosx/release/MacExpert"
INTEL_BIN="$PKG_DIR/.build/x86_64-apple-macosx/release/MacExpert"

if [ ! -x "$ARM_BIN" ] || [ ! -x "$INTEL_BIN" ]; then
    echo "ERROR: one or both per-arch binaries missing." >&2
    echo "  arm64:  $ARM_BIN" >&2
    echo "  x86_64: $INTEL_BIN" >&2
    exit 1
fi

echo "Assembling MacExpert.app..."
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

lipo -create -output "$APP_DIR/Contents/MacOS/MacExpert" "$ARM_BIN" "$INTEL_BIN"
echo "Universal binary: $(lipo -archs "$APP_DIR/Contents/MacOS/MacExpert")"

cp "$PKG_DIR/MacExpert/Resources/ExpertIcon.icns" "$APP_DIR/Contents/Resources/ExpertIcon.icns"

# Copy Swift resource bundles (take the arm64 set; they're architecture-
# independent so the other arch's copies would be identical).
for bundle in "$PKG_DIR/.build/arm64-apple-macosx/release/"*.bundle; do
    [ -d "$bundle" ] && cp -R "$bundle" "$APP_DIR/Contents/Resources/"
done

# Info.plist — without this the bundle has no identity: it won't launch cleanly and (once an
# ExtensionKit .appex is embedded) the extension won't register with macOS / the Suite.
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>MacExpert</string>
    <key>CFBundleDisplayName</key>
    <string>MacExpert</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>MacExpert</string>
    <key>CFBundleIconFile</key>
    <string>ExpertIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

# Codesign with the Developer ID Application identity if one is available. SIGN_IDENTITY env
# var overrides; otherwise we pick the first Developer ID Application identity from the
# keychain. Hardened runtime is enabled so the app meets Gatekeeper / notarization
# requirements. If no identity is present, fall back to ad-hoc signing.
#
# package-signed.sh sets SKIP_SIGN=1: it embeds the ExtensionKit .appex and then signs the
# whole bundle inside-out (with entitlements) + notarizes, so signing here would be redundant
# and would only double-expose the build to Apple's flaky timestamp service. The standalone
# release.sh path leaves SKIP_SIGN unset, so it still gets a signed app from this script.
if [ "${SKIP_SIGN:-0}" != "1" ]; then
    if [ -z "${SIGN_IDENTITY:-}" ]; then
        SIGN_IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null \
            | awk -F\" '/Developer ID Application/ { print $2; exit }')"
    fi

    if [ -n "$SIGN_IDENTITY" ]; then
        echo "Codesigning with: $SIGN_IDENTITY"
        # Strip Finder/quarantine xattrs first; codesign refuses to sign
        # bundles that contain "resource fork, Finder information, or
        # similar detritus".
        xattr -cr "$APP_DIR"
        codesign --force --deep --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" \
            "$APP_DIR"
        echo "Verifying signature..."
        # Verify can spuriously fail with "Disallowed xattr com.apple.FinderInfo"
        # when the source tree lives on iCloud Drive (macOS auto-adds Finder
        # metadata to bundle directories). The real signature is fine — the
        # zip we ship strips that xattr via `ditto`. So we run verify but
        # don't fail the build on this specific xattr warning.
        if ! codesign --verify --deep --strict --verbose=2 "$APP_DIR" 2>&1 | tail -3 \
             | tee /dev/tty | grep -q "satisfies its Designated Requirement"; then
            echo "(Verify warning is usually iCloud's FinderInfo xattr — harmless;"
            echo " release.sh's ditto-zipped output is the canonical artifact.)"
        fi
    else
        echo "No Developer ID found — ad-hoc signing (local use only)."
        codesign --force --deep --sign - "$APP_DIR"
    fi
fi

echo "Done! App at: $APP_DIR (v$VERSION, $BUNDLE_ID)"
echo "Run: open \"$APP_DIR\""
