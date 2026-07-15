> **Historical document.** The chunked-streaming architecture described here was
> removed once every backend became whole-file-on-stop (a warm model server made
> streaming-while-talking unnecessary — see docs/BENCHMARKS.md). Kept because the
> failure analysis (seam artifacts, VAD cut tuning, mid-word splits) explains
> several rules that survive in `backend/postprocess.js`.

# Voice-to-Text: chunked-streaming transcription spec

Status: **implemented** (2026-05-22). Backend live; Swift built, pending the
TCC re-grant cutover. Built per the decisions in §9: paste all-at-once, fixed
0.015 RMS VAD threshold, 0.6s silence cut / 1.5s min / 20s max-cap, upload
concurrency 3, per-chunk WAVs kept on disk under `recordings/sessions/<id>/`.
Goal: kill the post-stop wait on multi-minute dictations by transcribing
*while you speak* instead of all-at-once after you stop.

---

## 1. The problem, measured

Today the entire pipeline is **batch and post-hoc**: nothing transcribes until
you press Globe the second time, then everything runs serially.

```
press Globe (stop)
  └─ Swift finalizes WAV, reads whole file into RAM      VoiceToText.swift:247
      └─ POST whole file → localhost:8000
          └─ multer buffers the ENTIRE body              server.js:20
              └─ backend reads file again, POSTs whole    transcribe.js:99
                 file → DGX whisper-server
                  └─ whisper transcribes the ENTIRE clip
                      └─ response → paste
```

So perceived latency is bounded below by *"transcribe the whole recording,
starting only after you stop."* It grows with recording length.

### Is it linear or exponential? — Linear, mildly sublinear.

Pulled 906 real transcriptions from `~/.pm2/logs/voice-to-text-backend-out.log`,
bucketed by audio length (derived from size: 16 kHz mono int16 = 32 KB/s):

| audio length | n   | median DGX time | max    | ms / sec audio |
|--------------|-----|-----------------|--------|----------------|
| 0–5s         | 240 | 0.35s           | 1.7s   | 132            |
| 5–15s        | 251 | 0.55s           | 2.0s   | 62             |
| 15–30s       | 134 | 0.83s           | 3.7s   | 40             |
| 30–60s       | 123 | 1.48s           | 10.1s  | 34             |
| 60–120s      | 97  | 2.30s           | 5.6s   | 28             |
| **120s+**    | 61  | **3.86s**       | 18.1s  | 20             |

Fit: **~250 ms fixed + ~20 ms per second of audio** (DGX runs ~40–50× realtime).
Per-second cost *drops* as clips lengthen (fixed overhead amortizes) — the
opposite of exponential. A 3-min clip ≈ 4s; a 10-min clip ≈ 12s.

### Where the painful 30s waits actually come from

Not exponential blowup. Three tail causes:

1. **Local fallback.** DGX unreachable or returns degenerate output → falls back
   to `whisper-cli` on the Mac at ~0.3–0.5× realtime. A 3-min clip = 60–90s
   locally. This is the worst case. (Only 4 fallbacks in the whole log, but
   brutal when hit.)
2. **Network blips** — the 10–18s maxes above.
3. Median multi-minute experience is ~4s; the 30s is the long tail.

---

## 2. Goals and hard constraints

- **G1.** Perceived post-stop latency ≈ constant (one chunk), independent of
  recording length.
- **C1 — RAM/CPU (the MacBook lag concern).** No ffmpeg. No per-chunk subprocess
  spawn. No growing in-memory buffer of the whole recording. Only small,
  bounded buffers that are freed after each chunk ships. *(The old ffmpeg
  downsample that lagged the machine was removed in commit `598684d`; this
  design must not reintroduce that class of cost.)*
- **C2.** Reuse the existing DGX `whisper-server /inference` batch endpoint.
  No new model, no streaming-ASR rewrite.
- **C3.** Final text quality ≥ today. Don't split words at chunk boundaries.
- **C4.** Keep the local-`whisper-cli` fallback working.

---

## 3. Chosen direction — Option A: chunk while recording

Cut the live audio into pieces and ship each piece to the backend *as it is
produced*. By the time you stop, everything except the final phrase is already
transcribed, so the post-stop wait collapses to "~one chunk."

Three sub-variants for *how* to cut:

### A1 — Fixed-interval chunks (e.g. every N seconds)
Simplest. **Rejected as primary:** cuts land mid-word → garbled boundaries.
Salvageable only with overlap windows + dedup, which is fiddly and error-prone.

