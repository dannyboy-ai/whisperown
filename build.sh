#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$SCRIPT_DIR/dist/WhisperOwn.app"
RELEASE_BUILD="${WHISPEROWN_RELEASE:-0}"
INSTALL_APP="${WHISPEROWN_INSTALL_APP:-1}"

echo "Building WhisperOwn..."

# Clean previous build
rm -rf "$APP_BUNDLE"

# Create .app bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Compile via SwiftPM (standard multi-file Swift executable; no Xcode). System
# frameworks auto-link from their imports.
swift build -c release --package-path "$SCRIPT_DIR"
cp "$SCRIPT_DIR/.build/release/WhisperOwn" "$APP_BUNDLE/Contents/MacOS/WhisperOwn"

# Copy Info.plist
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$SCRIPT_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$SCRIPT_DIR/Resources/BrandHero.png" "$APP_BUNDLE/Contents/Resources/BrandHero.png"

# Code signing. This is what determines whether the Accessibility grant survives
# a rebuild. Ad-hoc ("-") binds the grant to the binary's cdhash, which changes on
# EVERY rebuild — so Accessibility silently breaks each time (a stale ✓ stays in
# the list). A stable signing identity binds the grant to the certificate instead,
# so you grant Accessibility ONCE and it persists across all future rebuilds.
# Local builds prefer an Apple Development identity so Accessibility survives
# rebuilds. Release builds provide a Developer ID Application identity explicitly
# and add the hardened runtime, secure timestamp, and release entitlements.
SIGN_ID="${WHISPEROWN_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID/{print $2; exit}')
fi
if [ "$RELEASE_BUILD" = "1" ]; then
    case "$SIGN_ID" in
        "Developer ID Application:"*) ;;
        *)
            echo "ERROR: release builds require a Developer ID Application identity."
            exit 1
            ;;
    esac
    codesign --force --sign "$SIGN_ID" \
        --identifier "com.whisperown.app" \
        --options runtime \
        --timestamp \
        --entitlements "$SCRIPT_DIR/WhisperOwn.entitlements" \
        "$APP_BUNDLE"
    echo "Signed release with hardened runtime: $SIGN_ID"
elif [ -n "$SIGN_ID" ]; then
    codesign --force --sign "$SIGN_ID" --identifier "com.whisperown.app" "$APP_BUNDLE"
    echo "Signed with stable identity: $SIGN_ID  (Accessibility grant persists across rebuilds)"
else
    codesign --force --sign - --identifier "com.whisperown.app" "$APP_BUNDLE"
    echo "Signed ad-hoc — no stable identity found; Accessibility must be re-granted after each rebuild"
fi

if [ "$INSTALL_APP" = "1" ]; then
    # Stop a running copy before replacing its bundle. Otherwise `open` after an
    # update keeps the old in-memory process and the user is not actually testing
    # the newly installed binary.
    osascript -e 'tell application id "com.whisperown.app" to quit' 2>/dev/null || true
    sleep 0.3

    # Install a real copy in /Applications. A symlinked ad-hoc app cannot keep a
    # stable Accessibility grant.
    rm -rf "/Applications/WhisperOwn.app"
    cp -R "$APP_BUNDLE" "/Applications/WhisperOwn.app"
    echo "Installed: /Applications/WhisperOwn.app  (real copy — run THIS one)"
    echo ""
    echo "To run:  open /Applications/WhisperOwn.app"
fi

echo "Built:     $APP_BUNDLE"
