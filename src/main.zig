//! claude-speak — single-binary TTS + sound cues for Claude Code.
//! Subcommands (being ported from the bash reference in scripts/):
//!   hook <event>        dispatch a Claude Code hook (payload on stdin)
//!   player <session>    background playback daemon
//!   <ctl-cmd> [arg]     control the player (next/prev/replay/mute/voice/...)
const std = @import("std");
const clean = @import("clean.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var it = init.args.iterate();
    _ = it.next(); // program name
    const cmd = it.next() orelse return usage();

    if (std.mem.eql(u8, cmd, "version")) {
        std.debug.print("claude-speak 0.2.0-dev (zig)\n", .{});
        return;
    }

    // Remaining subcommands are ported incrementally; until then the bash
    // scripts remain the live implementation.
    std.debug.print("claude-speak: '{s}' not yet implemented in the zig port\n", .{cmd});
}

fn usage() void {
    std.debug.print("usage: claude-speak <hook|player|ctl-cmd|version>\n", .{});
}

test {
    _ = @import("clean.zig");
}
