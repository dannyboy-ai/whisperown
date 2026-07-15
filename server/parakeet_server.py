# Local Parakeet-MLX backend — same POST /transcribe (raw WAV) -> {text} contract
# as nemo_server.py, but runs on THIS Mac's GPU via MLX (no remote box needed).
# WAV is decoded with soundfile (libsndfile), NOT ffmpeg — so it sidesteps the
# parakeet_mlx ffmpeg/x265 audio path entirely.
import os, json, time, tempfile, threading
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
from http.server import BaseHTTPRequestHandler, HTTPServer
import numpy as np, soundfile as sf, mlx.core as mx
import parakeet_mlx.audio as _pa, parakeet_mlx.parakeet as _pk

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
PORT = int(os.environ.get("PORT", "8005"))
_LK = threading.Lock()

print(f"loading {MODEL} …", flush=True)
M = from_pretrained(MODEL)
_tmp = tempfile.mktemp(suffix=".wav")
sf.write(_tmp, np.zeros(16000, dtype="float32"), 16000)
M.transcribe(_tmp)  # warm
os.remove(_tmp)
print(f"parakeet warm, ready on 127.0.0.1:{PORT}", flush=True)

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        if self.path != "/transcribe":
            self.send_response(404); self.end_headers(); return
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        p = tempfile.mktemp(suffix=".wav")
        with open(p, "wb") as f: f.write(body)
        t0 = time.time()
        try:
            info = sf.info(p); dur = info.frames / info.samplerate
            with _LK:
                text = getattr(M.transcribe(p), "text", "").strip()
        except Exception as e:
            self.send_response(500); self.end_headers()
            self.wfile.write(json.dumps({"error": str(e)}).encode()); return
        finally:
            try: os.remove(p)
            except: pass
        ms = round((time.time() - t0) * 1000)
        out = json.dumps({"text": text, "infer_ms": ms, "audio_s": round(dur, 1),
                          "rtfx": round(dur / (ms / 1000), 1) if ms else 0}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers(); self.wfile.write(out)

# Single-threaded on purpose: MLX streams are thread-local and dictation is
# one request at a time, so all transcription runs on the main thread.
HTTPServer(("127.0.0.1", PORT), H).serve_forever()
