const os = require("os");
const path = require("path");
const fs = require("fs");

const SUPPORT = path.join(os.homedir(), "Library/Application Support");
const DATA_DIR = path.join(SUPPORT, "WhisperOwn");
const LEGACY_DIR = path.join(SUPPORT, "Voice-to-Text");
const DB_PATH = path.join(DATA_DIR, "whisperown.db");

// One-time migration: the app was formerly "Voice-to-Text". Move the whole data
// directory (recordings, history DB, dictionary, config) to the new name so
// nothing is lost, then rename the legacy DB files (incl. WAL sidecars) inside it.
// Idempotent — after the first run there's nothing left to move.
function migrate() {
  try {
    if (fs.existsSync(LEGACY_DIR) && !fs.existsSync(DATA_DIR)) {
      fs.renameSync(LEGACY_DIR, DATA_DIR);
    }
    for (const suffix of ["", "-wal", "-shm"]) {
      const from = path.join(DATA_DIR, "voice-to-text.db" + suffix);
      const to = DB_PATH + suffix;
      if (fs.existsSync(from) && !fs.existsSync(to)) fs.renameSync(from, to);
    }
  } catch (e) {
    console.error("[paths] data-dir migration skipped:", e.message);
  }
}
migrate();
fs.mkdirSync(DATA_DIR, { recursive: true });

module.exports = { DATA_DIR, DB_PATH };
