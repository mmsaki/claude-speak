---
description: claude-speak — switch TTS voice (name or id)
argument-hint: <voice name or id>
allowed-tools: Bash(bash:*)
---
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" voice "$ARGUMENTS"`
