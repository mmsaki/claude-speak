---
description: claude-speak — switch TTS engine (say | openai | elevenlabs)
argument-hint: <say|openai|elevenlabs>
allowed-tools: Bash(bash:*)
---
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" engine "$ARGUMENTS"`
