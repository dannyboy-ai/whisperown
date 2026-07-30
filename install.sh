#!/bin/bash
# One-command source install for WhisperOwn. Idempotent — safe to re-run.
set -e

REPO="$(cd "$(dirname "$0")" && pwd)"

echo "==> WhisperOwn setup"

if [ "$(uname -m)" != "arm64" ]; then
    echo "ERROR: WhisperOwn needs an Apple Silicon Mac."
    exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
    echo "ERROR: Xcode Command Line Tools are required. Run: xcode-select --install"
    echo "       then re-run ./install.sh"
    exit 1
fi

# Remove the pre-native backend if this checkout was installed before the
# FluidAudio cutover. New installs never create a background service.
LEGACY_AGENT="$HOME/Library/LaunchAgents/com.whisperown.server.plist"
launchctl bootout "gui/$UID/com.whisperown.server" 2>/dev/null || true
if [ -f "$LEGACY_AGENT" ]; then
    rm "$LEGACY_AGENT"
    echo "==> Removed legacy Python launch agent"
fi
if [ -d "$REPO/server/.venv" ]; then
    rm -rf "$REPO/server/.venv"
    echo "==> Removed legacy Python environment"
fi

echo "==> Building the native menubar app"
"$REPO/build.sh"

echo "==> Opening WhisperOwn"
open /Applications/WhisperOwn.app

cat <<'EOF'

WhisperOwn is installed in /Applications.
The first-run guide handles the local speech-model download and macOS permissions.
EOF
