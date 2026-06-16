# claude-speak config — copy to ~/.claude/claude-speak/config and edit.
# This file is sourced by every hook; use shell `export` lines only.

# --- layers (1 = on, 0 = off) ---
export CLAUDE_TTS=1            # spoken responses
export CLAUDE_CUES=1           # procedural sound cues
export CLAUDE_HAPTICS=0        # experimental trackpad haptics (Force Touch only)

# --- voice engine ---  elevenlabs | openai | say  (auto-detected if unset)
# export CLAUDE_TTS_ENGINE=elevenlabs
# OpenAI:     CLAUDE_TTS_VOICE=nova        CLAUDE_TTS_MODEL=gpt-4o-mini-tts | tts-1-hd
# ElevenLabs: CLAUDE_TTS_VOICE=<voice_id>  CLAUDE_TTS_MODEL=eleven_turbo_v2_5
# export CLAUDE_TTS_VOICE=21m00Tcm4TlvDq8ikWAM
export CLAUDE_TTS_MAXCHARS=1500   # cap per spoken chunk

# --- playback ---
export CLAUDE_TTS_GLOBAL_LOCK=1   # 1 = never let two sessions talk over each other

# Keys are read from ~/.claude/.openai_key and ~/.claude/.elevenlabs_key (chmod 600),
# or from OPENAI_API_KEY / ELEVENLABS_API_KEY in the environment.
