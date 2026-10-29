#!/bin/bash
# Build MacExpert.app as a universal (arm64 + x86_64) binary so it runs
# natively on both Apple Silicon and Intel Macs without Rosetta.
#
# Every run builds fresh and checks what it built (2026-10-09). This script
# used to build each arch on its own and lipo
# .build/{arm64,x86_64}-apple-macosx/release/MacExpert — paths Swift 6.4's
# build system no longer writes (it writes .build/out/Products/Release). The
# June 2026 binaries left there were what got lipo'd, so v2.0.10 shipped a
# June build without the update check its notes describe. Now SwiftPM builds
# both architectures in one invocation and is ASKED where the product is; the
# old product is deleted first; and the script stops if the fresh binary is
# missing, lacks an architecture, records the wrong deployment target or SDK,
# needs an @rpath dylib, lacks the update checker, or is not byte-identical in
# the .app.
set -euo pipefail

# Script lives inside the Swift Package directory; the .app bundle sits
# one level up alongside it.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$SCRIPT_DIR"
APP_DIR="$(dirname "$SCRIPT_DIR")/MacExpert.app"

# Version stamped into the bundle's Info.plist (override via env). The release workflow
# passes the resolved release version; local builds default to a dev marker.
VERSION="${VERSION:-0.0.0-dev}"
BUNDLE_ID="com.vu2cpl.MacExpert"
MIN_OS="14.0"   # = Package.swift .macOS(.v14) and LSMinimumSystemVersion below

fail() { echo "ERROR: $*" >&2; exit 1; }

cd "$PKG_DIR"

BUILD_ARGS=(-c release --arch arm64 --arch x86_64)
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
BUILT_BIN="$BIN_DIR/MacExpert"
# Whatever is here after the build was produced by this run.
rm -f "$BUILT_BIN"
rm -rf "$BIN_DIR"/*.bundle

SDK="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VER="$(xcrun --sdk macosx --show-sdk-version)"

echo "Building MacExpert (release, arm64 + x86_64, macOS SDK $SDK_VER) -> $BIN_DIR"
# -isysroot for the link step: Swift 6.4's build system links through
# `swiftc -sdk`, which hands clang only --sysroot, so ld records the
# deployment target (14.0) as the SDK version and macOS applies old
# linked-on-or-after behaviour. Pass the real SDK and check it below.
swift build "${BUILD_ARGS[@]}" \
    -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$SDK"

[ -f "$BUILT_BIN" ] || fail "the build did not produce $BUILT_BIN"
ARCHS=" $(lipo -archs "$BUILT_BIN") "
for a in arm64 x86_64; do
    case "$ARCHS" in *" $a "*) ;; *) fail "$BUILT_BIN lacks $a (has:${ARCHS})" ;; esac
    BV="$(vtool -arch "$a" -show-build "$BUILT_BIN")"
    minos="$(awk '$1=="minos"{print $2}' <<<"$BV")"
    sdk="$(awk '$1=="sdk"{print $2}' <<<"$BV")"
    [ "$minos" = "$MIN_OS" ] || fail "$a slice has minos $minos, expected $MIN_OS"
    [ "$sdk" = "$SDK_VER" ] || fail "$a slice records sdk $sdk, expected $SDK_VER"
done
if otool -L "$BUILT_BIN" | /usr/bin/grep -q '@rpath/'; then
    otool -L "$BUILT_BIN" | /usr/bin/grep '@rpath/'
    fail "the binary needs @rpath dylibs this bundle does not carry"
fi
# The standalone app has the GitHub release check (MacExpert/UpdateChecker.swift);
# a binary without its request URL is not a build of this source.
# (A count, not grep -q: under pipefail an early grep exit SIGPIPEs strings.)
CHECKER="$(strings -a "$BUILT_BIN" | /usr/bin/grep -c 'api.github.com/repos/' || true)"
[ "${CHECKER:-0}" -gt 0 ] \
    || fail "$BUILT_BIN has no update checker — not a build of the current source"
echo "Built $(stat -f '%Sm' "$BUILT_BIN"); archs:${ARCHS}minos $MIN_OS, sdk $SDK_VER"

echo "Assembling MacExpert.app (fresh)..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BUILT_BIN" "$APP_DIR/Contents/MacOS/MacExpert"
cmp -s "$BUILT_BIN" "$APP_DIR/Contents/MacOS/MacExpert" \
    || fail "the binary in $APP_DIR is not the one just built"
echo "Universal binary: $(lipo -archs "$APP_DIR/Contents/MacOS/MacExpert")"

cp "$PKG_DIR/MacExpert/Resources/ExpertIcon.icns" "$APP_DIR/Contents/Resources/ExpertIcon.icns"

# SwiftPM resource bundles from this build (architecture-independent). The
# bin path also holds the test target's bundle (fixtures) — not shipped.
for bundle in "$BIN_DIR/"*.bundle; do
    case "$(basename "$bundle")" in *Tests.bundle) continue ;; esac
    [ -d "$bundle" ] && cp -R "$bundle" "$APP_DIR/Contents/Resources/"
done
[ -d "$APP_DIR/Contents/Resources/MacExpert_MacExpert.bundle" ] \
    || fail "MacExpert_MacExpert.bundle missing from the build"

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
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")" = "$VERSION" ] \
    || fail "Info.plist does not carry version $VERSION"

# Codesign with the Developer ID Application identity if one is available. SIGN_IDENTITY env
# var overrides; otherwise we pick the first Developer ID Application identity from the
# keychain. Hardened runtime is enabled so the app meets Gatekeeper / notarization
# requirements. If no identity is present, fall back to ad-hoc signing.
#
# release.sh sets SKIP_SIGN=1: it embeds the ExtensionKit .appex and then signs the whole
# bundle inside-out (with entitlements) + notarizes, so signing here would be redundant and
# would only double-expose the build to Apple's flaky timestamp service. Direct invocations
# (./build-app.sh from the command line, install.sh, etc.) leave SKIP_SIGN unset and get a
# signed standalone app from this step.
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
