#!/usr/bin/env bash
# player.sh <session-dir>
# Background daemon: plays queued audio segments in order, obeys a control FIFO.
# bash 3.2 safe: commands arrive via a blocking reader that signals us (SIGUSR1),
# which interrupts playback instantly; idle waits use `sleep` (fractional ok).
# Control words (one per line on $sd/control):
#   next prev replay last goto<sp>N pause resume toggle stop rprev rnext clear quit
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$DIR/lib.sh"

sd="$1"
mkdir -p "$sd/segs"
fifo="$sd/control"
cmdq="$sd/cmdq"; : > "$cmdq"
[ -p "$fifo" ] || { rm -f "$fifo"; mkfifo "$fifo"; }
PLAY="${CLAUDE_TTS_PLAY_CMD:-/usr/bin/afplay}"

pos=$(cat "$sd/pos" 2>/dev/null || echo 1)
paused=0; INT=0; apid=""
muted=0; [ -f "$sd/muted" ] && muted=1

qlock() { local n=0; while ! mkdir "$sd/cmdq.lock" 2>/dev/null && [ $n -lt 100 ]; do sleep 0.02; n=$((n+1)); done; }
qunlock() { rmdir "$sd/cmdq.lock" 2>/dev/null || true; }

# Reader: blocks on the FIFO, queues each command, pokes the main process.
( exec 9<>"$fifo"
  while IFS= read -r line <&9; do
    qlock; printf '%s\n' "$line" >> "$cmdq"; qunlock
    kill -USR1 $$ 2>/dev/null || exit 0
  done ) &
READER=$!
trap 'INT=1; [ -n "$apid" ] && kill "$apid" 2>/dev/null' USR1
trap 'kill "$READER" 2>/dev/null; rm -f "$fifo"; exit 0' TERM INT

resp_before() { awk -v p="$1" '$1<p{c=$1} END{print c?c:1}' "$sd/responses" 2>/dev/null; }
resp_after()  { awk -v p="$1" '$1>p{print $1; exit}' "$sd/responses" 2>/dev/null; }

handle() {
  local total; total=$(cs_seg_count "$sd")
  set -- $1
  case "${1:-}" in
    next)   pos=$((pos+1)); INT=1 ;;
    prev)   pos=$((pos>1 ? pos-1 : 1)); INT=1 ;;
    replay) INT=1 ;;
    last)   pos=$total; INT=1 ;;
    goto)   [ -n "${2:-}" ] && pos="$2"; INT=1 ;;
    rprev)  pos=$(resp_before "$pos"); INT=1 ;;
    rnext)  local n; n=$(resp_after "$pos"); [ -n "$n" ] && pos="$n"; INT=1 ;;
    pause|stop) paused=1; INT=1 ;;
    resume)     paused=0 ;;
    toggle) if [ "$paused" = 1 ]; then paused=0; else paused=1; INT=1; fi ;;
    mute)   muted=1; : > "$sd/muted"; INT=1 ;;
    unmute) muted=0; rm -f "$sd/muted" ;;
    mutetoggle) if [ "$muted" = 1 ]; then muted=0; rm -f "$sd/muted"; else muted=1; : > "$sd/muted"; INT=1; fi ;;
    clear)  rm -f "$sd"/segs/* 2>/dev/null; : > "$sd/responses"; pos=1; INT=1 ;;
    quit)   kill "$READER" 2>/dev/null; rm -f "$fifo"; exit 0 ;;
  esac
  [ "$pos" -lt 1 ] && pos=1
  [ "$total" -gt 0 ] && [ "$pos" -gt $((total+1)) ] && pos=$((total+1))
}

drain() {
  qlock
  if [ -s "$cmdq" ]; then
    while IFS= read -r c; do [ -n "$c" ] && handle "$c"; done < "$cmdq"
    : > "$cmdq"
  fi
  qunlock
}

nap() { sleep "${1:-0.5}" & wait $! 2>/dev/null; }   # interruptible by SIGUSR1

while true; do
  drain
  # Muted: silent, but ride the live edge so unmute is current (no backlog).
  if [ "$muted" = 1 ]; then
    pos=$(( $(cs_seg_count "$sd") + 1 )); echo "$pos" > "$sd/pos"; nap 0.5; continue
  fi
  # Follow mode: never fall more than MAX_LAG segments behind the newest.
  if [ -n "${CLAUDE_TTS_MAX_LAG:-}" ]; then
    total=$(cs_seg_count "$sd")
    [ $((total - pos)) -gt "$CLAUDE_TTS_MAX_LAG" ] && pos=$((total - CLAUDE_TTS_MAX_LAG))
  fi
  echo "$pos" > "$sd/pos"

  if [ "$paused" = 1 ]; then nap 0.5; continue; fi
  txt=$(cs_seg_txt "$sd" "$pos")
  [ -f "$txt" ] || { nap 0.5; continue; }         # nothing enqueued at this position yet

  audio=$(cs_seg_audio "$sd" "$pos")
  if [ -z "$audio" ]; then                         # on-demand synth: only what we play
    cat "$txt" | bash "$CS_DIR/synth.sh" "${txt%.txt}" >/dev/null 2>&1
    audio=$(cs_seg_audio "$sd" "$pos")
  fi
  [ -z "$audio" ] && { nap 0.5; continue; }        # synth failed

  # Prefetch next segment in the background to smooth sequential playback.
  ntxt=$(cs_seg_txt "$sd" $((pos+1)))
  if [ -f "$ntxt" ] && [ -z "$(cs_seg_audio "$sd" $((pos+1)))" ]; then
    ( cat "$ntxt" | bash "$CS_DIR/synth.sh" "${ntxt%.txt}" ) >/dev/null 2>&1 &
  fi

  # Wait for the shared speaker (other sessions), staying responsive.
  until cs_speaker_try; do
    drain
    [ "$paused" = 1 ] && break
    [ "$(cs_seg_audio "$sd" "$pos")" != "$audio" ] && break
    nap 0.5
  done
  if [ "$paused" = 1 ] || [ "$(cs_seg_audio "$sd" "$pos")" != "$audio" ]; then
    cs_speaker_release; continue
  fi

  INT=0
  if [ -n "${CLAUDE_TTS_RATE:-}" ] && [ "$PLAY" = "/usr/bin/afplay" ]; then
    "$PLAY" -r "$CLAUDE_TTS_RATE" "$audio" & apid=$!   # extra speedup (raises pitch)
  else
    "$PLAY" "$audio" & apid=$!
  fi
  wait "$apid" 2>/dev/null        # SIGUSR1 trap kills apid -> wait returns
  apid=""
  cs_speaker_release
  drain
  [ "$INT" = 0 ] && pos=$((pos+1))   # natural end -> advance
done
