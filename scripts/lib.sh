#!/usr/bin/env bash
# claude-speak shared library: config, engine resolution, prose cleaning, queue helpers.

CS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CS_HOME="${CLAUDE_SPEAK_HOME:-$HOME/.claude/claude-speak}"
mkdir -p "$CS_HOME"
[ -f "$CS_HOME/config" ] && . "$CS_HOME/config"     # optional user overrides (shell exports)

# --- engine + credentials --------------------------------------------------
# Resolution order when CLAUDE_TTS_ENGINE is unset: elevenlabs -> openai -> say.
cs_have_key() { # $1 = openai|elevenlabs
  case "$1" in
    openai)     [ -n "${OPENAI_API_KEY:-}" ] || [ -f "$HOME/.claude/.openai_key" ] ;;
    elevenlabs) [ -n "${ELEVENLABS_API_KEY:-}" ] || [ -f "$HOME/.claude/.elevenlabs_key" ] ;;
  esac
}

cs_key() { # $1 = openai|elevenlabs -> prints key or nothing
  case "$1" in
    openai)
      [ -n "${OPENAI_API_KEY:-}" ] && { printf '%s' "$OPENAI_API_KEY"; return; }
      [ -f "$HOME/.claude/.openai_key" ] && tr -d '[:space:]' < "$HOME/.claude/.openai_key" ;;
    elevenlabs)
      [ -n "${ELEVENLABS_API_KEY:-}" ] && { printf '%s' "$ELEVENLABS_API_KEY"; return; }
      [ -f "$HOME/.claude/.elevenlabs_key" ] && tr -d '[:space:]' < "$HOME/.claude/.elevenlabs_key" ;;
  esac
}

cs_engine() {
  if [ -n "${CLAUDE_TTS_ENGINE:-}" ]; then printf '%s' "$CLAUDE_TTS_ENGINE"; return; fi
  if cs_have_key elevenlabs; then printf 'elevenlabs'; return; fi
  if cs_have_key openai;     then printf 'openai';     return; fi
  printf 'say'
}

# --- session paths ---------------------------------------------------------
cs_session_dir() { printf '%s/%s' "$CS_HOME" "${1:-default}"; }

# --- prose cleaning --------------------------------------------------------
# stdin -> stdout, stripped of everything that isn't prose.
cs_clean() {
  /usr/bin/awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }   # fenced code blocks
    fence { next }
    /^[[:space:]]{4,}[^[:space:]]/ { next }             # indented code
    /^[[:space:]]*\|.*\|[[:space:]]*$/ { next }         # table rows
    { print }
  ' | /usr/bin/sed -E \
      -e 's/!\[[^]]*\]\([^)]*\)//g' \
      -e 's/\[([^]]+)\]\([^)]+\)/\1/g' \
      -e 's#https?://[^[:space:]]+##g' \
      -e 's/^[[:space:]]*#+[[:space:]]*//' \
      -e 's/^[[:space:]]*>[[:space:]]?//' \
      -e 's/^[[:space:]]*[-*+][[:space:]]+//' \
      -e 's,[][/\|=+<>{}()@#$%^&*~`_-], ,g' \
    | /usr/bin/awk 'BEGIN{blank=0}
        /^[[:space:]]*$/ {blank++; if(blank<2)print ""; next} {blank=0; print}'
}

# Full cleaned prose of ALL assistant text blocks in a transcript.
cs_assistant_prose() { # $1 = transcript path
  /usr/bin/jq -rs '
    map(select(.type=="assistant")) | .[].message.content
    | (if type=="array" then map(select(.type=="text") | .text) | join(" ") else empty end)
  ' "$1" 2>/dev/null | cs_clean
}

