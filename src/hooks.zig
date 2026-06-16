//! Hook dispatch + control client. `hook <event>` plays a cue and enqueues new
//! prose to the daemon; `ctl <cmd>` forwards control words. Spawns the daemon
//! (detached) on demand.
const std = @import("std");
const payload = @import("payload.zig");
const clean = @import("clean.zig");
const config = @import("config.zig");
const ipc = @import("ipc.zig");
const synth = @import("synth_wav.zig");
const audio = @import("audio.zig");

fn cwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

fn alive(io: std.Io, gpa: std.mem.Allocator, pidpath: []const u8) bool {
    const data = cwd().readFileAlloc(io, pidpath, gpa, .limited(64)) catch return false;
    defer gpa.free(data);
    const pid = std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, data, " \t\r\n"), 10) catch return false;
    std.posix.kill(pid, @enumFromInt(0)) catch return false;
    return true;
}

fn ensureDaemon(io: std.Io, gpa: std.mem.Allocator, exe: []const u8, session_dir: []const u8) void {
    const pidpath = std.fmt.allocPrint(gpa, "{s}/player.pid", .{session_dir}) catch return;
    defer gpa.free(pidpath);
    if (alive(io, gpa, pidpath)) return;
    const lock = std.fmt.allocPrint(gpa, "{s}/spawn.lock", .{session_dir}) catch return;
    defer gpa.free(lock);
    cwd().createDir(io, lock, .default_dir) catch return; // someone else is spawning
    defer cwd().deleteDir(io, lock) catch {};
    if (alive(io, gpa, pidpath)) return;

    const child = std.process.spawn(io, .{
        .argv = &.{ exe, "player", session_dir },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    if (child.id) |pid| {
        var buf: [32]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch return;
        cwd().writeFile(io, .{ .sub_path = pidpath, .data = txt }) catch {};
    }
    // detached — do not wait
}

fn ensureSounds(io: std.Io, gpa: std.mem.Allocator, home: []const u8) []u8 {
    const sounds = std.fmt.allocPrint(gpa, "{s}/sounds", .{home}) catch return "";
    const flag = std.fmt.allocPrint(gpa, "{s}/.rendered", .{sounds}) catch return sounds;
    defer gpa.free(flag);
    if (cwd().readFileAlloc(io, flag, gpa, .limited(1))) |d| {
        gpa.free(d);
        return sounds;
    } else |_| {}
    cwd().createDir(io, sounds, .default_dir) catch {};
    synth.renderAll(gpa, io, sounds) catch {};
    return sounds;
}

fn playCue(io: std.Io, gpa: std.mem.Allocator, home: []const u8, name: []const u8) void {
    const sounds = ensureSounds(io, gpa, home);
    defer gpa.free(sounds);
    if (sounds.len == 0) return;
    const wav = std.fmt.allocPrint(gpa, "{s}/{s}.wav", .{ sounds, name }) catch return;
    defer gpa.free(wav);
    _ = audio.spawnPlay(io, wav) catch {}; // detached; orphan is reaped by init
}

/// Read transcript, clean, and enqueue only the newly-written prose (tracked by
/// a per-session byte cursor). On stop, also marks a response boundary.
fn enqueueNewProse(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: config.Config,
    exe: []const u8,
    session_dir: []const u8,
    transcript_path: []const u8,
    is_stop: bool,
) void {
    if (!cfg.flag("CLAUDE_TTS", true)) return;
    const tx = cwd().readFileAlloc(io, transcript_path, gpa, .limited(64 << 20)) catch return;
    defer gpa.free(tx);
    const raw = payload.assistantText(gpa, tx) catch return;
    defer gpa.free(raw);
    const cleaned = clean.cleanProse(gpa, raw) catch return;
    defer gpa.free(cleaned);
    const prose = clean.collapse(gpa, cleaned) catch return;
    defer gpa.free(prose);

    const cpath = std.fmt.allocPrint(gpa, "{s}/cursor", .{session_dir}) catch return;
    defer gpa.free(cpath);
    var cursor: usize = 0;
    if (cwd().readFileAlloc(io, cpath, gpa, .limited(64))) |c| {
        defer gpa.free(c);
        cursor = std.fmt.parseInt(usize, std.mem.trim(u8, c, " \t\r\n"), 10) catch 0;
    } else |_| {}
    if (cursor > prose.len) cursor = 0;

    if (prose.len > cursor) {
        const new = std.mem.trim(u8, prose[cursor..], " \t\r\n");
        var buf: [32]u8 = undefined;
        const ctxt = std.fmt.bufPrint(&buf, "{d}", .{prose.len}) catch return;
        cwd().writeFile(io, .{ .sub_path = cpath, .data = ctxt }) catch {};
        if (new.len > 0) {
            ensureDaemon(io, gpa, exe, session_dir);
            const line = std.fmt.allocPrint(gpa, "enqueue\t{s}", .{new}) catch return;
            defer gpa.free(line);
            ipc.send(io, gpa, session_dir, line) catch {};
        }
    }
    if (is_stop) ipc.send(io, gpa, session_dir, "endresponse") catch {};
}

pub fn hook(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    exe: []const u8,
    event: []const u8,
    payload_bytes: []const u8,
) !void {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const home = try config.home(arena, environ);
    const cfg = try config.load(arena, io, environ, home);
    var p = payload.parsePayload(gpa, payload_bytes) catch payload.Payload{};
    defer p.deinit(gpa);

    const sid = p.session_id orelse "default";
    const session_dir = try std.fmt.allocPrint(arena, "{s}/{s}", .{ home, sid });
    cwd().createDir(io, session_dir, .default_dir) catch {};

    const cues_on = cfg.flag("CLAUDE_CUES", true);

    if (std.mem.eql(u8, event, "userprompt")) {
        if (cues_on) playCue(io, gpa, home, "send");
    } else if (std.mem.eql(u8, event, "sessionstart")) {
        const src = p.source orelse "";
        if (cues_on and (src.len == 0 or std.mem.eql(u8, src, "startup") or std.mem.eql(u8, src, "resume")))
            playCue(io, gpa, home, "send");
    } else if (std.mem.eql(u8, event, "pretool")) {
        const tool = p.tool_name orelse "";
        const cue = if (std.mem.eql(u8, tool, "AskUserQuestion") or std.mem.eql(u8, tool, "ExitPlanMode")) "permission" else "tick";
        if (cues_on) playCue(io, gpa, home, cue);
        if (p.transcript_path) |t| enqueueNewProse(io, gpa, cfg, exe, session_dir, t, false);
    } else if (std.mem.eql(u8, event, "notify")) {
        if (cues_on) playCue(io, gpa, home, "permission");
    } else if (std.mem.eql(u8, event, "stop")) {
        if (cues_on) playCue(io, gpa, home, "reset");
        if (p.transcript_path) |t| enqueueNewProse(io, gpa, cfg, exe, session_dir, t, true);
    } else if (std.mem.eql(u8, event, "subagentstop")) {
        if (cues_on) playCue(io, gpa, home, "running");
    }

    // record the active session for the control CLI
    const cur = try std.fmt.allocPrint(arena, "{s}/current", .{home});
    cwd().writeFile(io, .{ .sub_path = cur, .data = session_dir }) catch {};
}

pub fn ctl(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    exe: []const u8,
    cmd: []const u8,
    arg: ?[]const u8,
) !void {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const home = try config.home(arena, environ);

    // `voice <id>` just writes the runtime override (daemon reads it on synth)
    if (std.mem.eql(u8, cmd, "voice")) {
        const id = arg orelse {
            std.debug.print("usage: claude-speak voice <id>\n", .{});
            return;
        };
        const vpath = try std.fmt.allocPrint(arena, "{s}/voice", .{home});
        try cwd().writeFile(io, .{ .sub_path = vpath, .data = id });
        std.debug.print("claude-speak: voice set -> {s}\n", .{id});
        return;
    }

    const cur = cwd().readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}/current", .{home}), gpa, .limited(4096)) catch {
        std.debug.print("claude-speak: no active session yet\n", .{});
        return;
    };
    defer gpa.free(cur);
    const session_dir = std.mem.trim(u8, cur, " \t\r\n");

    const line = if (arg) |a|
        try std.fmt.allocPrint(arena, "{s} {s}", .{ cmd, a })
    else
        cmd;
    ensureDaemon(io, gpa, exe, session_dir);
    try ipc.send(io, gpa, session_dir, line);
    std.debug.print("claude-speak: {s}\n", .{line});
}
