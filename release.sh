#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$SCRIPT_DIR/dist/WhisperOwn.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SCRIPT_DIR/Info.plist")"
ARTIFACT="$SCRIPT_DIR/dist/WhisperOwn-v${VERSION}-macOS-arm64.zip"
NOTARY_PROFILE="${WHISPEROWN_NOTARY_PROFILE:-whisperown-notary}"
SIGN_ID="${WHISPEROWN_SIGN_ID:-}"

if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')
fi
if [ -z "$SIGN_ID" ]; then
    echo "ERROR: no Developer ID Application signing identity found."
    exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/whisperown-release.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
SUBMISSION="$WORK_DIR/WhisperOwn-notarization.zip"
EXTRACTED="$WORK_DIR/verified"

printf '==> Building WhisperOwn %s\n' "$VERSION"
WHISPEROWN_RELEASE=1 \
WHISPEROWN_INSTALL_APP=0 \
WHISPEROWN_SIGN_ID="$SIGN_ID" \
    "$SCRIPT_DIR/build.sh"

printf '==> Verifying Developer ID signature\n'
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

printf '==> Submitting to Apple notary service\n'
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$SUBMISSION"
xcrun notarytool submit "$SUBMISSION" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

printf '==> Stapling notarization ticket\n'
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"
spctl --assess --type execute --verbose=4 "$APP_BUNDLE"

printf '==> Creating distributable archive\n'
rm -f "$ARTIFACT"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ARTIFACT"

mkdir -p "$EXTRACTED"
ditto -x -k "$ARTIFACT" "$EXTRACTED"
codesign --verify --deep --strict --verbose=2 "$EXTRACTED/WhisperOwn.app"
xcrun stapler validate "$EXTRACTED/WhisperOwn.app"
spctl --assess --type execute --verbose=4 "$EXTRACTED/WhisperOwn.app"

printf '\nRelease artifact: %s\n' "$ARTIFACT"
