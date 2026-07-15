const fs = require("fs");
const path = require("path");
const { fetch: undiciFetch, Agent } = require("undici");

// Keep-alive pool to the local Parakeet server so back-to-back dictations reuse a
// warm socket instead of a fresh TCP setup each time. (undici's own fetch is
// required for the dispatcher to apply.)
const localAgent = new Agent({
  keepAliveTimeout: 120_000,
  keepAliveMaxTimeout: 600_000,
  connections: 8,
});

const { loadConfig, DATA_DIR } = require("./config");
const CONFIG = loadConfig();
const PARAKEET_URL = (CONFIG.remote && CONFIG.remote.parakeet) || "http://127.0.0.1:8005/transcribe";

// A 200-OK degenerate result (repetition collapse / near-empty on real audio)
// sits at ~0 chars/sec; a 0.5 ch/s floor clears even slow, pause-heavy dictations
// (p1≈0.95) while catching genuine collapses. On degenerate we now SURFACE a
// failure rather than silently retrying — the WAV is on disk, so re-transcribe.
const MIN_CHARS_PER_SECOND = 0.5;

// One backend: the local Parakeet-MLX server (server/parakeet_server.py). Kept as
// a function because server.js /backend-status reports it.
function readBackendMode() {
  return "parakeet";
}

// POST the whole WAV to the local Parakeet server and return its text. Throws if
// the server is unreachable — callers surface that (no silent fallback).
async function transcribeWholeFile(wavPath) {
  const buf = fs.readFileSync(wavPath);
  const durationSec = wavDurationSec(wavPath);
  const timeoutMs = Math.max(120_000, Math.ceil((durationSec || 0) * 1000));
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const t0 = Date.now();
    const res = await undiciFetch(PARAKEET_URL, {
      method: "POST",
      headers: { "Content-Type": "audio/wav" },
      body: buf,
      signal: ctrl.signal,
      dispatcher: localAgent,
    });
    if (!res.ok) throw new Error(`parakeet ${res.status}`);
    const json = await res.json();
    console.log(`[transcribe] parakeet ${Date.now() - t0}ms dur=${json.audio_s}s`);
    return (json.text || "").replace(/\s+/g, " ").trim();
  } finally {
    clearTimeout(timer);
  }
}

// Parse a PCM WAV header in-process to get duration without spawning ffprobe.
// AVAudioFile writes a non-canonical header (JUNK pad before `fmt `, FLLR pad
// before `data`), so walk the RIFF chunk list rather than reading fixed offsets.
function wavDurationSec(filePath) {
  const fd = fs.openSync(filePath, "r");
  try {
    const fileSize = fs.statSync(filePath).size;
    const head = Buffer.alloc(12);
    if (fs.readSync(fd, head, 0, 12, 0) < 12) return null;
    if (head.toString("ascii", 0, 4) !== "RIFF") return null;
    if (head.toString("ascii", 8, 12) !== "WAVE") return null;

    let offset = 12;
    let bytesPerSec = null;
    let dataBytes = null;
    const ck = Buffer.alloc(8);
    while (offset + 8 <= fileSize) {
      if (fs.readSync(fd, ck, 0, 8, offset) < 8) break;
      const id = ck.toString("ascii", 0, 4);
      const size = ck.readUInt32LE(4);
      if (id === "fmt ") {
        const fmt = Buffer.alloc(16);
        if (fs.readSync(fd, fmt, 0, 16, offset + 8) < 16) return null;
        if (fmt.readUInt16LE(0) !== 1) return null; // 1 = PCM
        const channels = fmt.readUInt16LE(2);
        const sampleRate = fmt.readUInt32LE(4);
        const bitsPerSample = fmt.readUInt16LE(14);
        bytesPerSec = sampleRate * channels * (bitsPerSample / 8);
      } else if (id === "data") {
        const onDisk = Math.max(0, fileSize - (offset + 8));
        dataBytes = size > 0 ? Math.min(size, onDisk) : onDisk;
        break;
      }
      offset += 8 + size + (size % 2); // chunks are word-aligned
    }
    if (!bytesPerSec || dataBytes === null) return null;
    return Math.max(0, dataBytes / bytesPerSec);
  } finally {
    fs.closeSync(fd);
  }
}

// { text, source } — source "parakeet" or null (skipped silence). Throws if the
// Parakeet server is unreachable or returns degenerate output; server.js turns
// that into a 500 so the app surfaces it (the WAV is already saved, so retry).
async function transcribe(wavPath) {
  const stat = fs.statSync(wavPath);
  if (stat.size < 10000) return { text: "", source: null };
  const durationSec = wavDurationSec(wavPath);
  const text = await transcribeWholeFile(wavPath);
  if (durationSec !== null && durationSec > 10 && text.length < durationSec * MIN_CHARS_PER_SECOND) {
    throw new Error(`degenerate output: ${text.length} chars for ${durationSec.toFixed(1)}s`);
  }
  return { text, source: "parakeet" };
}

module.exports = { transcribe, wavDurationSec, readBackendMode };
