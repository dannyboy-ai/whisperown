# voice-to-text-backend

Node transcription backend for the WhisperOwn menubar app. Receives the whole
recording from the Swift app on stop, routes it to the configured remote model
server (with silent local-whisper fallback) or transcribes locally, runs the
text-cleanup pipeline, and stores results in SQLite.

Endpoints: `POST /transcribe` (multipart WAV → `{text, id}`), `GET /history`,
`GET /backend-status` (probes the configured remote servers).

## Files

- `server.js` — Express server; upload endpoints; writes to the recordings dir
  the Swift app shares.
- `config.js` — loads `~/Library/Application Support/Voice-to-Text/config.json`
  (endpoints, whisper binary, model); defaults are local-only.
- `transcribe.js` — remote-first routing with local `whisper-cli` fallback.
- `postprocess.js` — cleans up raw transcripts.
- `db.js` — SQLite (better-sqlite3) storage.

## Run

```bash
npm start                              # node server.js
pm2 restart voice-to-text-backend      # under PM2 (process name)
```

## Notes

- `whisper-cpp` is pinned in brew. Upgrading needs a full PM2 daemon restart
  (`pm2 kill && pm2 start server.js --name voice-to-text-backend`), not just
  `pm2 restart`.
- Short audio files (<10 KB) are skipped to avoid empty-recording errors on
  tap-and-release.
- Deps: express, better-sqlite3, multer, undici.
