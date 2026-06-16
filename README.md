# claude-speak

Hear Claude Code. A plugin that adds three independently-toggleable audio layers,
driven by Claude Code's event hooks:

- 🔊 **Cues** — procedural synth sound effects on every event (send, tick, notify,
  success, failure, …), rendered from a dependency-free Python synthesizer
  (inspired by Kit Langton's `TaskSounds.ts`).
- 🗣 **Voice** — text-to-speech reading of Claude's prose (code stripped out), with a
  **per-session queue** you can **skip / replay / navigate**.
- 📳 **Haptics** — *experimental* trackpad feedback (Force Touch only; off by default).

## Install

```bash
/plugin marketplace add mmsaki/claude-speak
/plugin install claude-speak@mmsaki
```

Then restart Claude Code. Cues work out of the box (uses macOS `afplay`). For voice,
add a key (see below) — without one it falls back to the macOS `say` voice.

> macOS only for now (`afplay` / `say`). Requires `jq` and `python3` (both standard).

## Voice engines

Auto-detected by which key is present: **ElevenLabs → OpenAI → `say`**. Keys live in
`chmod 600` files (never committed):

```bash
printf 'sk_...'  > ~/.claude/.elevenlabs_key && chmod 600 ~/.claude/.elevenlabs_key
printf 'sk-...'  > ~/.claude/.openai_key     && chmod 600 ~/.claude/.openai_key
```

or via `OPENAI_API_KEY` / `ELEVENLABS_API_KEY` in your environment.

## Controls

A stable CLI is symlinked to `~/.claude/claude-speak/bin/claude-speak` on session
start. Add it to PATH or alias it:

```bash
export PATH="$HOME/.claude/claude-speak/bin:$PATH"
```

```
claude-speak next | prev          # one segment
claude-speak rnext | rprev        # one whole response (up/down)
claude-speak replay               # replay current segment
claude-speak goto N | last
claude-speak pause | resume | toggle
claude-speak list | status | sessions
claude-speak keys                 # interactive single-key control
```

### Keybindings

Claude Code's own keybindings can't run shell commands, so use one of:

- **Single-key listener** — run `claude-speak keys` in a second terminal / tmux pane:
  `n`/`→` next · `p`/`←` prev · `r` replay · `space` pause · `N`/`P` response · `q` quit.
- **Global hotkeys** ([skhd](https://github.com/koekeishiya/skhd)) — work while the
  Claude TUI is focused:
  ```
  cmd + alt - right : claude-speak next
  cmd + alt - left  : claude-speak prev
  cmd + alt - r     : claude-speak replay
  ```
- Bundled slash commands: `/claude-speak:next`, `:prev`, `:replay`, `:list`, `:stop`.

## Per-session queue & no overlap

Each Claude CLI session gets its own queue, cursor, player, and controls (keyed by
`session_id`). A **global speaker lock** ensures two sessions never talk over each
other — the second waits its turn while staying fully navigable. Disable with
`CLAUDE_TTS_GLOBAL_LOCK=0`.

## Config

Copy `config.example.sh` to `~/.claude/claude-speak/config` and edit (sourced by every
hook). Toggle layers (`CLAUDE_TTS`, `CLAUDE_CUES`, `CLAUDE_HAPTICS`), pick engine/voice,
set the per-chunk cap, etc.

## Haptics (experimental)

macOS has no public CLI haptic API; `NSHapticFeedbackManager` only actuates Force Touch
trackpads from an app context. Set `CLAUDE_HAPTICS=1`, then provide an actuator —
easiest is a tiny compiled helper at `scripts/bin/haptic`:

```swift
// haptic.swift  —  swiftc haptic.swift -o scripts/bin/haptic
import AppKit
let pat = CommandLine.arguments.dropFirst().first ?? "generic"
let m: NSHapticFeedbackManager.FeedbackPattern =
  pat == "alignment" ? .alignment : pat == "levelChange" ? .levelChange : .generic
NSHapticFeedbackManager.defaultPerformer.perform(m, performanceTime: .now)
```

## Sound palette

`send tick notify success failure done reset interrupted running config blip copied
hover death` — play any directly: `bash scripts/cue.sh success`.

## License

MIT
