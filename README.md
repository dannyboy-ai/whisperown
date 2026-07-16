<p align="center"><img src="docs/assets/banner.png" alt="WhisperOwn — a whisper you own, for macOS" width="100%"></p>

# WhisperOwn

<p align="center">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-Apple_silicon-111?logo=apple">
  <img alt="license" src="https://img.shields.io/badge/license-MIT-2dd4bf">
  <img alt="tests" src="https://img.shields.io/badge/tests-162_passing-3fce7a">
  <img alt="local" src="https://img.shields.io/badge/audio-100%25_local-e8a34c">
  <img alt="lang" src="https://img.shields.io/badge/Swift_+_Python-2_parts-8fa3b8">
</p>

**A whisper you own.** Press the Globe key. Talk. Press it again — your words are
pasted where your cursor is, already cleaned up. Everything runs **locally on your
Mac's own silicon**: no cloud, no accounts, no telemetry. Your audio and the
compute never leave the machine. (The name nods to Wispr Flow — this is the
self-hosted answer to it.)

It's two parts: a small macOS menubar app (Swift) and one local backend (Python) that
transcribes on your GPU and cleans up the text. Both on localhost.

<p align="center"><img src="docs/assets/how-it-works.png" alt="1 press globe, 2 talk, 3 press globe again, 4 it's typed at your cursor" width="100%"></p>

## Why this exists

Commercial dictation (Wispr Flow, Superwhisper, macOS dictation) is cloud-bound,
slow to start, subscription-gated, or mangles technical vocabulary. This one is:

- **Fast.** Parakeet on Apple Silicon transcribes a typical dictation in well under
  a second (~50 ms for a 4 s clip, ~500 ms for a full minute on an M4 Max) — measured.
- **Local.** The model runs on your Mac's GPU via MLX. No network, no GPU box,
  nothing to reach. (First launch downloads the model once; after that it's offline.)
- **Honest about cleanup.** A deterministic pipeline strips silence-hallucinations
  ("thank you."), fillers, restart-stutters, and echoes — and it **never rewrites
  your words with an LLM.** See [POSTPROCESS.md](POSTPROCESS.md).
- **Small.** A menubar app and one Python file's worth of backend. Nothing to run
  but a single login agent.

## Requirements

- **Apple Silicon Mac** (M1 or newer). The model runs on the GPU via MLX — Intel
  Macs are not supported.
- **macOS 13 Ventura or later** (the System Settings steps below use the modern
  layout; developed on macOS 26).
- **Xcode Command Line Tools** — `xcode-select --install`. Needed to compile the app.
- **Python 3.10+** (the system `python3` on a current macOS is fine).

---

## Setup

One command, then two macOS settings.

### 1. Install

```sh
./install.sh
```

That creates the Python backend (a virtualenv + the transcription deps), installs a
login **launch agent** that keeps it warm at `127.0.0.1:8000`, and builds the app
into `/Applications`. The first time the agent starts it downloads the Parakeet model
(a few hundred MB) — after that it's fully offline. Re-run `./install.sh` anytime
after a pull; it's idempotent.

Then open it:

```sh
open /Applications/WhisperOwn.app
```

A small icon appears in your menubar. There's no Dock icon and no window — this is a
menubar-only app. **On first launch a Permissions Guide opens** and walks you through
the next two steps one at a time (no permission prompt fires until you click the step
it belongs to). Reopen it anytime from the menubar → **Permissions Guide…**.

### 2. Free up the Globe key  ← the step everyone forgets

WhisperOwn's record toggle **is** the Globe key (🌐, bottom-left of a Mac keyboard;
on keyboards without it, the **Fn** key is the same key). By default macOS binds that
key to the emoji picker or input-source switching, so if you don't reassign it,
pressing Globe pops up emoji *and* fights the app.

> **System Settings → Keyboard →** the **"Press 🌐 key to"** dropdown → choose
> **"Do Nothing."**

It doesn't affect your F1–F12 keys — only the special single-press Globe action.

### 3. Grant two permissions

The first time you press Globe to record, macOS will ask for these. Both are required:

