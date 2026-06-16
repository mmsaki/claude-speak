#!/usr/bin/env bash
# haptic.sh <level>  — EXPERIMENTAL trackpad haptics. Off unless CLAUDE_HAPTICS=1.
# level: light | medium | heavy
#
# macOS has no public CLI haptic API; NSHapticFeedbackManager only actuates
# Force Touch trackpads. The helper is never shipped as a binary — on first use
# it is compiled once from haptic.swift into the cache (needs Xcode CLT), or, if
# swiftc is unavailable, downloaded from the GitHub release. Any failure is silent.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$DIR/lib.sh"
[ "${CLAUDE_HAPTICS:-0}" = "1" ] || exit 0

case "${1:-medium}" in
  light) pat="alignment" ;; heavy) pat="levelChange" ;; *) pat="generic" ;;
esac

HELPER="$CS_HOME/bin/haptic-helper"          # compiled binary, cached (not in repo)
SRC="$CS_DIR/haptic.swift"
REL="https://github.com/mmsaki/claude-speak/releases/latest/download/haptic-arm64-macos"

if [ ! -x "$HELPER" ]; then
  mkdir -p "$CS_HOME/bin"
  if mkdir "$CS_HOME/bin/.build.lock" 2>/dev/null; then   # build once, in background
    if command -v swiftc >/dev/null 2>&1 && [ -f "$SRC" ]; then
      ( swiftc "$SRC" -o "$HELPER" 2>/dev/null; rmdir "$CS_HOME/bin/.build.lock" 2>/dev/null ) &
    else
      ( /usr/bin/curl -fsSL -o "$HELPER" "$REL" 2>/dev/null && chmod +x "$HELPER"
        rmdir "$CS_HOME/bin/.build.lock" 2>/dev/null ) &
    fi
  fi
  exit 0                                       # this event skipped; ready for the next
fi

"$HELPER" "$pat" >/dev/null 2>&1 &
exit 0
