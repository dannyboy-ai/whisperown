const Database = require("better-sqlite3");
const path = require("path");
const os = require("os");
const fs = require("fs");

const dataDir = path.join(
  os.homedir(),
  "Library/Application Support/Voice-to-Text"
);
fs.mkdirSync(dataDir, { recursive: true });

const db = new Database(path.join(dataDir, "voice-to-text.db"));

// WAL mode for better concurrent read/write
db.pragma("journal_mode = WAL");

db.exec(`
  CREATE TABLE IF NOT EXISTS transcriptions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    audio_path TEXT NOT NULL,
    text TEXT NOT NULL,
    duration_ms INTEGER,
    created_at TEXT DEFAULT (datetime('now'))
  )
`);

// Migration: `source` records WHERE the text came from — "remote" (the
// configured GPU server) or "local" (whisper-cli fallback on the Mac). Added so
// "how often / when did it fall back to local?" is a one-line SQL query instead
// of log archaeology. Older rows (pre-migration) stay NULL unless backfilled.
const cols = db.prepare("PRAGMA table_info(transcriptions)").all();
if (!cols.some((c) => c.name === "source")) {
  db.exec("ALTER TABLE transcriptions ADD COLUMN source TEXT");
}

const insert = db.prepare(`
  INSERT INTO transcriptions (audio_path, text, duration_ms, source)
  VALUES (@audio_path, @text, @duration_ms, @source)
`);

const getRecent = db.prepare(`
  SELECT id, text, audio_path, duration_ms, source, created_at
  FROM transcriptions
  ORDER BY created_at DESC
  LIMIT ?
`);

module.exports = {
  save(audioPath, text, durationMs = null, source = null) {
    const result = insert.run({
      audio_path: audioPath,
      text,
      duration_ms: durationMs,
      source,
    });
    return result.lastInsertRowid;
  },

  history(limit = 50) {
    return getRecent.all(limit);
  },
};
