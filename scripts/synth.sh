#!/usr/bin/env bash
# synth.sh <base-path>  (text on stdin) -> writes <base-path>.<ext>, prints final path.
# Engine chosen by cs_engine (CLAUDE_TTS_ENGINE or key autodetect). Always falls back
# to macOS `say` so an audio file is guaranteed to exist (avoids player deadlock).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$DIR/lib.sh"

base="$1"
text=$(cat)
[ -n "$text" ] || exit 1
engine=$(cs_engine)

say_fallback() {
  local v=""; [ -s "$CS_HOME/voice" ] && v=$(cat "$CS_HOME/voice")
  # use the chosen say voice if valid; otherwise the system default
  if [ -n "$v" ] && /usr/bin/say -v "$v" -o "$base.aiff" "$text" 2>/dev/null; then
    printf '%s' "$base.aiff"; return 0
  fi
  /usr/bin/say -o "$base.aiff" "$text" 2>/dev/null && { printf '%s' "$base.aiff"; return 0; }
  return 1
}

case "$engine" in
  openai)
    key=$(cs_key openai)
    voice="${CLAUDE_TTS_VOICE:-nova}"          # alloy echo fable onyx nova shimmer
    model="${CLAUDE_TTS_MODEL:-gpt-4o-mini-tts}"
    body=$(/usr/bin/jq -n --arg m "$model" --arg v "$voice" --arg i "$text" \
      '{model:$m, voice:$v, input:$i, response_format:"mp3"}')
    if [ -n "$key" ] && /usr/bin/curl -sS -f -m 30 https://api.openai.com/v1/audio/speech \
        -H "Authorization: Bearer $key" -H "Content-Type: application/json" \
        -d "$body" -o "$base.mp3" 2>/dev/null && [ -s "$base.mp3" ]; then
      printf '%s' "$base.mp3"; exit 0
    fi
    say_fallback && exit 0; exit 1 ;;

  elevenlabs)
    key=$(cs_key elevenlabs)
    voice="${CLAUDE_TTS_VOICE:-21m00Tcm4TlvDq8ikWAM}"   # default: Rachel
    [ -s "$CS_HOME/voice" ] && voice=$(cat "$CS_HOME/voice")   # runtime override (claude-speak voice ...)
    model="${CLAUDE_TTS_MODEL:-eleven_turbo_v2_5}"
    fmt="${CLAUDE_TTS_FORMAT:-mp3_44100_128}"
    speed="${CLAUDE_TTS_SPEED:-1.0}"                     # 0.7-1.2 (pitch-preserving)
    body=$(/usr/bin/jq -n --arg m "$model" --arg t "$text" --argjson sp "$speed" \
      '{model_id:$m, text:$t, voice_settings:{speed:$sp}}')
    if [ -n "$key" ] && /usr/bin/curl -sS -f -m 30 \
        "https://api.elevenlabs.io/v1/text-to-speech/$voice?output_format=$fmt" \
        -H "xi-api-key: $key" -H "Content-Type: application/json" \
        -d "$body" -o "$base.mp3" 2>/dev/null && [ -s "$base.mp3" ]; then
      printf '%s' "$base.mp3"; exit 0
    fi
    say_fallback && exit 0; exit 1 ;;

  *)
    say_fallback && exit 0; exit 1 ;;
esac
