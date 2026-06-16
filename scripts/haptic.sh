#!/usr/bin/env bash
# haptic.sh <level>  — EXPERIMENTAL trackpad haptics. Off unless CLAUDE_HAPTICS=1.
# level: light | medium | heavy  (maps to NSHapticFeedbackManager patterns)
#
# macOS has no public CLI haptic API; NSHapticFeedbackManager only actuates
# Force Touch trackpads from an app context. We try, in order:
#   1) a user-compiled helper at $CS_DIR/bin/haptic  (see README to build it)
#   2) a `haptic` binary on PATH
#   3) a `swift -e` one-liner (slow: compiles each call; best-effort)
# Any failure is silent — haptics are a nice-to-have, never block.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$DIR/lib.sh"
[ "${CLAUDE_HAPTICS:-0}" = "1" ] || exit 0

level="${1:-medium}"
case "$level" in
  light)  pat="alignment" ;;
  heavy)  pat="levelChange" ;;
  *)      pat="generic" ;;
esac

if [ -x "$CS_DIR/bin/haptic" ]; then
  "$CS_DIR/bin/haptic" "$pat" >/dev/null 2>&1 &
elif command -v haptic >/dev/null 2>&1; then
  haptic "$pat" >/dev/null 2>&1 &
elif command -v swift >/dev/null 2>&1; then
  swift -e "import AppKit; NSHapticFeedbackManager.defaultPerformer.perform(.$pat, performanceTime: .now)" >/dev/null 2>&1 &
fi
exit 0
