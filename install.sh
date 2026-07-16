#!/bin/bash
# One-command setup for WhisperOwn. Idempotent — safe to re-run after a pull.
#
#   ./install.sh
#
# Sets up the Python backend (venv + deps + a login launch agent) and builds the
# menubar app. Afterward you still do two things by hand, both spelled out at the
# end: free the Globe key, and grant Accessibility.
set -e

REPO="$(cd "$(dirname "$0")" && pwd)"
AGENT="com.whisperown.server"
PLIST_SRC="$REPO/server/$AGENT.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$AGENT.plist"

echo "==> WhisperOwn setup"

# --- preflight -------------------------------------------------------------
if [ "$(uname -m)" != "arm64" ]; then
    echo "ERROR: WhisperOwn needs an Apple Silicon Mac (the model runs on the GPU via MLX)."
    exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
    echo "ERROR: Xcode Command Line Tools are required. Run:  xcode-select --install"
    echo "       then re-run ./install.sh"
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found (need 3.10+)."
    exit 1
fi

# --- backend: venv + deps --------------------------------------------------
echo "==> Python backend (server/.venv)"
if [ ! -d "$REPO/server/.venv" ]; then
    python3 -m venv "$REPO/server/.venv"
fi
"$REPO/server/.venv/bin/pip" install --quiet --upgrade pip
"$REPO/server/.venv/bin/pip" install --quiet -r "$REPO/server/requirements.txt"

echo "==> Backend self-test (cleanup pipeline)"
( cd "$REPO/server" && ./.venv/bin/python test_postprocess.py >/dev/null && echo "    cleanup tests pass" )

# --- launch agent (starts at login, restarts if it dies) -------------------
echo "==> Launch agent ($AGENT)"
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__REPO__|$REPO|g" -e "s|__HOME__|$HOME|g" "$PLIST_SRC" > "$PLIST_DST"
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"
echo "    loaded — first start downloads the Parakeet model (a few hundred MB), then stays warm on 127.0.0.1:8000"

# --- build + install the app ----------------------------------------------
echo "==> Building the menubar app"
"$REPO/build.sh"

cat <<'EOF'

==> Two manual steps remain (the app's Permissions Guide also walks you through these):

  1. Free the Globe key
     System Settings → Keyboard → "Press 🌐 key to" → Do Nothing
     (Otherwise pressing Globe pops the emoji picker and fights the app.)

  2. Grant Accessibility
     System Settings → Privacy & Security → Accessibility → toggle WhisperOwn on
     (Lets it see the Globe keypress and paste at your cursor.)

Then:  open /Applications/WhisperOwn.app
Press Globe, talk, press Globe again — your cleaned-up text lands at the cursor.
EOF
