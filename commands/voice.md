---
description: claude-speak — switch voice (name/id), or on|off for narration
argument-hint: <name> | on | off
allowed-tools: Bash(bash:*)
---
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" voice "$ARGUMENTS"`
