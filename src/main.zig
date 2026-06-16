//! claude-speak — single-binary TTS + sound cues for Claude Code.
//! Subcommands (being ported from the bash reference in scripts/):
//!   hook <event>        dispatch a Claude Code hook (payload on stdin)
//!   player <session>    background playback daemon
//!   <ctl-cmd> [arg]     control the player (next/prev/replay/mute/voice/...)
const std = @import("std");
const clean = @import("clean.zig");
const synth = @import("synth_wav.zig");
const tts = @import("tts.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var it = init.args.iterate();
    _ = it.next(); // program name
    const cmd = it.next() orelse return usage();

    if (std.mem.eql(u8, cmd, "version")) {
        std.debug.print("claude-speak 0.2.0-dev (zig)\n", .{});
        return;
    }

    if (std.mem.eql(u8, cmd, "cues")) {
        const dir = it.next() orelse return usage();
        var gpa: std.heap.DebugAllocator(.{}) = .init;
        defer _ = gpa.deinit();
        var threaded: std.Io.Threaded = .init(gpa.allocator(), .{});
        defer threaded.deinit();
        try synth.renderAll(gpa.allocator(), threaded.io(), dir);
        std.debug.print("rendered {d} cues -> {s}\n", .{ synth.cues.len, dir });
        return;
    }

    if (std.mem.eql(u8, cmd, "tts")) {
        const voice = it.next() orelse return usage();
        const text = it.next() orelse return usage();
        const out = it.next() orelse return usage();
        var gpa: std.heap.DebugAllocator(.{}) = .init;
        defer _ = gpa.deinit();
        const alloc = gpa.allocator();
        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();
        const io = threaded.io();
        // key: $ELEVENLABS_API_KEY, else ~/.claude/.elevenlabs_key
        var key: []u8 = undefined;
        if (init.environ.getPosix("ELEVENLABS_API_KEY")) |k| {
            key = try alloc.dupe(u8, k);
        } else {
            const hd = init.environ.getPosix("HOME") orelse "/tmp";
            const kp = try std.fmt.allocPrint(alloc, "{s}/.claude/.elevenlabs_key", .{hd});
            defer alloc.free(kp);
            const raw = try std.Io.Dir.cwd().readFileAlloc(io, kp, alloc, .limited(4096));
            key = try alloc.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
            alloc.free(raw);
        }
        defer alloc.free(key);
        try tts.elevenlabs(alloc, io, key, voice, "eleven_turbo_v2_5", "1.2", text, out);
        std.debug.print("wrote {s}\n", .{out});
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
    _ = @import("synth_wav.zig");
    _ = @import("payload.zig");
    _ = @import("config.zig");
    _ = @import("tts.zig");
    _ = @import("audio.zig");
}
