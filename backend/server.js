const express = require("express");
const multer = require("multer");
const path = require("path");
const os = require("os");
const fs = require("fs");
const db = require("./db");
const { transcribe, wavDurationSec, readBackendMode } = require("./transcribe");
const { postprocess } = require("./postprocess");

const app = express();
const PORT = parseInt(process.env.PORT, 10) || 8000; // menubar app expects 8000
app.use(express.json());

// Store uploads in the same recordings directory the Swift app uses
const recordingsDir = path.join(
  os.homedir(),
  "Library/Application Support/Voice-to-Text/recordings"
);
fs.mkdirSync(recordingsDir, { recursive: true });

const upload = multer({ dest: recordingsDir });

app.post("/transcribe", upload.single("audio"), async (req, res) => {
  if (!req.file) {
    return res.status(400).json({ error: "No audio file provided" });
  }

  // Rename multer's temp file to .wav
  const wavPath = req.file.path + ".wav";
  fs.renameSync(req.file.path, wavPath);

  try {
    const { text: rawText, source } = await transcribe(wavPath);
    // postprocess applies the output style (lowercase + acronym preservation),
    // the user dictionary, filler cleanup, and the trailing space — for every
    // backend. (A remote model's own capitalization is discarded because
    // lowercase is the preferred style; its sentence segmentation survives
    // since postprocess keeps punctuation.)
    const text = postprocess(rawText);
    const durSec = wavDurationSec(wavPath);
    const id = db.save(wavPath, text, durSec === null ? null : Math.round(durSec * 1000), source);
    console.log(`[${new Date().toISOString()}] Transcribed: "${rawText}" (id=${id})`);
    res.json({ text, id });
  } catch (err) {
    console.error("Transcription error:", err);
    res.status(500).json({ error: "Transcription failed" });
  }
});

app.get("/history", (req, res) => {
  const limit = Math.min(parseInt(req.query.limit) || 50, 200);
  const rows = db.history(limit);
  res.json(rows);
});

// The active cleanup-rule manifest, for the app's read-only "Cleanup Rules" viewer.
app.get("/rules", (req, res) => {
  const { RULES } = require("./postprocess");
  res.json(RULES);
});

// Probe the configured remote endpoint(s) so the menubar app can show "is my
// GPU box reachable?" without knowing any endpoint itself — the app only ever
// talks to this localhost backend; remote topology lives in config.json.
app.get("/backend-status", async (req, res) => {
  const { loadConfig } = require("./config");
  const remote = loadConfig().remote;
  const entries = Object.entries(remote).filter(([, url]) => url);
  const results = await Promise.all(
    entries.map(async ([mode, url]) => {
      const start = Date.now();
      try {
        const ctrl = new AbortController();
        const timer = setTimeout(() => ctrl.abort(), 3000);
        const resp = await fetch(url.replace(/\/transcribe$/, "/"), {
          signal: ctrl.signal,
        }).finally(() => clearTimeout(timer));
        return { mode, url, ok: true, status: resp.status, ms: Date.now() - start };
      } catch (err) {
        return { mode, url, ok: false, error: err.message, ms: Date.now() - start };
      }
    })
  );
  res.json({ mode: readBackendMode(), remotes: results });
});

app.listen(PORT, "127.0.0.1", () => {
  console.log(`WhisperOwn backend running on http://127.0.0.1:${PORT}`);
});
