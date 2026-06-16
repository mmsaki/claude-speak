#!/usr/bin/env bash
# speak.sh [step|stop]
# Hook entry. step = PreToolUse (read prose written so far); stop = end of turn.
# Enqueues newly-written cleaned prose as audio segments (chunked, never dropped).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$DIR/lib.sh"

mode="${1:-step}"
payload=$(cat)
transcript=$(printf '%s' "$payload" | /usr/bin/jq -r '.transcript_path // empty')
sid=$(printf '%s' "$payload" | /usr/bin/jq -r '.session_id // empty')
[ -f "$transcript" ] || exit 0
[ -n "$sid" ] || sid=$(printf '%s' "$transcript" | /usr/bin/shasum | cut -d' ' -f1)

sd=$(cs_session_dir "$sid"); mkdir -p "$sd/segs"
cs_voice_on "$sd" || exit 0     # voice off (sounds-only mode) -> don't narrate
printf '%s' "$sd" > "$CS_HOME/current"          # newest active session (for the CLI)

cs_enqueue_new "$sd" "$transcript" 1 || true
cs_ensure_player "$sd"

# Follow mode: if we're lagging past MAX_LAG, nudge the player to catch up now.
if [ -n "${CLAUDE_TTS_MAX_LAG:-}" ] && [ -f "$sd/player.pid" ]; then
  ppos=$(cat "$sd/pos" 2>/dev/null || echo 1); tot=$(cs_seg_count "$sd")
  [ $((tot - ppos)) -gt "$CLAUDE_TTS_MAX_LAG" ] && kill -USR1 "$(cat "$sd/player.pid")" 2>/dev/null || true
fi

if [ "$mode" = stop ]; then
  : > "$sd/resp_pending"    # next turn starts a new response
  # The final message often lands in the transcript a beat AFTER Stop fires, so
  # a single read here would speak it one turn late. Poll briefly to catch it
  # now (no boundary marking — it belongs to the response we just finished).
  ( for _ in 1 2 3 4 5 6; do sleep 0.5; cs_enqueue_new "$sd" "$transcript" 0 || true; done ) >/dev/null 2>&1 &
fi
exit 0
