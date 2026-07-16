const express = require("express");
const path = require("path");
const fs = require("fs");
const crypto = require("crypto");
const { DATA_DIR } = require("./paths");
const db = require("./db");
const { transcribe, wavDurationSec } = require("./transcribe");
const { postprocess } = require("./postprocess");

const app = express();
const PORT = parseInt(process.env.PORT, 10) || 8000; // the menubar app expects 8000
app.use(express.json()); // only parses application/json; the WAV body passes through

// Recordings land in the same directory the menubar app reads from.
const recordingsDir = path.join(DATA_DIR, "recordings");
fs.mkdirSync(recordingsDir, { recursive: true });

// The app POSTs the raw WAV as the request body (Content-Type: audio/wav). Stream
// it straight to a file — no multipart parser needed for a single-field upload.
function receiveWav(req) {
  return new Promise((resolve, reject) => {
    const name = `${Date.now()}-${crypto.randomBytes(4).toString("hex")}.wav`;
    const wavPath = path.join(recordingsDir, name);
    const out = fs.createWriteStream(wavPath);
    req.on("error", reject);
    out.on("error", reject);
    out.on("finish", () => resolve(wavPath));
    req.pipe(out);
  });
}

app.post("/transcribe", async (req, res) => {
  try {
    const wavPath = await receiveWav(req);
    const { text: rawText, source } = await transcribe(wavPath);
    // Cleanup applies the lowercase house style, the user dictionary, and filler
    // removal (see postprocess.js). Punctuation is preserved, so sentence breaks
    // survive.
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

app.listen(PORT, "127.0.0.1", () => {
  console.log(`WhisperOwn backend running on http://127.0.0.1:${PORT}`);
});
