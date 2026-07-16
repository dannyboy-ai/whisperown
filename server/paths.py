"""The data directory and the one-time migration from the former app name.

Everything the app owns lives under ~/Library/Application Support/WhisperOwn/:
recordings, the history DB, and the user dictionary. Importing this module runs
the migration and ensures the directory exists.
"""

import os

SUPPORT = os.path.join(os.path.expanduser("~"), "Library", "Application Support")
DATA_DIR = os.path.join(SUPPORT, "WhisperOwn")
LEGACY_DIR = os.path.join(SUPPORT, "Voice-to-Text")
DB_PATH = os.path.join(DATA_DIR, "whisperown.db")


def _migrate():
    """The app was formerly "Voice-to-Text". Move the whole data directory to the
    new name, then rename the legacy DB files (incl. WAL sidecars). Idempotent —
    after the first run there's nothing left to move."""
    try:
        if os.path.exists(LEGACY_DIR) and not os.path.exists(DATA_DIR):
            os.rename(LEGACY_DIR, DATA_DIR)
        for suffix in ("", "-wal", "-shm"):
            src = os.path.join(DATA_DIR, "voice-to-text.db" + suffix)
            dst = DB_PATH + suffix
            if os.path.exists(src) and not os.path.exists(dst):
                os.rename(src, dst)
    except OSError as e:
        print(f"[paths] data-dir migration skipped: {e}", flush=True)


_migrate()
os.makedirs(DATA_DIR, exist_ok=True)
