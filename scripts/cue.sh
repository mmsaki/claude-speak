#!/usr/bin/env bash
# cue.sh <name>  — play a procedural sound cue. Renders the WAV set on first use.
# Disable all cues with: export CLAUDE_CUES=0
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$DIR/lib.sh"
[ "${CLAUDE_CUES:-1}" = "0" ] && exit 0

name="${1:-}"; [ -n "$name" ] || exit 0
sounds="$CS_HOME/sounds"

# Render once (cached). Lock so concurrent hooks don't race the generator.
if [ ! -f "$sounds/.rendered" ]; then
  lk="$CS_HOME/render.lock"
  if mkdir "$lk" 2>/dev/null; then
    /usr/bin/env python3 "$CS_DIR/gen_sounds.py" "$sounds" >/dev/null 2>&1
    rmdir "$lk" 2>/dev/null || true
  else
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$sounds/.rendered" ] && break; sleep 0.3; done
  fi
fi

wav="$sounds/$name.wav"
[ -f "$wav" ] || exit 0
# Fully detach so the hook returning can't cut the sound short.
nohup /usr/bin/afplay "$wav" >/dev/null 2>&1 &
disown 2>/dev/null || true
exit 0
