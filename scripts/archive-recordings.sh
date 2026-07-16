#!/usr/bin/env bash
# Move WhisperOwn recordings older than 30 days from the hot directory
# into per-month subdirs under _archive/. Keeps the flat recording dir
# small so Spotlight / XProtect / Time Machine don't churn over 15k+
# files every time the system goes under memory pressure.
#
# Transcripts already live in SQLite (whisperown.db); the wav files
# are only kept for ad-hoc replay or re-transcription. Same volume, so
# Time Machine continues to back them up.
#
# Safe to re-run. Idempotent. Designed to be invoked by launchd weekly.

set -euo pipefail

ROOT="$HOME/Library/Application Support/WhisperOwn/recordings"
ARCHIVE="$ROOT/_archive"
AGE_DAYS="${AGE_DAYS:-30}"

if [[ ! -d "$ROOT" ]]; then
  echo "archive-recordings: $ROOT does not exist" >&2
  exit 0
fi

mkdir -p "$ARCHIVE"

moved=0
errors=0

# -maxdepth 1 → never touch files already under _archive/
while IFS= read -r -d '' f; do
  month=$(stat -f "%Sm" -t "%Y-%m" "$f")
  dest_dir="$ARCHIVE/$month"
  mkdir -p "$dest_dir"
  if mv -n "$f" "$dest_dir/"; then
    moved=$((moved + 1))
  else
    errors=$((errors + 1))
  fi
done < <(find "$ROOT" -maxdepth 1 -name "*.wav" -mtime "+${AGE_DAYS}" -print0)

ts=$(date "+%Y-%m-%dT%H:%M:%S%z")
echo "[$ts] archive-recordings: moved=$moved errors=$errors age_threshold=${AGE_DAYS}d"
