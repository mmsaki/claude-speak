//! The player daemon. Single process, two threads:
//!   - player thread: synth (on-demand) + afplay each segment, blocking wait
//!   - poll thread:   drain the control file, mutate the queue, and interrupt
//!                    playback (Child.kill) on nav/pause/mute — instant response
//! Shared state is guarded by an atomic swap spinlock (no Thread.Mutex in 0.17).
const std = @import("std");
const queue = @import("queue.zig");
const audio = @import("audio.zig");
const tts = @import("tts.zig");
const config = @import("config.zig");
const ipc = @import("ipc.zig");

fn sleepMs(io: std.Io, ms: i64) void {
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .awake) catch {};
}

const Shared = struct {
    flag: std.atomic.Value(bool) = .init(false),
    quit: std.atomic.Value(bool) = .init(false),
    interrupted: std.atomic.Value(bool) = .init(false),
    cur_child: ?*std.process.Child = null,
    q: queue.Queue,
    io: std.Io,
    gpa: std.mem.Allocator,
    session_dir: []const u8,
    home: []const u8,
    engine: []const u8,
    el_key: ?[]const u8,
    voice: []const u8,
    model: []const u8,
    speed: []const u8,

    fn acq(s: *Shared) void {
        while (s.flag.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn rel(s: *Shared) void {
        s.flag.store(false, .release);
    }
};

/// Apply one control line. Returns true if it should interrupt playback.
fn applyCommand(s: *Shared, line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "enqueue\t")) {
        _ = s.q.enqueue(line["enqueue\t".len..]) catch {};
        return false;
    }
    if (std.mem.eql(u8, line, "endresponse")) {
        s.q.endResponse();
        return false;
    }
    if (std.mem.eql(u8, line, "next")) {
        s.q.next();
        return true;
    }
    if (std.mem.eql(u8, line, "prev")) {
        s.q.prev();
        return true;
    }
    if (std.mem.eql(u8, line, "replay")) return true;
    if (std.mem.eql(u8, line, "last")) {
        s.q.last();
        return true;
    }
    if (std.mem.eql(u8, line, "rprev")) {
        s.q.rprev();
        return true;
    }
    if (std.mem.eql(u8, line, "rnext")) {
        s.q.rnext();
        return true;
    }
    if (std.mem.startsWith(u8, line, "goto ")) {
        const n = std.fmt.parseInt(usize, line[5..], 10) catch return false;
        s.q.goto(n);
        return true;
    }
    if (std.mem.eql(u8, line, "pause") or std.mem.eql(u8, line, "stop")) {
        s.q.paused = true;
        return true;
    }
    if (std.mem.eql(u8, line, "resume")) {
        s.q.paused = false;
        return false;
    }
    if (std.mem.eql(u8, line, "toggle")) {
        s.q.paused = !s.q.paused;
        return s.q.paused;
    }
    if (std.mem.eql(u8, line, "mute")) {
        s.q.muted = true;
        return true;
    }
    if (std.mem.eql(u8, line, "unmute")) {
        s.q.muted = false;
        return false;
    }
    if (std.mem.eql(u8, line, "mutetoggle")) {
        s.q.muted = !s.q.muted;
        return s.q.muted;
    }
    if (std.mem.eql(u8, line, "quit")) {
        s.quit.store(true, .release);
        return true;
    }
    return false;
}

fn pollThread(s: *Shared) void {
    while (!s.quit.load(.acquire)) {
        sleepMs(s.io, 40);
        const data = ipc.drain(s.io, s.gpa, s.session_dir) catch continue;
        defer s.gpa.free(data);
        if (data.len == 0) continue;
        s.acq();
        var interrupt = false;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |ln| {
            if (ln.len == 0) continue;
            if (applyCommand(s, ln)) interrupt = true;
        }
        if (interrupt) {
            s.interrupted.store(true, .release);
            // Signal afplay directly (poll thread only reads the pid; the player
            // thread owns Child.wait, so we never touch Child from two threads).
            if (s.cur_child) |c| {
                if (c.id) |pid| std.posix.kill(pid, @enumFromInt(15)) catch {}; // SIGTERM
            }
        }
        s.rel();
    }
}

