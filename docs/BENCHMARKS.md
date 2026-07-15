# Benchmarks

Measured 2026-07-11 (short-clip re-verification 2026-07-13). Same five real
dictations (16 kHz mono WAV, one speaker's actual voice) on every machine —
1.6s, 20s, 45s, 2min, and 5min clips, plus a true 8s clip on the two machines
still available at re-verification. Local runs
are cold (the app spawns `whisper-cli` per dictation, so every run pays the model
load — that's the real UX). Remote runs are warm and include the full
Mac → server → Mac round-trip over Tailscale. Peak RAM via `/usr/bin/time -l`
maximum RSS.

## Short dictation — the case you feel all day

An 8-second utterance, stop-talking → text-ready:

| Setup | Wall time |
|---|---|
| DGX Spark, Nemotron, warm | **0.29 s** |
| M4 Max, whisper `large-v3-turbo`, local | 1.10 s |
| M2 Pro Mac mini, whisper `large-v3-turbo`, local | ~1.5 s¹ |
| 2015 Intel MacBook Air (i5-5250U), whisper `base.en`, local | ~4 s¹ |

¹ M2 Pro and Intel were measured on a 1.6 s utterance (1.33 s and 3.4 s
respectively — see the grid) plus their measured per-second rates from the
20 s/45 s rows; short-dictation latency is dominated by the fixed model-load
floor, not utterance length.

## Full grid — recommended model per machine

Wall-clock seconds (multiple of real-time in parens).

| Audio | Spark · nemotron | M4 Max · turbo | M2 Pro · turbo | Intel '15 · base.en |
|---|---|---|---|---|
| 1.6 s | 0.18 | 1.1 | 1.33 | 3.4 |
| 8 s | 0.29 (27×) | 1.10 (7×) | — | — |
| 20 s | 0.32 (63×) | 1.1 (18×) | 1.68 (12×) | 5.9 (3.4×) |
| 45 s | 1.42 (32×) | 1.6 (28×) | 2.58 (17×) | 11.3 (4×) |
| 2 min | 1.73 (70×) | 2.6 (46×) | 5.3 (23×) | — |
| 5 min | 2.74 (110×) | 4.6 (65×) | 10.0 (30×) | — |

The Intel machine is a deliberate worst case: 2-core 1.6 GHz Broadwell. On that
chip `large-v3-turbo` takes **72 seconds** for the 1.6 s clip (unusable) — which is exactly why its recommended model is `base.en`. Any
2018+ Intel Mac sits well above this floor.

## Model spectrum (M4 Max, 2-min clip)

RAM is model-determined, not machine-determined (M2 Pro and M4 Max measure
within 5 MB of each other).

| Model | File size | Wall | Peak RAM | Verdict |
|---|---|---|---|---|
| `base.en` | 141 MB | 1.09 s | 350 MB | weak/low-RAM hardware |
| `large-v3-turbo` | 1.5 GB | 2.62 s | 1.9 GB | **default** |
| `medium.en` | 1.4 GB | 3.65 s | 2.15 GB | dominated by turbo — skip |

`large-v3-turbo` beats `medium.en` on speed, RAM, *and* accuracy, so the real
choice is turbo vs base.en.

## Memory: two different stories

- **Local = transient.** RAM is claimed for the ~1–3 s of transcription and
  released. Nothing stays resident between dictations.
- **Remote = persistent.** The GPU server holds ~12.2 GB RSS warm 24/7
  (~4.7 GB of that is fp16 Nemotron weights, plus the punctuation model and CUDA
  context). That standing reservation is what buys the ~0.3 s response — there is
  no per-request model load.

## Findings worth knowing

1. **The warm model is the whole trick.** The Spark isn't 6× faster because the
   GPU is huge; it's faster because the model never unloads. The local path's
   ~1 s floor *is* the model load.
2. **Prebuilt binaries SIGILL on old Intel.** The stock whisper.cpp Docker image
   is built with AVX-512 and dies with `Illegal instruction` on pre-2017 chips.
   Build from source with `-DGGML_AVX512=OFF -DGGML_AVX2=ON`.
3. **Model size is the load-bearing choice on weak hardware.** Same engine, one
   flag: 72 s → 3.4 s on the 2015 Intel.
