#!/usr/bin/env bash
# event.sh <event>  — central hook dispatcher. Reads the hook payload on stdin and
# fans out to sound cues, voice (TTS), and haptics for that event.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$DIR/lib.sh"

ev="${1:-}"
payload=$(cat)

cue() { bash "$CS_DIR/cue.sh" "$1"    >/dev/null 2>&1; }
hap() { bash "$CS_DIR/haptic.sh" "$1" >/dev/null 2>&1; }
voice() { printf '%s' "$payload" | bash "$CS_DIR/speak.sh" "$1"; }

case "$ev" in
  userprompt)   cue send;   hap light ;;
  pretool)      cue tick;   hap light;  voice step ;;
  posttool)
    err=$(printf '%s' "$payload" | /usr/bin/jq -r '
      (.tool_response.error? // empty),
      (if (.tool_response.is_error? // false) then "err" else empty end)' 2>/dev/null | head -1)
    [ -n "$err" ] && { cue failure; hap heavy; } ;;
  notify)       cue permission; hap medium ;;
  stop)         cue reset; hap medium; voice stop ;;
  subagentstop) cue running ;;
  sessionend)
    sid=$(printf '%s' "$payload" | /usr/bin/jq -r '.session_id // empty')
    if [ -n "$sid" ]; then
      sd=$(cs_session_dir "$sid")
      [ -f "$sd/player.pid" ] && kill "$(cat "$sd/player.pid" 2>/dev/null)" 2>/dev/null
      pkill -f "player.sh $sd" 2>/dev/null
      rm -rf "$sd"
    fi ;;
  sessionstart)
    cs_prune_sessions                                   # sweep dead sessions
    sid=$(printf '%s' "$payload" | /usr/bin/jq -r '.session_id // empty')
    if [ -n "$sid" ]; then
      sd=$(cs_session_dir "$sid"); mkdir -p "$sd/segs"
      printf '%s' "$sd" > "$CS_HOME/current"             # controls resolve immediately
      : > "$sd/resp_pending"
    fi
    mkdir -p "$CS_HOME/bin"
    ln -sf "$CS_DIR/ctl.sh" "$CS_HOME/bin/claude-speak"   # stable CLI path
    src=$(printf '%s' "$payload" | /usr/bin/jq -r '.source // empty')
    case "$src" in startup|resume|"") cue send ;; esac ;;  # not on compact/clear
esac
exit 0
