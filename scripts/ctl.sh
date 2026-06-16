#!/usr/bin/env bash
# claude-speak — drive the per-session voice player.
# Commands:
#   next | prev        move one segment forward / back
#   rnext | rprev      jump to next / previous response (move down/up a response)
#   replay             replay the current segment
#   goto N             jump to segment N
#   last               jump to the most recent segment
#   pause | resume | toggle | stop
#   list               show the queue (">" current, "*" response starts)
#   status             show engine, position, totals
#   sessions           list all active sessions
#   keys               interactive single-key control (n/p/r/space/N/P/l/q)
#   clear              empty the queue
#   quit               stop the player daemon
# Targets the most recently active session; override with CLAUDE_SPEAK_SESSION=<dir>.
set -uo pipefail
# Resolve through the bin/ symlink so we find lib.sh next to the real script.
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  t="$(readlink "$SELF")"; case "$t" in /*) SELF="$t" ;; *) SELF="$(dirname "$SELF")/$t" ;; esac
done
DIR="$(cd "$(dirname "$SELF")" && pwd)"; . "$DIR/lib.sh"

cmd="${1:-status}"; arg="${2:-}"

if [ "$cmd" = "engine" ]; then
  case "$arg" in
    say|openai|elevenlabs) printf '%s' "$arg" > "$CS_HOME/engine"
      echo "claude-speak: engine -> $arg (applies to the next spoken segment)" ;;
    "") echo "engine: $(cs_engine)" ;;
    *)  echo "claude-speak: unknown engine '$arg' (use say | openai | elevenlabs)"; exit 1 ;;
  esac
  exit 0
fi

if [ "$cmd" = "voices" ] || [ "$cmd" = "voice" ]; then
  cur=$(cat "$CS_HOME/voice" 2>/dev/null)

  # macOS `say` has its own voice namespace (Samantha, Alex, Daniel, ...).
  if [ "$(cs_engine)" = "say" ]; then
    if [ "$cmd" = "voices" ]; then
      echo "macOS say voices ( * = current ) — claude-speak voice <name>:"
      /usr/bin/say -v '?' | /usr/bin/awk -v c="$cur" '{m=($1==c)?"* ":"  "; printf "%s%-16s %s\n", m, $1, $2}'
    else
      [ -n "$arg" ] || { echo "usage: claude-speak voice <name>"; exit 1; }
      printf '%s' "$arg" > "$CS_HOME/voice"; echo "claude-speak: voice -> $arg"
    fi
    exit 0
  fi

  key=$(cs_key elevenlabs)
  resp=""; [ -n "$key" ] && resp=$(/usr/bin/curl -s -H "xi-api-key: $key" https://api.elevenlabs.io/v1/voices)
  has_api=0; printf '%s' "$resp" | /usr/bin/jq -e '.voices' >/dev/null 2>&1 && has_api=1

  if [ "$cmd" = "voices" ]; then
    echo "Available voices ( * = current ):"
    if [ "$has_api" = 1 ]; then
      printf '%s' "$resp" | /usr/bin/jq -r --arg c "$cur" '.voices[] |
        (if .voice_id==$c then "* " else "  " end) + .name + "\t" + .voice_id + "\t"
        + ((.labels.gender // "") + " " + (.labels.accent // ""))' | /usr/bin/column -t -s "$(printf '\t')"
    else
      [ -n "$key" ] && echo "(key lacks voices_read permission — showing built-in premade voices)"
      cs_static_voices | /usr/bin/awk -F'\t' -v c="$cur" '{m=($2==c)?"* ":"  "; print m $0}' \
        | /usr/bin/column -t -s "$(printf '\t')"
    fi
    exit 0
  fi

  [ -n "$arg" ] || { echo "usage: claude-speak voice <name or id>"; exit 1; }
  id=""
  [ "$has_api" = 1 ] && id=$(printf '%s' "$resp" | /usr/bin/jq -r --arg n "$arg" \
    '.voices[] | select((.name|ascii_downcase)==($n|ascii_downcase) or .voice_id==$n) | .voice_id' | head -1)
  [ -n "$id" ] || id=$(cs_static_voice_id "$arg")
  [ -n "$id" ] || { echo "claude-speak: voice not found: $arg (try: claude-speak voices)"; exit 1; }
  printf '%s' "$id" > "$CS_HOME/voice"
  echo "claude-speak: voice set -> $arg ($id)  (applies to the next spoken segment)"
  exit 0
fi

if [ "$cmd" = "sessions" ]; then
  for d in "$CS_HOME"/*/; do
    [ -d "$d/segs" ] || continue
    a=$(cs_player_alive "$d" && echo running || echo stopped)
    printf '%s  [%s]  %s segs\n' "$(basename "$d")" "$a" "$(cs_seg_count "$d")"
  done
  exit 0