- **Microphone** — to hear you. Prompted on first record; approve it.
- **Accessibility** — the important one. It lets the app *see* the Globe keypress
  system-wide and *paste* into other apps. Grant it under **System Settings → Privacy
  & Security → Accessibility** (toggle **WhisperOwn** on). The app deep-links you
  straight to this pane and auto-relaunches within a second of the grant.

  If you have an **Apple Development / Developer ID** signing identity (from Xcode or a
  paid account), `build.sh` auto-detects and signs with it, and the Accessibility
  grant **persists across rebuilds** — grant it once. Without any identity it falls
  back to **ad-hoc** signing, where each rebuild changes the binary's fingerprint and
  invalidates the grant, so you must re-toggle WhisperOwn after every rebuild.
  (`security find-identity -v -p codesigning` shows what you have; set
  `WHISPEROWN_SIGN_ID="<name>"` to force one.)

### 4. Dictate

Press **Globe** — the menubar icon turns red (recording). Talk. Press **Globe** again
— a beat later, your cleaned-up text lands at the cursor, wherever you are. Re-paste
the last one anytime with **Ctrl+Cmd+V**.

---

## Everyday use

| Menu item | What it does |
|---|---|
| **Show History** | Your past dictations — play back the audio, re-copy the text. |
| **Re-transcribe last** / **Reveal recording in Finder** | Recover a dictation if transcription failed. |
| **Dictionary…** | Your personal "it always mishears X → Y" fixes (view + add). |
| **Cleanup Rules…** | View the active post-processing rules (read-only; edit via your agent — see [POSTPROCESS.md](POSTPROCESS.md)). |
| **Permissions Guide…** | Re-open the first-run permissions walkthrough anytime. |

If the backend is ever unreachable, a dictation fails **visibly** (the icon flashes
amber) and the WAV is saved — recover it with **Re-transcribe last**. There is no
silent cloud fallback; a failure is always one you can see and replay.

## Customizing

- **Dictionary** — the fastest lever. From the menubar, add `heard → meant` pairs for
  words the model reliably gets wrong (names, jargon, your own coinages). Applied as
  whole-word replacements. This is *your* data and lives outside the repo.
- **`server/postprocess.py`** — the deterministic cleanup pipeline. Every rule is
  documented in plain English in [POSTPROCESS.md](POSTPROCESS.md). Edit by hand or
  hand it to your LLM, then run the guard:
  ```sh
  cd server && ./.venv/bin/python test_postprocess.py
  ```

## How it fits together

```
┌─ menubar app (Swift) ─┐   raw WAV    ┌─ backend (Python :8000) ───────┐
│ Globe hotkey          ├─────────────►│ Parakeet-MLX transcribe (GPU)  │
│ record 16kHz mono     │              │ postprocess (fillers, stutters,│
│ paste at cursor       │◄─────────────┤   dictionary)                  │
└───────────────────────┘    text +    │ SQLite history                 │
                             history    └────────────────────────────────┘
```

The app only ever talks to its own localhost backend. Nothing reaches the network
(except the one-time model download on first run).

## Troubleshooting

- **Pressing Globe pops up emoji / switches my keyboard language.** You skipped
  step 2 — set "Press 🌐 key to" → "Do Nothing."
- **Nothing happens when I press Globe.** Accessibility isn't granted (or was
  invalidated by a rebuild). Re-toggle WhisperOwn under Privacy & Security →
  Accessibility.
- **Recording works but nothing pastes.** Same Accessibility grant — it powers both
  the keypress capture and the paste.
- **Icon flashes amber.** The backend isn't reachable. It's a launch agent, so
  `launchctl list | grep whisperown` and re-`load` it if needed (the log is at
  `~/Library/Logs/whisperown.log`). Your recording is safe — use **Re-transcribe last**.

## Docs

- [POSTPROCESS.md](POSTPROCESS.md) — every cleanup rule in plain English.

## Privacy

No accounts, no telemetry, no network calls after the one-time model download. Audio,
transcripts, and history stay in `~/Library/Application Support/WhisperOwn/` on your
machine. Deleting that folder erases everything.

## Uninstall

Removes everything cleanly, in reverse of setup:

```sh
# 1. stop + remove the backend launch agent
launchctl unload ~/Library/LaunchAgents/com.whisperown.server.plist
rm ~/Library/LaunchAgents/com.whisperown.server.plist

# 2. remove the app
rm -rf /Applications/WhisperOwn.app

# 3. erase all recordings, history, and settings
rm -rf ~/Library/Application\ Support/WhisperOwn/
```

Finally, remove **WhisperOwn** from System Settings → Privacy & Security →
Accessibility and Microphone.

## Expectations

Software I run every day, shared as-is. PRs welcome; issues may sit; no roadmap.
Fork freely.

## License

MIT