### A2 — Silence/VAD-based chunks ✅ recommended
Cut only at natural pauses. Each chunk is a whole utterance, so whisper sees
clean input and quality matches today. Needs a cheap energy-based
voice-activity detector in the Swift recorder (no ML, a few float ops per
buffer — satisfies C1).

### A3 — Hybrid (A2 + safety cap) ✅ this is what we actually build
A2, plus: if someone talks continuously past `MAX_CHUNK_MS` with no pause,
force-cut at a buffer boundary so a chunk can't grow unbounded (protects RAM
and latency). Force-cuts are rare; optionally carry a small audio overlap into
the next chunk to hide the seam.

**Decision: implement A3** (silence-preferred, with a hard duration cap).

---

## 4. Architecture

```
                       AVAudioEngine tap (already exists, 4096-frame buffers)
                                  │  converted to 16 kHz int16 (already exists)
                ┌─────────────────┴─────────────────┐
                ▼                                    ▼
   (a) full-session WAV file              (b) current-chunk sample buffer
       written as today                       (small Data, bounded by MAX_CHUNK_MS)
       — canonical record + fallback          + running RMS energy → VAD state machine
                │                                    │
                │                          on silence-cut OR max-cap:
                │                            wrap buffer in a clean 44-byte
                │                            PCM WAV header, ship as chunk seq=N,
                │                            clear buffer
                ▼                                    ▼
        used only if chunked            POST /session/:id/chunk  (multipart, seq=N)
        path fails (fallback)                        │
                                                     ▼
                                          backend transcribes each chunk
                                          independently, holds results by seq
                                                     │
                              press Globe (stop) ────┤ ship final partial chunk
                                                     ▼
                                          POST /session/:id/finish
                                                     │ wait for in-flight chunks,
                                                     │ join by seq, postprocess
                                                     │ whole text, save to db
                                                     ▼
                                          return final text → Swift pastes
```

### 4a. Swift recorder changes (`AudioRecorder` in VoiceToText.swift)

The tap callback already produces converted 16 kHz int16 buffers
([VoiceToText.swift:887](VoiceToText.swift:887)). Add, inside that callback:

- **Energy VAD.** Compute RMS of the buffer (sum of squares). Compare to a
  noise-floor threshold with a short hangover, giving a speech/silence state.
- **Two consumers of each converted buffer:**
  1. existing `audioFile.write(...)` → canonical full-session WAV (unchanged).
  2. append samples to a small `currentChunk` `Data` buffer.