# --- queue helpers ---------------------------------------------------------
cs_seg_txt()   { printf '%s/segs/%04d.txt' "$1" "$2"; }            # $1 sd $2 idx
cs_seg_audio() { ls "$1"/segs/$(printf '%04d' "$2").* 2>/dev/null | grep -v '\.txt$' | head -1; }
cs_seg_count() { ls "$1"/segs/*.txt 2>/dev/null | wc -l | tr -d ' '; }

# --- global speaker lock (serialize audible playback across ALL sessions) --
# Per-session queues stay independent; this only ensures one sound at a time so
# two Claude CLIs don't talk over each other. Non-blocking + stale-pid aware.
cs_speaker_try() {
  [ "${CLAUDE_TTS_GLOBAL_LOCK:-1}" = "0" ] && return 0
  local L="$CS_HOME/speaker.lock"
  if mkdir "$L" 2>/dev/null; then echo $$ > "$L/pid"; return 0; fi
  local p; p=$(cat "$L/pid" 2>/dev/null)
  if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then     # owner died holding it
    rm -rf "$L"; mkdir "$L" 2>/dev/null && { echo $$ > "$L/pid"; return 0; }
  fi
  return 1
}
cs_speaker_release() {
  [ "${CLAUDE_TTS_GLOBAL_LOCK:-1}" = "0" ] && return 0
  local L="$CS_HOME/speaker.lock"
  [ "$(cat "$L/pid" 2>/dev/null)" = "$$" ] && rm -rf "$L"
}

# --- player lifecycle ------------------------------------------------------
cs_player_alive() { [ -f "$1/player.pid" ] && kill -0 "$(cat "$1/player.pid" 2>/dev/null)" 2>/dev/null; }

# Built-in ElevenLabs premade voices (fallback when the key lacks voices_read).
cs_static_voices() {
  printf '%s\n' \
    "Rachel	21m00Tcm4TlvDq8ikWAM	female · calm narration" \
    "Domi	AZnzlk1XvdvUeBnXmlld	female · strong" \
    "Sarah	EXAVITQu4vr4xnSDxMaL	female · soft" \
    "Elli	MF3mGyEYCl7XYWbV9V6O	female · emotional" \
    "Dorothy	ThT5KcBeYPX3keUQqHPh	female · British" \
    "Charlotte	XB0fDUnXU5powFXDhCwa	female · Swedish" \
    "Matilda	XrExE9yKIg1WjnnlVkGX	female · warm" \
    "Freya	jsCqWAovK2LkecY7zXl4	female · expressive" \
    "Grace	oWAxZDx7w5VEj9dCyTzz	female · US-Southern" \
    "Lily	pFZP5JQG7iQjIQuC4Bku	female · British" \
    "Nicole	piTKgcLEGmPE4e6mEKli	female · whisper" \
    "Antoni	ErXwobaYiN019PkySvjV	male · well-rounded" \
    "Charlie	IKne3meq5aSn9XLyUdCD	male · Australian" \
    "George	JBFqnCBsd6RMkjVDRZzb	male · warm" \
    "Callum	N2lVS1w4EtoT3dr4eOWO	male · hoarse" \
    "Liam	TX3LPaxmHKxFdv7VOQHJ	male · neutral" \
    "Josh	TxGEqnHWrfWFTfGW9XjX	male · deep" \
    "Arnold	VR6AewLTigWG4xSOukaG	male · crisp" \
    "Daniel	onwK4e9ZLuTAKqWW03F9	male · British news" \
    "Brian	nPczCjzI2devNBz1zQrb	male · deep US" \
    "Bill	pqHfZKP75CvOlQylNhV4	male · older" \
    "Adam	pNInz6obpgDQGcFmaJgB	male · deep" \
    "Sam	yoZ06aMxZJJ28mfd3POQ	male · raspy"
}

cs_static_voice_id() {  # $1 = name or id -> prints id
  cs_static_voices | /usr/bin/awk -F'\t' -v q="$1" '
    BEGIN{ql=tolower(q)} tolower($1)==ql || $2==q {print $2; exit}'
}

cs_prune_sessions() {   # remove finished sessions
  for d in "$CS_HOME"/*/; do
    cs_player_alive "$d" && continue
    if [ -d "${d}segs" ]; then
      # active session with audio: prune if idle >60min
      [ -n "$(find "$d" -maxdepth 0 -mmin +60 2>/dev/null)" ] && rm -rf "$d"
    else
      # metadata-only (cursor preserved after exit for resume): prune >7 days
      [ -n "$(find "$d" -maxdepth 0 -mmin +10080 2>/dev/null)" ] && rm -rf "$d"
    fi
  done
}

cs_ensure_player() { # $1 = session dir
  local sd="$1"
  cs_player_alive "$sd" && return 0
  local lk="$sd/player.start.lock"
  mkdir "$lk" 2>/dev/null || return 0
  nohup bash "$CS_DIR/player.sh" "$sd" >>"$sd/player.log" 2>&1 &
  echo $! > "$sd/player.pid"
  rmdir "$lk" 2>/dev/null || true
}
