# claude-speak

**Give your Claude Code agent a voice.** 🗣️

claude-speak reads Claude's replies aloud and plays subtle sound cues as it
works — so you can *listen* to a long session instead of watching the terminal.

## Features

- 🗣️ **Spoken replies** — Claude's responses read aloud, in real time
- 🔊 **Sound cues** — gentle audio for sending, tool calls, permission prompts, and exit
- ⏯️ **Playback controls** — skip, replay, pause, mute, and switch voices on the fly
- 🎙️ **Great voices** — ElevenLabs or OpenAI, with a built-in macOS voice as fallback
- 🧵 **Per-session** — each session has its own queue; two terminals never talk over each other

## Install

```
/plugin marketplace add mmsaki/claude-speak
/plugin install claude-speak@mmsaki
```

Restart Claude Code — that's it. It speaks with the built-in **macOS voice** out
of the box (no API key, no cost).

**Want premium voices?** (optional) Add a key, then switch the engine:

```bash
printf 'YOUR_ELEVENLABS_KEY' > ~/.claude/.elevenlabs_key && chmod 600 ~/.claude/.elevenlabs_key
# then, in Claude:   /claude-speak:engine elevenlabs
# (OpenAI works too: ~/.claude/.openai_key + /claude-speak:engine openai)
```

## Commands

| Command | What it does |
| --- | --- |
| `/claude-speak:next` · `:prev` | skip forward / back |
| `/claude-speak:replay` | replay the current segment |
| `/claude-speak:stop` · `:play` | pause / resume |
| `/claude-speak:mute` | silence the voice (cues keep playing) |
| `/claude-speak:voice <name>` | switch voice |
| `/claude-speak:voices` | list available voices |
| `/claude-speak:list` | show what's queued |

---

macOS · MIT · [full docs](DOCS.md) · [report an issue](https://github.com/mmsaki/claude-speak/issues)
