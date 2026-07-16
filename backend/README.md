# whisperown-backend

Node backend for the WhisperOwn menubar app. Receives the whole recording from the
Swift app on stop, POSTs it to the local Parakeet-MLX server, runs the deterministic
text-cleanup pipeline, and stores results in SQLite.

Endpoints: `POST /transcribe` (raw WAV body → `{text, id}`), `GET /history`,
`GET /rules` (the active cleanup-rule manifest, for the app's read-only viewer).

## Files

- `server.js` — Express server; streams the raw WAV to disk, transcribes, cleans,
  stores, and serves history.
- `paths.js` — the data directory (`~/Library/Application Support/WhisperOwn/`) and
  the one-time migration from the former "Voice-to-Text" name.
- `transcribe.js` — POSTs the WAV to the Parakeet server (`PARAKEET_URL`, default
  `127.0.0.1:8005`); surfaces failures instead of silently retrying.
- `postprocess.js` — deterministic cleanup of raw transcripts (no LLM).
- `db.js` — SQLite (better-sqlite3) history.

## Run

```bash
npm start                          # node server.js
pm2 restart whisperown-backend     # under PM2 (process name)
```

## Notes

- Short audio files (<10 KB) are skipped to avoid empty-recording errors on
  tap-and-release.
- Point transcription at a different host with the `PARAKEET_URL` env var.
- Deps: express, better-sqlite3.
