#!/bin/bash
# Reproduce the numbers in docs/BENCHMARKS.md on YOUR hardware.
#
#   ./scripts/bench.sh path/to/clip.wav [more.wav ...]
#
# No arguments? It benchmarks your 3 most recent real dictations from
# ~/Library/Application Support/Voice-to-Text/recordings/.
# Times (a) the local whisper-cli path (cold, like the app runs it) and
# (b) the configured remote server, if any — via the same HTTP call the
# backend makes. Peak RAM via /usr/bin/time.
set -euo pipefail

SUPPORT="$HOME/Library/Application Support/Voice-to-Text"
CONFIG="$SUPPORT/config.json"
WHISPER=$(python3 -c "import json;print(json.load(open('$CONFIG'))['local'].get('whisperCli','/opt/homebrew/bin/whisper-cli'))" 2>/dev/null || echo /opt/homebrew/bin/whisper-cli)
MODEL=$(python3 -c "
import json,os
try: m=json.load(open('$CONFIG'))['local'].get('model','models/ggml-large-v3-turbo.bin')
except: m='models/ggml-large-v3-turbo.bin'
print(m if os.path.isabs(m) else os.path.join('$SUPPORT', m))" 2>/dev/null)
REMOTE=$(python3 -c "
import json
try:
    r=json.load(open('$CONFIG')).get('remote',{})
    print(r.get('lan') or r.get('tailscale') or '')
except: print('')" 2>/dev/null)

CLIPS=("$@")
if [ ${#CLIPS[@]} -eq 0 ]; then
  # find+stat instead of a glob: a long-lived install can hold tens of
  # thousands of recordings, which overflows ARG_MAX.
  while IFS= read -r f; do CLIPS+=("$f"); done < <(
    find "$SUPPORT/recordings" -maxdepth 1 -name '*.wav' -print0 2>/dev/null \
      | xargs -0 stat -f '%m %N' 2>/dev/null | sort -rn | head -3 | cut -d' ' -f2-)
fi
[ ${#CLIPS[@]} -eq 0 ] && { echo "No clips. Pass WAV paths or dictate something first."; exit 1; }

echo "machine : $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)"
echo "model   : $(basename "$MODEL")"
echo "remote  : ${REMOTE:-none configured}"
echo
printf "%-28s %8s %10s %10s %10s\n" clip audio_s local_s peakRAM_MB remote_s

for f in "${CLIPS[@]}"; do
  dur=$(python3 - "$f" <<'PY'
import sys,struct
p=sys.argv[1]
with open(p,'rb') as fh:
    d=fh.read()
i=12; rate=None; data=None
while i+8<=len(d):
    cid=d[i:i+4]; sz=struct.unpack('<I',d[i+4:i+8])[0]
    if cid==b'fmt ': rate=struct.unpack('<I',d[i+12:i+16])[0]*struct.unpack('<H',d[i+10:i+12])[0]*struct.unpack('<H',d[i+22:i+24])[0]//8
    if cid==b'data': data=min(sz,len(d)-i-8); break
    i+=8+sz+(sz%2)
print(f"{data/rate:.1f}" if rate and data else "?")
PY
)
  t0=$(python3 -c 'import time;print(time.time())')
  out=$( { /usr/bin/time -l "$WHISPER" -m "$MODEL" -f "$f" --no-timestamps -np -mc 0 -l en >/dev/null; } 2>&1 )
  t1=$(python3 -c 'import time;print(time.time())')
  local_s=$(python3 -c "print(f'{$t1-$t0:.2f}')")
  ram=$(echo "$out" | awk '/maximum resident/{printf "%.0f", $1/1024/1024}')
  remote_s="-"
  if [ -n "$REMOTE" ]; then
    remote_s=$(curl -s -o /dev/null -w "%{time_total}" --data-binary @"$f" -H "Content-Type: audio/wav" "$REMOTE" 2>/dev/null || echo fail)
  fi
  printf "%-28s %8s %10s %10s %10s\n" "$(basename "$f" | cut -c1-28)" "$dur" "$local_s" "${ram:-?}" "$remote_s"
done