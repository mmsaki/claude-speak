//! claude-speak — single-binary TTS + sound cues for Claude Code.
//! Subcommands (being ported from the bash reference in scripts/):
//!   hook <event>        dispatch a Claude Code hook (payload on stdin)
//!   player <session>    background playback daemon
//!   <ctl-cmd> [arg]     control the player (next/prev/replay/mute/voice/...)
const std = @import("std");
const clean = @import("clean.zig");
const synth = @import("synth_wav.zig");
const tts = @import("tts.zig");
const daemon = @import("daemon.zig");
const hooks = @import("hooks.zig");

const ctl_cmds = [_][]const u8{
    "next", "prev", "replay", "last", "rprev", "rnext", "goto",
    "pause", "resume", "toggle", "stop", "mute", "unmute", "mutetoggle",
    "clear", "quit", "voice",
};

pub fn main(init: std.process.Init.Minimal) !void {
    var it = init.args.iterate();
    const exe = it.next() orelse return usage(); // program path (for spawning the daemon)
    const cmd = it.next() orelse return usage();

    if (std.mem.eql(u8, cmd, "version")) {
        std.debug.print("claude-speak 0.2.0-dev (zig)\n", .{});
        return;
    }

    if (std.mem.eql(u8, cmd, "player")) {
        const session = it.next() orelse return usage();
        var gpa: std.heap.DebugAllocator(.{}) = .init;
        defer _ = gpa.deinit();
        var threaded: std.Io.Threaded = .init(gpa.allocator(), .{ .environ = init.environ });
        defer threaded.deinit();
        try daemon.run(gpa.allocator(), threaded.io(), init.environ, session);
        return;
    }

    if (std.mem.eql(u8, cmd, "hook")) {
        const event = it.next() orelse return usage();
        var gpa: std.heap.DebugAllocator(.{}) = .init;
        defer _ = gpa.deinit();
        const alloc = gpa.allocator();
        var threaded: std.Io.Threaded = .init(alloc, .{ .environ = init.environ });
        defer threaded.deinit();
        const io = threaded.io();
        const payload_bytes = std.Io.Dir.cwd().readFileAlloc(io, "/dev/stdin", alloc, .limited(64 << 20)) catch "";
        defer alloc.free(payload_bytes);
        try hooks.hook(alloc, io, init.environ, exe, event, payload_bytes);
        return;
    }

    for (ctl_cmds) |c| {
        if (std.mem.eql(u8, cmd, c)) {
            const arg = it.next();
            var gpa: std.heap.DebugAllocator(.{}) = .init;
            defer _ = gpa.deinit();
            var threaded: std.Io.Threaded = .init(gpa.allocator(), .{ .environ = init.environ });
            defer threaded.deinit();
            try hooks.ctl(gpa.allocator(), threaded.io(), init.environ, exe, cmd, arg);
            return;
        }
    }

    if (std.mem.eql(u8, cmd, "cues")) {
        const dir = it.next() orelse return usage();
        var gpa: std.heap.DebugAllocator(.{}) = .init;
        defer _ = gpa.deinit();
        var threaded: std.Io.Threaded = .init(gpa.allocator(), .{ .environ = init.environ });
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
        var threaded: std.Io.Threaded = .init(alloc, .{ .environ = init.environ });
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
    _ = @import("queue.zig");
    _ = @import("ipc.zig");
    _ = @import("daemon.zig");
}
