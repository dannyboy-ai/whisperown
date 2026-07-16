"""SQLite history of transcriptions. Stdlib sqlite3 — one row per dictation."""

import sqlite3

from paths import DB_PATH

# check_same_thread=False: the model warmup and serve loop share one thread today,
# but this keeps us correct if a request ever lands off the main thread.
_conn = sqlite3.connect(DB_PATH, check_same_thread=False)
_conn.execute("PRAGMA journal_mode = WAL")
_conn.execute(
    """
    CREATE TABLE IF NOT EXISTS transcriptions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        audio_path TEXT NOT NULL,
        text TEXT NOT NULL,
        duration_ms INTEGER,
        created_at TEXT DEFAULT (datetime('now'))
    )
    """
)

# `source` records which path produced the text. Added later as a migration, so
# rows predating the column are NULL.
_cols = [row[1] for row in _conn.execute("PRAGMA table_info(transcriptions)")]
if "source" not in _cols:
    _conn.execute("ALTER TABLE transcriptions ADD COLUMN source TEXT")
_conn.commit()


def save(audio_path, text, duration_ms=None, source=None):
    cur = _conn.execute(
        "INSERT INTO transcriptions (audio_path, text, duration_ms, source) VALUES (?, ?, ?, ?)",
        (audio_path, text, duration_ms, source),
    )
    _conn.commit()
    return cur.lastrowid


def history(limit=50):
    cur = _conn.execute(
        "SELECT id, text, audio_path, duration_ms, source, created_at "
        "FROM transcriptions ORDER BY created_at DESC LIMIT ?",
        (limit,),
    )
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, row)) for row in cur.fetchall()]
