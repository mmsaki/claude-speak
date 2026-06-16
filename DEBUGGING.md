# Debugging claude-speak

How to diagnose audio/queue/cursor issues. The golden rule: **everything is
observable on disk** — the plugin keeps all per-session state under
`~/.claude/claude-speak/`, so most bugs are found by *reading state files*, not
guessing.

## 1. Know the layout

```
~/.claude/claude-speak/
├── config                 # user settings (engine, voice, speed, MAX_LAG, toggles)
├── current                # path of the most-recent active session (for the CLI)
├── voice                  # runtime voice-id override (claude-speak voice ...)
├── sounds/                # rendered cue WAVs (+ .rendered flag)
└── <session_id>/          # one dir PER Claude session
    ├── cursor             # byte offset of prose already spoken  ← the #1 suspect
    ├── segs/NNNN.txt      # spoken text per segment (+ NNNN.mp3/.aiff audio)
    ├── responses          # segment indices that start a response (rprev/rnext)
    ├── pos                # player's current segment index
    ├── control            # FIFO/file the hook+ctl write commands to
    ├── player.pid         # daemon pid (liveness via kill -0)
    └── player.log         # daemon diagnostics
```

The plugin itself runs from a **cache copy**, not your working tree, once
installed from a marketplace:
```
~/.claude/plugins/cache/mmsaki/claude-speak/<version>/   # ← what's actually live
```
Check which version is live and whether it matches `main`:
```bash
ls ~/.claude/plugins/cache/mmsaki/claude-speak/        # versioned subdir
diff <(git show origin/main:scripts/event.sh) \
     ~/.claude/plugins/cache/mmsaki/claude-speak/*/scripts/event.sh
```

## 2. The core data model (so you know what "wrong" looks like)

- **Prose** = all assistant *text* blocks in the transcript, cleaned (`cs_assistant_prose`).
  Note a huge transcript can have *small* prose — tool calls/results aren't spoken.
- **cursor** = how many chars of prose have already been spoken. Each hook reads
  `new = prose[cursor:]`, speaks it, sets `cursor = len(prose)`.
- A bug where it "reads old messages" ≈ **cursor is too low** (0 or stale).
- A bug where it "skips messages" ≈ cursor too high, or follow-mode (`MAX_LAG`) skipping.

## 3. Reproduce the read pipeline by hand

The fastest way to see *exactly* what would be spoken for a given transcript:
```bash
cd ~/developer/mmsaki/claude-speak && . scripts/lib.sh
T=$(find ~/.claude/projects -name '<session_id>.jsonl' | head -1)
cs_assistant_prose "$T" | wc -c          # total prose length (= where cursor should land)
cs_assistant_prose "$T" | tail -c 400    # the most recent prose (what SHOULD be next)
```

Simulate a single hook end-to-end in an isolated home (never touches live state):
```bash
export CLAUDE_SPEAK_HOME=/tmp/cs-debug; rm -rf $CLAUDE_SPEAK_HOME
printf '{"session_id":"T","transcript_path":"%s","source":"resume"}' "$T" \
  | bash ~/.claude/plugins/cache/mmsaki/claude-speak/*/scripts/event.sh sessionstart
cat /tmp/cs-debug/T/cursor    # did the prime set it correctly?
```

## 4. Inspect what actually got spoken

Each segment's text is on disk — read them to see what was queued and when:
```bash
SD=~/.claude/claude-speak/<session_id>
for f in "$SD"/segs/*.txt; do echo "[$(basename $f)] $(head -c 80 "$f")"; done
stat -f '%Sm %N' -t '%H:%M:%S' "$SD"/segs/*.txt   # timestamps vs the event you suspect
cat "$SD/cursor"; cat "$SD/pos"                    # where the cursor/player are
```
Cross-reference segment timestamps with when the suspect event happened (e.g. a
segment created at *resume time* containing message #1 ⇒ cursor was 0 on resume).

## 5. Daemon / playback issues

```bash
pgrep -af 'player.sh <session_id>'     # bash daemon (main + reader subshell = 2 procs)
pgrep -af 'claude-speak player'        # zig daemon
cat "$SD/player.log"                    # startup diagnostics (engine, key found?)
pgrep -x afplay                         # is audio actually playing?
```
- **Wrong engine / `say` instead of ElevenLabs**: `player.log` shows `engine=/key=`.
  A spawned daemon with an *empty environment* can't find `$HOME`/the key — in the
  zig port this required seeding `Io.Threaded.environ`.
- **Won't stop / talks over itself**: check the global speaker lock
  `~/.claude/claude-speak/speaker.lock` and that only one player runs per session.
- **Stale audio on exit**: `SessionEnd` must kill the player AND its `afplay`
  child (killing the daemon alone orphans afplay, which keeps playing).

## 6. Common root causes (seen in the wild)

| Symptom | Root cause | Where |
|---|---|---|
| Reads message #1 on resume | `SessionEnd` deleted the cursor; resume starts at 0 | preserve cursor in `sessionend` |
| Old/"bad" sounds after reinstall | stale plugin **cache** (version never bumped) | bump `plugin.json` version every change |
| `say` voice not ElevenLabs | daemon spawned without env → no key | seed env on spawn |
| Phantom cue (no action) | event fires on compaction/resume too | gate on `.source` |
| Cue cut short | hook teardown killed `afplay` | `nohup … & disown` the cue |

## 7. Toggles for isolating layers

```bash
CLAUDE_TTS=0      # mute voice (keep cues)
CLAUDE_CUES=0     # mute cues (keep voice)
CLAUDE_TTS_ENGINE=say   # force offline engine (rule out network/key)
CLAUDE_TTS_DEBUG=1       # (where supported) print instead of speak
```

## 8. After a fix: bump + sync + reload

The live cache won't change until you bump the version (or hand-sync). During
dev:
```bash
# bump plugin.json (patch for fixes), commit, push, then sync the live cache:
C=~/.claude/plugins/cache/mmsaki/claude-speak/<version>
cp scripts/event.sh "$C/scripts/"; cp .claude-plugin/plugin.json "$C/.claude-plugin/"
# then in Claude Code:  /reload-plugins
```
