"""WhisperOwn backend — the whole thing, in one local Python process.

The menubar app POSTs a recording here on stop; this server transcribes it on the
Mac's GPU (Parakeet-MLX), runs the deterministic cleanup, stores it, and returns
the text. Nothing leaves the machine.

Endpoints (all on 127.0.0.1):
  POST /transcribe   raw WAV body -> {text, id}
  GET  /history      recent dictations (JSON rows)
  GET  /rules        the active cleanup-rule manifest (read-only viewer)

WAV is decoded with soundfile (libsndfile), not ffmpeg, so it sidesteps the
parakeet_mlx ffmpeg audio path entirely.
"""

import json
import os
import re
import secrets
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

os.environ.setdefault("HF_HUB_DISABLE_XET", "1")

import numpy as np
import soundfile as sf
import mlx.core as mx
import parakeet_mlx.audio as _pa
import parakeet_mlx.parakeet as _pk

import db
from paths import DATA_DIR
from postprocess import RULES, postprocess


def _load(fn, sampling_rate, dtype=mx.bfloat16):
    d, s = sf.read(str(fn), dtype="float32", always_2d=False)
    if getattr(d, "ndim", 1) > 1:
        d = d.mean(axis=1)
    if s != sampling_rate:
        import librosa
        d = librosa.resample(d.astype(np.float32), orig_sr=s, target_sr=sampling_rate)
    return mx.array(np.asarray(d, dtype=np.float32))


_pa.load_audio = _load
_pk.load_audio = _load
from parakeet_mlx import from_pretrained

MODEL = os.environ.get("PARAKEET_MODEL", "mlx-community/parakeet-tdt-0.6b-v3")
PORT = int(os.environ.get("PORT", "8000"))  # the menubar app expects 8000
RECORDINGS_DIR = os.path.join(DATA_DIR, "recordings")
os.makedirs(RECORDINGS_DIR, exist_ok=True)

# Skip files below this — a tap-and-release produces a near-empty WAV, not speech.
MIN_WAV_BYTES = 10_000
# A 200-OK degenerate result (repetition collapse / near-empty on real audio) sits
# at ~0 chars/sec; a 0.5 ch/s floor clears even slow, pause-heavy dictations while
# catching genuine collapses. On degenerate we SURFACE a failure (the WAV is on
# disk to re-transcribe) rather than paste garbage.
MIN_CHARS_PER_SECOND = 0.5

_LK = threading.Lock()

print(f"loading {MODEL} …", flush=True)
M = from_pretrained(MODEL)
_tmp = os.path.join(RECORDINGS_DIR, f".warm-{secrets.token_hex(4)}.wav")
sf.write(_tmp, np.zeros(16000, dtype="float32"), 16000)
M.transcribe(_tmp)  # warm
os.remove(_tmp)
print(f"whisperown backend warm, ready on 127.0.0.1:{PORT}", flush=True)


def wav_duration_sec(path):
    try:
        info = sf.info(path)
        return info.frames / info.samplerate if info.samplerate else None
    except Exception:
        return None


def transcribe_file(path):
    """(text, duration_sec, source). Raises on degenerate output so the caller can
    surface a visible failure. A sub-threshold file returns "" (logged, not run)."""
    dur = wav_duration_sec(path)
    if os.path.getsize(path) < MIN_WAV_BYTES:
        return "", dur, None
    with _LK:
        # Chunk long audio (with overlap) rather than one giant pass — a single
        # pass silently drops the tail of long recordings. Files shorter than
        # chunk_duration are a single chunk, so short dictations are unaffected.
        raw = getattr(M.transcribe(path, chunk_duration=60.0, overlap_duration=15.0), "text", "")
    raw = re.sub(r"\s+", " ", raw).strip()
    if dur is not None and dur > 10 and len(raw) < dur * MIN_CHARS_PER_SECOND:
        raise ValueError(f"degenerate output: {len(raw)} chars for {dur:.1f}s")
    return raw, dur, "parakeet"


def save_recording(body):
    name = f"{int(time.time() * 1000)}-{secrets.token_hex(4)}.wav"
    path = os.path.join(RECORDINGS_DIR, name)
    with open(path, "wb") as f:
        f.write(body)
    return path


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/transcribe":
            self._json(404, {"error": "not found"})
            return
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        wav_path = save_recording(body)
        try:
            raw, dur, source = transcribe_file(wav_path)
        except Exception as e:
            # Surface as a failure — the app flashes amber and keeps the WAV.
            self._json(500, {"error": str(e)})
            return
        text = postprocess(raw)
        dur_ms = None if dur is None else round(dur * 1000)
        rid = db.save(wav_path, text, dur_ms, source)
        print(f"[{time.strftime('%H:%M:%S')}] transcribed: {raw!r} (id={rid})", flush=True)
        self._json(200, {"text": text, "id": rid})

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/history":
            qs = urllib.parse.parse_qs(parsed.query)
            limit = min(int(qs.get("limit", ["50"])[0] or 50), 200)
            self._json(200, db.history(limit))
            return
        if parsed.path == "/rules":
            self._json(200, RULES)
            return
        self._json(404, {"error": "not found"})


# Single-threaded on purpose: MLX streams are thread-local and dictation is one
# request at a time, so all transcription runs on the main thread.
if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
