const fs = require("fs");
const path = require("path");
const http = require("http");
const https = require("https");

// Keep-alive pools so back-to-back dictations reuse a warm socket to the Parakeet
// server instead of paying a fresh TCP handshake each time.
const keepAlive = { keepAlive: true, keepAliveMsecs: 120_000, maxSockets: 8 };
const httpAgent = new http.Agent(keepAlive);
const httpsAgent = new https.Agent(keepAlive);

// POST a WAV buffer, resolve the server's parsed JSON reply. Rejects on non-2xx or
// timeout — no retry; callers surface the failure (the WAV is on disk to re-run).
function postWav(urlStr, buf, timeoutMs) {
  return new Promise((resolve, reject) => {
    const url = new URL(urlStr);
    const isHttps = url.protocol === "https:";
    const req = (isHttps ? https : http).request(
      url,
      {
        method: "POST",
        agent: isHttps ? httpsAgent : httpAgent,
        headers: { "Content-Type": "audio/wav", "Content-Length": buf.length },
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          if (res.statusCode < 200 || res.statusCode >= 300) {
            return reject(new Error(`parakeet ${res.statusCode}`));
          }
          try {
            resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
          } catch (e) {
            reject(e);
          }
        });
      }
    );
    req.setTimeout(timeoutMs, () => req.destroy(new Error("parakeet timeout")));
    req.on("error", reject);
    req.end(buf);
  });
}

const PARAKEET_URL = process.env.PARAKEET_URL || "http://127.0.0.1:8005/transcribe";

// A 200-OK degenerate result (repetition collapse / near-empty on real audio)
// sits at ~0 chars/sec; a 0.5 ch/s floor clears even slow, pause-heavy dictations
// (p1≈0.95) while catching genuine collapses. On degenerate we now SURFACE a
// failure rather than silently retrying — the WAV is on disk, so re-transcribe.
const MIN_CHARS_PER_SECOND = 0.5;


// POST the whole WAV to the local Parakeet server and return its text. Throws if
// the server is unreachable — callers surface that (no silent fallback).
async function transcribeWholeFile(wavPath) {
  const buf = fs.readFileSync(wavPath);
  const durationSec = wavDurationSec(wavPath);
  const timeoutMs = Math.max(120_000, Math.ceil((durationSec || 0) * 1000));
  const t0 = Date.now();
  const json = await postWav(PARAKEET_URL, buf, timeoutMs);
  console.log(`[transcribe] parakeet ${Date.now() - t0}ms dur=${json.audio_s}s`);
  return (json.text || "").replace(/\s+/g, " ").trim();
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

module.exports = { transcribe, wavDurationSec };
