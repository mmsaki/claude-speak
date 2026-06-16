//! Cross-process control channel: a per-session `control` file appended under
//! an atomic `createDir` lock (works across the hook, ctl, and daemon
//! processes). The daemon drains+clears it each poll. Uses only verified Io
//! filesystem ops — no sockets/FIFO/signals.
const std = @import("std");

fn cwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

fn lockDir(alloc: std.mem.Allocator, session_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/ctl.lock", .{session_dir});
}
fn controlPath(alloc: std.mem.Allocator, session_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/control", .{session_dir});
}

fn lock(io: std.Io, alloc: std.mem.Allocator, session_dir: []const u8) !void {
    const lp = try lockDir(alloc, session_dir);
    defer alloc.free(lp);
    var n: usize = 0;
    while (n < 400) : (n += 1) {
        if (cwd().createDir(io, lp, .default_dir)) {
            return;
        } else |_| std.Io.sleep(io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }
    return error.LockTimeout;
}
fn unlock(io: std.Io, alloc: std.mem.Allocator, session_dir: []const u8) void {
    const lp = lockDir(alloc, session_dir) catch return;
    defer alloc.free(lp);
    cwd().deleteDir(io, lp) catch {};
}

/// Append one command line to the session's control file (atomic under lock).
pub fn send(io: std.Io, alloc: std.mem.Allocator, session_dir: []const u8, line: []const u8) !void {
    try lock(io, alloc, session_dir);
    defer unlock(io, alloc, session_dir);
    const ctl = try controlPath(alloc, session_dir);
    defer alloc.free(ctl);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    if (cwd().readFileAlloc(io, ctl, alloc, .limited(4 << 20))) |old| {
        defer alloc.free(old);
        try buf.appendSlice(alloc, old);
    } else |_| {}
    try buf.appendSlice(alloc, line);
    try buf.append(alloc, '\n');
    try cwd().writeFile(io, .{ .sub_path = ctl, .data = buf.items });
}

/// Read and clear all pending commands. Caller owns the returned bytes (lines
/// separated by '\n'); empty if none.
pub fn drain(io: std.Io, alloc: std.mem.Allocator, session_dir: []const u8) ![]u8 {
    try lock(io, alloc, session_dir);
    defer unlock(io, alloc, session_dir);
    const ctl = try controlPath(alloc, session_dir);
    defer alloc.free(ctl);
    const data = cwd().readFileAlloc(io, ctl, alloc, .limited(4 << 20)) catch return alloc.dupe(u8, "");
    if (data.len > 0) cwd().writeFile(io, .{ .sub_path = ctl, .data = "" }) catch {};
    return data;
}

test "send then drain round-trips commands" {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "/tmp/cs-ipc-test";
    cwd().deleteTree(io, dir) catch {};
    try cwd().createDir(io, dir, .default_dir);
    defer cwd().deleteTree(io, dir) catch {};

    try send(io, a, dir, "next");
    try send(io, a, dir, "enqueue\thello world");
    const got = try drain(io, a, dir);
    defer a.free(got);
    try std.testing.expectEqualStrings("next\nenqueue\thello world\n", got);

    const empty = try drain(io, a, dir);
    defer a.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}
