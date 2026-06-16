//! Audio playback + `say` synthesis via child processes (afplay / say).
//! Returns the Child so the player can interrupt playback with kill().
const std = @import("std");

const afplay = "/usr/bin/afplay";
const say_bin = "/usr/bin/say";

/// Spawn afplay for `path`; caller waits/kills the returned Child.
pub fn spawnPlay(io: std.Io, path: []const u8) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = &.{ afplay, path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

/// Spawn afplay at a custom playback rate (afplay -r RATE path).
pub fn spawnPlayRate(io: std.Io, path: []const u8, rate: []const u8) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = &.{ afplay, "-r", rate, path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

/// Play `path` to completion (blocking).
pub fn playAndWait(io: std.Io, path: []const u8) void {
    var child = spawnPlay(io, path) catch return;
    _ = child.wait(io) catch {};
}

/// macOS `say` fallback: synthesize `text` to an AIFF at `out_path` (blocking).
pub fn sayToFile(io: std.Io, text: []const u8, out_path: []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = &.{ say_bin, "-o", out_path, text },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    if (!term.success()) return error.SayFailed;
}

test "spawn and wait a child process" {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var child = try std.process.spawn(io, .{
        .argv = &.{"/usr/bin/true"},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    try std.testing.expect(term.success());
}