/// Synthesize `text` for segment `idx` to a file; returns the owned path.
fn synth(s: *Shared, idx: usize, text: []const u8) ![]u8 {
    // runtime voice override written by `ctl voice ...` (else config voice)
    var voice = s.voice;
    var vbuf: ?[]u8 = null;
    defer if (vbuf) |v| s.gpa.free(v);
    const vpath = try std.fmt.allocPrint(s.gpa, "{s}/voice", .{s.home});
    defer s.gpa.free(vpath);
    if (std.Io.Dir.cwd().readFileAlloc(s.io, vpath, s.gpa, .limited(256))) |v| {
        defer s.gpa.free(v);
        const t = std.mem.trim(u8, v, " \t\r\n");
        if (t.len > 0) {
            vbuf = try s.gpa.dupe(u8, t);
            voice = vbuf.?;
        }
    } else |_| {}

    if (std.mem.eql(u8, s.engine, "elevenlabs")) {
        if (s.el_key) |key| {
            const path = try std.fmt.allocPrint(s.gpa, "{s}/{d}.mp3", .{ s.session_dir, idx });
            if (tts.elevenlabs(s.gpa, s.io, key, voice, s.model, s.speed, text, path)) {
                return path;
            } else |_| s.gpa.free(path);
        }
    }
    // say fallback (always works offline)
    const path = try std.fmt.allocPrint(s.gpa, "{s}/{d}.aiff", .{ s.session_dir, idx });
    errdefer s.gpa.free(path);
    try audio.sayToFile(s.io, text, path);
    return path;
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ, session_dir: []const u8) !void {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const home = try config.home(arena, environ);
    const cfg = try config.load(arena, io, environ, home);

    // ElevenLabs key: env or ~/.claude/.elevenlabs_key
    var el_key: ?[]const u8 = null;
    if (environ.getPosix("ELEVENLABS_API_KEY")) |k| {
        if (k.len > 0) el_key = try arena.dupe(u8, k);
    }
    if (el_key == null) {
        const hd = environ.getPosix("HOME") orelse "/tmp";
        const kp = try std.fmt.allocPrint(arena, "{s}/.claude/.elevenlabs_key", .{hd});
        if (std.Io.Dir.cwd().readFileAlloc(io, kp, arena, .limited(4096))) |raw| {
            el_key = try arena.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
        } else |_| {}
    }

    var s = Shared{
        .q = queue.Queue.init(gpa),
        .io = io,
        .gpa = gpa,
        .session_dir = session_dir,
        .home = home,
        .engine = try arena.dupe(u8, config.engine(cfg, el_key != null, false)),
        .el_key = el_key,
        .voice = try arena.dupe(u8, cfg.getOr("CLAUDE_TTS_VOICE", "21m00Tcm4TlvDq8ikWAM")),
        .model = try arena.dupe(u8, cfg.getOr("CLAUDE_TTS_MODEL", "eleven_turbo_v2_5")),
        .speed = try arena.dupe(u8, cfg.getOr("CLAUDE_TTS_SPEED", "1.0")),
    };
    defer s.q.deinit();
    if (cfg.get("CLAUDE_TTS_MAX_LAG")) |ml| s.q.max_lag = std.fmt.parseInt(usize, ml, 10) catch null;

    { // startup log for diagnostics
        const logp = try std.fmt.allocPrint(arena, "{s}/player.log", .{session_dir});
        var lb: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&lb, "engine={s} key={s} voice={s}\n", .{ s.engine, if (el_key != null) "yes" else "no", s.voice }) catch "";
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = logp, .data = msg }) catch {};
    }

    const poller = try std.Thread.spawn(.{}, pollThread, .{&s});
    defer poller.join();

    while (!s.quit.load(.acquire)) {
        // snapshot under lock
        s.acq();
        if (s.q.muted) {
            s.q.pos = s.q.count();
            s.rel();
            sleepMs(io, 60);
            continue;
        }
        s.q.catchUp();
        const paused = s.q.paused;
        const idx = s.q.pos;
        const cur = s.q.current();
        const need_synth = cur != null and cur.?.audio == null;
        const text = if (need_synth) try gpa.dupe(u8, cur.?.text) else null;
        const ready_audio = if (cur != null and cur.?.audio != null) try gpa.dupe(u8, cur.?.audio.?) else null;
        s.rel();

        if (paused or cur == null) {
            if (text) |t| gpa.free(t);
            if (ready_audio) |r| gpa.free(r);
            sleepMs(io, 60);
            continue;
        }

        // synth if needed (no lock held — may be slow/network)
        var audio_path: []u8 = undefined;
        if (need_synth) {
            defer gpa.free(text.?);
            audio_path = synth(&s, idx, text.?) catch {
                sleepMs(io, 100);
                continue;
            };
            s.acq();
            if (idx < s.q.count()) s.q.setAudio(idx, audio_path) catch {};
            s.rel();
        } else {
            audio_path = ready_audio.?;
        }
        defer gpa.free(audio_path);

        // play, interruptibly
        var child = audio.spawnPlay(io, audio_path) catch continue;
        s.acq();
        s.cur_child = &child;
        s.interrupted.store(false, .release);
        s.rel();

        _ = child.wait(io) catch {};

        s.acq();
        s.cur_child = null;
        const was_interrupted = s.interrupted.load(.acquire);
        if (!was_interrupted) s.q.advance();
        s.rel();
    }
}