fi

sd="${CLAUDE_SPEAK_SESSION:-$(cat "$CS_HOME/current" 2>/dev/null)}"
if [ -z "$sd" ] || [ ! -d "$sd" ]; then          # fall back to the newest session
  sd=$(ls -dt "$CS_HOME"/*/segs 2>/dev/null | head -1); sd="${sd%/segs}"
fi
[ -n "$sd" ] && [ -d "$sd" ] || { echo "claude-speak: no active session yet"; exit 1; }
send() { cs_ensure_player "$sd"; printf '%s\n' "$1" > "$sd/control"; }

case "$cmd" in
  next|prev|rnext|rprev|replay|last|pause|resume|toggle|stop|clear|quit|mute|unmute|mutetoggle)
    send "$cmd"; echo "claude-speak: $cmd" ;;
  goto)
    [ -n "$arg" ] || { echo "usage: claude-speak goto N"; exit 1; }
    send "goto $arg"; echo "claude-speak: goto $arg" ;;
  status)
    printf 'engine:  %s\nplayer:  %s\nmuted:   %s\nsession: %s\nsegment: %s / %s\n' \
      "$(cs_engine)" "$(cs_player_alive "$sd" && echo running || echo stopped)" \
      "$([ -f "$sd/muted" ] && echo yes || echo no)" \
      "$(basename "$sd")" "$(cat "$sd/pos" 2>/dev/null || echo 1)" "$(cs_seg_count "$sd")" ;;
  list)
    pos=$(cat "$sd/pos" 2>/dev/null || echo 1); i=1
    while [ -f "$(cs_seg_txt "$sd" "$i")" ]; do
      m=" "; [ "$i" = "$pos" ] && m=">"
      rs=" "; grep -qx "$i" "$sd/responses" 2>/dev/null && rs="*"
      printf '%s%s %3d  %s\n' "$m" "$rs" "$i" "$(head -c 64 "$(cs_seg_txt "$sd" "$i")" | tr '\n' ' ')"
      i=$((i+1))
    done
    [ "$i" = 1 ] && echo "(queue empty)" ;;
  keys)
    echo "claude-speak keys  ·  n/→ next  p/← prev  r replay  space pause  N/P response  l list  q quit"
    old=$(stty -g 2>/dev/null); stty -echo -icanon min 1 time 0 2>/dev/null
    trap 'stty "$old" 2>/dev/null' EXIT INT TERM
    while IFS= read -rsn1 k; do
      case "$k" in
        n) send next ;;
        p) send prev ;;
        r) send replay ;;
        N) send rnext ;;
        P) send rprev ;;
        l) "$0" list ;;
        q) break ;;
        ' ') send toggle ;;
        $'\e') read -rsn2 seq    # arrow keys send ESC [ X together
               case "$seq" in '[C') send next ;; '[D') send prev ;; '[A') send rprev ;; '[B') send rnext ;; esac ;;
      esac
    done
    stty "$old" 2>/dev/null ;;
  *) echo "claude-speak: unknown command '$cmd'"; exit 1 ;;
esac
