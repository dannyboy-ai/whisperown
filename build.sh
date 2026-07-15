#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$SCRIPT_DIR/dist/WhisperOwn.app"

echo "Building WhisperOwn..."

# Clean previous build
rm -rf "$APP_BUNDLE"

# Create .app bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Compile Swift
swiftc "$SCRIPT_DIR/VoiceToText.swift" \
    -o "$APP_BUNDLE/Contents/MacOS/WhisperOwn" \
    -framework Cocoa \
    -framework AVFoundation \
    -framework Carbon

# Copy Info.plist
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Code signing. This is what determines whether the Accessibility grant survives
# a rebuild. Ad-hoc ("-") binds the grant to the binary's cdhash, which changes on
# EVERY rebuild — so Accessibility silently breaks each time (a stale ✓ stays in
# the list). A stable signing identity binds the grant to the certificate instead,
# so you grant Accessibility ONCE and it persists across all future rebuilds.
# We auto-detect an Apple Development / Developer ID cert; override with
# WHISPEROWN_SIGN_ID="<identity name>". No identity → ad-hoc (grant resets each build).
SIGN_ID="${WHISPEROWN_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID/{print $2; exit}')
fi
if [ -n "$SIGN_ID" ]; then
    codesign --force --sign "$SIGN_ID" --identifier "com.whisperown.app" "$APP_BUNDLE"
    echo "Signed with stable identity: $SIGN_ID  (Accessibility grant persists across rebuilds)"
else
    codesign --force --sign - --identifier "com.whisperown.app" "$APP_BUNDLE"
    echo "Signed ad-hoc — no stable identity found; Accessibility must be re-granted after each rebuild"
fi

# Install a REAL copy in /Applications (NOT a symlink). An ad-hoc-signed app
# launched from a symlink into a user folder (~/Desktop/...) can't register a
# stable Accessibility TCC entry — it prompts but never appears in the list, so
# the grant never sticks. A real bundle at a canonical path fixes that. The
# ad-hoc signature is path-independent, so the copy stays valid.
rm -rf "/Applications/WhisperOwn.app"
cp -R "$APP_BUNDLE" "/Applications/WhisperOwn.app"

echo "Built:     $APP_BUNDLE"
echo "Installed: /Applications/WhisperOwn.app  (real copy — run THIS one)"
echo ""
echo "To run:  open /Applications/WhisperOwn.app"
