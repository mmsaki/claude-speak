// haptic helper — actuates Force Touch trackpad feedback.
// Compiled on first use by haptic.sh into the state dir (never shipped as a binary).
import AppKit

let pat = CommandLine.arguments.dropFirst().first ?? "generic"
let pattern: NSHapticFeedbackManager.FeedbackPattern =
  pat == "alignment" ? .alignment : pat == "levelChange" ? .levelChange : .generic
NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
