# claude-speak — full documentation

Everything beyond the [README](README.md): how it works, every command, all
settings, the sound design, haptics, and the native binary.

> macOS only (uses the system `afplay` / `say`). Needs `jq` and `python3` (both
> standard). The README covers install — this is the reference.

---

## How it works

claude-speak hangs off Claude Code's **hooks**. Each hook is a tiny event; the
plugin reacts by playing a **sound cue**, by **speaking** new prose, or both.

```
Claude Code event  ─▶  hook (event.sh)  ─▶  ┬─ cue   (a short synth sound)
                                            ├─ voice (speak new transcript prose)
                                            └─ haptic (optional trackpad tap)

speak: transcript ─▶ clean to prose ─▶ enqueue new text ─▶ player daemon ─▶ TTS + afplay
```

- **Per session.** Each Claude session gets its own queue and playback daemon
  under `~/.claude/claude-speak/<session_id>/`. Two terminals never share state.
- **Cursor.** A byte offset tracks how much prose has been spoken, so only *new*
  text is read. It's primed on start and preserved across exit, so resuming a
  session never replays the backlog.
- **Follow mode.** If playback falls behind, it skips forward to stay current.
- **Global speaker lock.** Only one segment is audible at a time across all
  sessions, so two CLIs don't talk over each other.

---

## Sounds — what plays when

| Event | Sound | Notes |
| --- | --- | --- |
| You submit a prompt | `send` | |
| Session start (new/resume) | `send` | not on compaction |
| Each tool call | `tick` | |
| Claude asks you a question | `permission` | AskUserQuestion / plan approval |
| Permission prompt | `permission` | only real permission notifications |
| Tool error | `failure` | |
| Subagent finishes | `running` | |
| Reply finishes | *(voice only)* | no cue — voice is the signal |
| You exit | `reset` | goodbye, and the voice stops |

### Sound palette

All cues are synthesized procedurally (no audio files shipped) by
`scripts/gen_sounds.py`, rendered once to WAV in `~/.claude/claude-speak/sounds/`.
Available: `send tick notify success failure done reset interrupted running
config permission blip copied hover death`. Audition any:

```bash
bash scripts/cue.sh success
```

To re-render after editing recipes: `rm ~/.claude/claude-speak/sounds/.rendered`
(they rebuild on the next cue), or `claude-speak cues ~/.claude/claude-speak/sounds`
with the native binary.

---

## Commands

### Slash commands (in Claude Code)

| Command | Action |
| --- | --- |
| `/claude-speak:next` · `:prev` | skip forward / back one segment |
| `/claude-speak:replay` | replay the current segment |
| `/claude-speak:stop` · `:play` | pause / resume |
| `/claude-speak:mute` | toggle mute (voice off, cues stay; stays at the live edge) |
| `/claude-speak:voice <name>` | switch voice |
| `/claude-speak:voices` | list available voices |
| `/claude-speak:list` | show the queue |

### CLI (`claude-speak`)

A `claude-speak` CLI is symlinked to `~/.claude/claude-speak/bin/` on session
start. Add it to your PATH:

```bash
export PATH="$HOME/.claude/claude-speak/bin:$PATH"
```

```
claude-speak next | prev            one segment forward / back
claude-speak rnext | rprev          jump a whole response (down / up)
claude-speak replay | last | goto N
claude-speak pause | resume | toggle | stop
claude-speak mute | unmute | mutetoggle
claude-speak voice <name|id> | voices
claude-speak list | status | sessions
claude-speak keys                   interactive single-key control (n/p/r/space/q)
claude-speak clear | quit
```

`claude-speak keys` is the nicest way to drive it live — run it in a second
terminal: `n`/`→` next · `p`/`←` prev · `r` replay · `space` pause · `q` quit.

---

## Voices

Engine is auto-detected: **ElevenLabs → OpenAI → macOS `say`** (whichever key is
present). Keys live in `chmod 600` files:

```bash
printf 'sk_...' > ~/.claude/.elevenlabs_key && chmod 600 ~/.claude/.elevenlabs_key
printf 'sk-...' > ~/.claude/.openai_key     && chmod 600 ~/.claude/.openai_key
```

`claude-speak voices` lists them. If your ElevenLabs key lacks the `voices_read`
permission, it falls back to a built-in list of premade voices. `claude-speak
voice <name>` switches live (applies to the next spoken segment).

---

## Configuration

Settings live in `~/.claude/claude-speak/config` (shell `export` lines, sourced
by every hook); environment variables override the file. Copy
`config.example.sh` to get started.

| Variable | Default | Meaning |
| --- | --- | --- |
| `CLAUDE_TTS` | `1` | speak replies (0 = off) |
| `CLAUDE_CUES` | `1` | sound cues (0 = off) |
| `CLAUDE_HAPTICS` | `0` | trackpad haptics (experimental) |
| `CLAUDE_TTS_ENGINE` | auto | `elevenlabs` · `openai` · `say` |
| `CLAUDE_TTS_VOICE` | Rachel | voice name/id for the engine |
| `CLAUDE_TTS_MODEL` | `eleven_turbo_v2_5` | TTS model |
| `CLAUDE_TTS_SPEED` | `1.0` | ElevenLabs speed 0.7–1.2 (pitch-preserving) |
| `CLAUDE_TTS_RATE` | — | extra `afplay -r` speedup (raises pitch) |
| `CLAUDE_TTS_MAXCHARS` | `1500` | max chars per segment (longer → split) |
| `CLAUDE_TTS_MAX_LAG` | `2` | follow mode: stay within N segments of newest |
| `CLAUDE_TTS_EAGER` | `1` | synth on enqueue (parallel) vs on-demand |
| `CLAUDE_TTS_GLOBAL_LOCK` | `1` | one audible segment at a time across sessions |
| `CLAUDE_TTS_SKIP_RE` | — | extra regex of phrases to never speak |
| `CLAUDE_SPEAK_HOME` | `~/.claude/claude-speak` | state directory |

---

## Haptics (experimental)

macOS has no public CLI haptic API — `NSHapticFeedbackManager` only actuates
Force Touch trackpads. Set `CLAUDE_HAPTICS=1`; on first use, `scripts/haptic.sh`
compiles `scripts/haptic.swift` once into the cache (needs Xcode CLT) or
downloads the prebuilt helper from the GitHub release. Failure is silent — it's
a nice-to-have, never blocking.

---

## Native binary (Zig)

A from-scratch single-binary rewrite lives in `src/` — zero runtime deps (no
`bash`/`jq`/`python3`/`curl`), just the OS `afplay`/`say`. It does real
ElevenLabs TTS over pure-Zig TLS, native cue synthesis, the per-session queue
with instant skip/interrupt, and ships as cross-compiled binaries (macOS
arm64/x64, Linux x64/arm64) on each [release](https://github.com/mmsaki/claude-speak/releases).

```bash
zig build -Doptimize=ReleaseSafe          # -> zig-out/bin/claude-speak
claude-speak hook <event>                 # called by hooks (payload on stdin)
claude-speak player <session>             # background playback daemon
claude-speak tts <voice> <text> <out.mp3> # one-off synthesis
```

The bash version is the tested default; the binary is opt-in. See
[DEBUGGING.md](DEBUGGING.md) for the on-disk state model and how to diagnose
issues.

---

## Uninstall

```
/plugin uninstall claude-speak@mmsaki
```
State lives in `~/.claude/claude-speak/` — remove it to wipe sounds/queues.
Keys in `~/.claude/.elevenlabs_key` / `.openai_key` are yours to keep or delete.
