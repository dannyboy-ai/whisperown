const fs = require("fs");
const path = require("path");
const os = require("os");

// All machine-specific settings live OUTSIDE the repo, in the same Application
// Support directory the app already uses for dictionary.json and backend.txt:
//
//   ~/Library/Application Support/Voice-to-Text/config.json
//
// Copy config.example.json there and edit. Everything is optional — with no
// config file at all, the backend POSTs each recording to the local Parakeet-MLX
// server on this Mac (fully offline). Routing to a remote GPU box is opt-in.
const DATA_DIR = path.join(
  os.homedir(),
  "Library/Application Support/Voice-to-Text"
);
const CONFIG_PATH = path.join(DATA_DIR, "config.json");

const DEFAULTS = {
  // Transcription endpoint overrides. Empty by default → transcribe.js uses the
  // local Parakeet-MLX server (server/parakeet_server.py) at 127.0.0.1:8005. Set
  // `parakeet` to any host that accepts a raw-WAV POST returning {text} to route
  // transcription to a remote box instead.
  remote: {},
};

function loadConfig() {
  let user = {};
  try {
    user = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf-8"));
  } catch {
    // no config file (or malformed) → pure defaults, local-only
  }
  return {
    remote: { ...DEFAULTS.remote, ...(user.remote || {}) },
  };
}

module.exports = { loadConfig, DATA_DIR, CONFIG_PATH };