- **Cut logic (state machine):**
  - In speech, then silence persists `> SILENCE_CUT_MS` **and** chunk
    `≥ MIN_CHUNK_MS` → emit chunk, clear buffer.
  - Chunk reaches `MAX_CHUNK_MS` with no pause → force-emit (optional small
    overlap retained).
  - Leading silence before first speech is dropped (don't ship empty chunks).
- **Emit = build a clean WAV in memory** (canonical 44-byte PCM header +
  the int16 samples — trivial, no ffmpeg) and hand it to an uploader with a
  monotonic `seq`. Then free the buffer.
- **On stop:** flush whatever is in `currentChunk` as the final chunk, then
  call `/session/:id/finish`.

New tunables (constants, easy to tweak):
`SILENCE_CUT_MS` (~600), `MIN_CHUNK_MS` (~1500), `MAX_CHUNK_MS` (~20000),
`VAD_RMS_THRESHOLD`, `VAD_HANGOVER_MS`.

Chunk buffer RAM ceiling = `MAX_CHUNK_MS` × 32 KB/s ≈ **~640 KB at 20s** — freed
after each ship. Satisfies C1.

### 4b. Upload / ordering

- Each chunk POSTed with `session` id + `seq`. Cap concurrency low (2–3) so we
  don't flood; the DGX whisper-server likely serializes internally anyway —
  fine, since chunks still overlap with continued recording.
- Out-of-order completion is expected; reassembly is by `seq`, not arrival.

### 4c. Backend changes (`backend/`)

New session-scoped endpoints (replace the single `/transcribe` for the app;
keep `/transcribe` for compatibility / one-shot):

- `POST /session/start` → `{ sessionId }` *(or implicit: first chunk with a
  client-generated id creates the session).*
- `POST /session/:id/chunk` (multipart `audio`, field `seq`) → transcribe that
  chunk via the existing remote/local path in [transcribe.js](backend/transcribe.js),
  store `results[seq] = text`. Return `202` (and optionally the partial text).
- `POST /session/:id/finish` → await all in-flight chunk promises, join
  `results` in `seq` order with spaces, run `postprocess` **once on the joined
  text** (so acronym/dictionary logic behaves exactly as today —
  [postprocess.js:19](backend/postprocess.js:19)), `db.save(...)` the full text,
  return `{ text, id }`. Drop the session.

Session state is just an in-memory `Map<sessionId, {results, inflight}>` with a
TTL sweep so an abandoned session (app crash) can't leak. No DB schema change —
`db.save` still stores one row per completed dictation
([server.js:34](backend/server.js:34)).

### 4d. Fallback (C4)

The canonical full-session WAV (4a, consumer 1) is still written. If the
chunked path errors (chunk upload failures, session timeout, gaps in `seq`),
Swift falls back to today's behavior: POST the whole file to a one-shot
`/transcribe`. Cheap insurance — the full file is written regardless.

---

## 5. Latency model: before → after

| scenario              | today (post-stop wait) | with A3            |
|-----------------------|------------------------|--------------------|
| 10s clip              | ~0.5s                  | ~0.5s (no change)  |
| 1-min clip            | ~1.5s                  | ~0.5–1s            |
| 3-min clip            | ~4s                    | **~0.5–1s**        |
| 3-min, local fallback | 60–90s                 | **~1–2s** (last chunk only) |

The win scales with length — exactly the multi-minute case you flagged. Very
short clips don't change (already fast; fixed overhead dominates).

---

## 6. Resource analysis (the MacBook concern)

| resource | today | with A3 |
|----------|-------|---------|
| subprocess spawns | 0 (ffmpeg already removed) | 0 — **unchanged** |
| peak app RAM | whole WAV read into Data on stop | bounded ~640 KB chunk buffer; full WAV stays on disk |
| CPU during record | converter only | converter + RMS energy (negligible) |
| network | 1 big POST after stop | many small POSTs during record (more requests, same total bytes) |
| disk | 1 WAV | 1 WAV (chunks built in memory, not written) |

Net: **lower peak RAM than today** (we stop slurping the whole file into a Data
blob on stop), no new subprocesses, trivial extra CPU.

---

## 7. Related bug to fix alongside (cheap, found while measuring)

Every backend log line reads `dur=?` — `wavDurationSec`
([transcribe.js:58](backend/transcribe.js:58)) is broken. `AVAudioFile` writes a
non-canonical header (`JUNK` + `FLLR` padding chunks), so `fmt ` lands at byte
48, not 20; the parser reads fixed offsets 20/24/44, sees garbage, returns
`null`. Consequences:

- Remote timeout never scales with length — always the 30s floor.
- **The degenerate-output guard never fires on the remote path** (gated on
  `durationSec !== null`, [transcribe.js:110](backend/transcribe.js:110)) — so a
  whisper repetition-loop collapse now passes through silently instead of
  retrying locally. Regression from the native-16kHz switch.

Fix: walk the RIFF chunk list properly (or compute duration from size:
`(fileSize − headerSize) / 32000`). The new chunk path writes *canonical*
headers, so this mainly matters for the full-file fallback and the degenerate
guard. Worth doing regardless of the streaming work.

---

## 8. Alternatives considered (not chosen)

- **Option B — true streaming ASR** (`whisper-stream` / websocket, partial
  hypotheses as you speak). Words appear live, but whisper isn't natively
  streaming → sliding-window decoding, lower accuracy, a DGX-side streaming
  endpoint, and a much bigger rewrite. Overkill unless live on-screen text is a
  goal. Violates C2.
- **Option C — overlap upload only.** Stream raw audio to the backend during
  recording so the file's already on the DGX at stop, but still transcribe in
  one batch at the end. Removes upload time (small) but **not** inference time
  (the dominant cost). Weak on its own; it's effectively a subset of A.

---

## 9. Open parameters / things to decide before building

1. **Paste mode:** all-at-once at stop (current behavior, just faster) vs.
   incremental paste as each chunk returns. Spec defaults to all-at-once.
2. VAD threshold tuning — energy threshold is environment-sensitive; may want a
   short auto-calibration from the first ~300 ms of silence.
3. Concurrency cap for chunk uploads (2–3?) and whether the DGX server
   serializes regardless.
4. Session id source (Swift-generated UUID, implicit-create on first chunk).
5. Whether to keep per-chunk WAVs on disk for debugging or build them purely in
   memory (spec assumes in-memory).
```
