#!/usr/bin/env bash
# speak.sh [step|stop]
# Hook entry. step = PreToolUse (read prose written so far); stop = end of turn
# (flush remaining prose, then mark a response boundary so the next turn is a new
# "response" for replay navigation). Enqueues cleaned prose as audio segments.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$DIR/lib.sh"
[ "${CLAUDE_TTS:-1}" = "0" ] && exit 0

mode="${1:-step}"
payload=$(cat)
transcript=$(printf '%s' "$payload" | /usr/bin/jq -r '.transcript_path // empty')
sid=$(printf '%s' "$payload" | /usr/bin/jq -r '.session_id // empty')
[ -f "$transcript" ] || exit 0
[ -n "$sid" ] || sid=$(printf '%s' "$transcript" | /usr/bin/shasum | cut -d' ' -f1)

sd=$(cs_session_dir "$sid"); mkdir -p "$sd/segs"
printf '%s' "$sd" > "$CS_HOME/current"          # newest active session (for the CLI)

# New cleaned prose since the spoken cursor.
prose=$(cs_assistant_prose "$transcript")
L=${#prose}
lock="$sd/cursor.lock"; n=0
while ! mkdir "$lock" 2>/dev/null && [ $n -lt 40 ]; do sleep 0.05; n=$((n+1)); done
C=$(cat "$sd/cursor" 2>/dev/null || echo 0); [ "$C" -le "$L" ] 2>/dev/null || C=0
new="${prose:$C}"
echo "$L" > "$sd/cursor"
rmdir "$lock" 2>/dev/null || true

new=$(printf '%s' "$new" | head -c "${CLAUDE_TTS_MAXCHARS:-1500}" | tr '\n' ' ' \
      | /usr/bin/sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')

if [ -n "$new" ] && printf '%s' "$new" | grep -q '[^[:space:]]'; then
  # Allocate the next index + reserve its .txt atomically.
  ilock="$sd/idx.lock"; n=0
  while ! mkdir "$ilock" 2>/dev/null && [ $n -lt 40 ]; do sleep 0.05; n=$((n+1)); done
  idx=$(( $(cs_seg_count "$sd") + 1 ))
  txt=$(cs_seg_txt "$sd" "$idx")
  printf '%s' "$new" > "$txt"
  # Record a response boundary at the first segment of each response.
  if [ -f "$sd/resp_pending" ] || [ ! -s "$sd/responses" ]; then
    echo "$idx" >> "$sd/responses"; rm -f "$sd/resp_pending"
  fi
  rmdir "$ilock" 2>/dev/null || true
  # NOTE: no synthesis here — the player synthesizes on demand at playback time,
  # so segments that get skipped/muted/never-reached never hit the TTS API.
fi

cs_ensure_player "$sd"

# Follow mode: if we're lagging past MAX_LAG, nudge the player to catch up now.
if [ -n "${CLAUDE_TTS_MAX_LAG:-}" ] && [ -f "$sd/player.pid" ]; then
  ppos=$(cat "$sd/pos" 2>/dev/null || echo 1); tot=$(cs_seg_count "$sd")
  [ $((tot - ppos)) -gt "$CLAUDE_TTS_MAX_LAG" ] && kill -USR1 "$(cat "$sd/player.pid")" 2>/dev/null || true
fi

# Eager-synthesize the final (Stop) answer so it reads promptly on arrival;
# intermediate PreToolUse segments stay on-demand (skipped ones cost nothing).
if [ "$mode" = stop ] && [ -n "${txt:-}" ] && [ -f "$txt" ] && [ -z "$(cs_seg_audio "$sd" "$idx")" ]; then
  ( cat "$txt" | bash "$CS_DIR/synth.sh" "${txt%.txt}" ) >/dev/null 2>&1 &
fi

[ "$mode" = stop ] && : > "$sd/resp_pending"    # next turn starts a new response
exit 0
