//! Procedural sound-cue synthesis — ports gen_sounds.py (Kit Langton's
//! TaskSounds recipes) to native Zig. Renders each cue to a 16-bit mono WAV.
//! Pure math + file write; no Python, no deps.
const std = @import("std");

const SR: usize = 44100;
const QUARTER: f64 = 0.5; // seconds per quarter note @ 120 BPM

const Osc = enum { sine, triangle, sawtooth, square4, fatsaw };
const Env = struct { a: f64, d: f64, s: f64, r: f64 };
const Voice = struct {
    off: f64, // start offset (s)
    osc: Osc,
    note: []const u8,
    gain: f64,
    n: f64, // note value: 4 = "4n", 32 = "32n", 1 = "1n"
    env: Env,
};
const Cue = struct {
    name: []const u8,
    voices: []const Voice,
    wet: f64,
    dist: bool = false,
};

fn dur(n: f64) f64 {
    return QUARTER * 4.0 / n;
}

fn noteFreq(note: []const u8) f64 {
    const base: i32 = switch (note[0]) {
        'C' => 0, 'D' => 2, 'E' => 4, 'F' => 5, 'G' => 7, 'A' => 9, 'B' => 11,
        else => 0,
    };
    var i: usize = 1;
    var semi: i32 = base;
    if (note.len > 1 and note[1] == '#') {
        semi += 1;
        i = 2;
    } else if (note.len > 1 and note[1] == 'b') {
        semi -= 1;
        i = 2;
    }
    const oct = std.fmt.parseInt(i32, note[i..], 10) catch 4;
    const midi: f64 = @floatFromInt(12 * (oct + 1) + semi);
    return 440.0 * std.math.pow(f64, 2.0, (midi - 69.0) / 12.0);
}

fn osc(kind: Osc, f: f64, t: f64) f64 {
    const w = 2.0 * std.math.pi * f * t;
    return switch (kind) {
        .sine => std.math.sin(w),
        .triangle => (2.0 / std.math.pi) * std.math.asin(std.math.sin(w)),
        .sawtooth => blk: {
            const x = f * t;
            break :blk 2.0 * (x - std.math.floor(x + 0.5));
        },
        .square4 => blk: {
            var s: f64 = 0;
            var k: usize = 1;
            while (k <= 4) : (k += 1) {
                const h: f64 = @floatFromInt(2 * k - 1);
                s += std.math.sin(w * h) / h;
            }
            break :blk s * (4.0 / std.math.pi) * 0.4;
        },
        .fatsaw => blk: {
            const cents = [_]f64{ -16, -10, -4, 0, 4, 10, 16 };
            var s: f64 = 0;
            for (cents) |c| {
                const ff = f * std.math.pow(f64, 2.0, c / 1200.0);
                const x = ff * t;
                s += 2.0 * (x - std.math.floor(x + 0.5));
            }
            break :blk s / @as(f64, cents.len);
        },
    };
}

fn adsr(i: usize, n_samp: usize, e: Env) f64 {
    const fi: f64 = @floatFromInt(i);
    const a_s = e.a * @as(f64, @floatFromInt(SR));
    const d_s = e.d * @as(f64, @floatFromInt(SR));
    const r_s = e.r * @as(f64, @floatFromInt(SR));
    const nf: f64 = @floatFromInt(n_samp);
    if (fi < a_s) return if (a_s > 0) fi / a_s else 1.0;
    if (fi < a_s + d_s) return 1.0 - (1.0 - e.s) * (if (d_s > 0) (fi - a_s) / d_s else 1.0);
    if (fi < nf) return e.s;
    const rel = fi - nf;
    if (rel < r_s) return e.s * (1.0 - rel / r_s);
    return 0.0;
}

fn renderVoice(buf: []f64, v: Voice, dist: bool) void {
    const n_samp: usize = @intFromFloat(dur(v.n) * @as(f64, @floatFromInt(SR)));
    const total = n_samp + @as(usize, @intFromFloat(v.env.r * @as(f64, @floatFromInt(SR))));
    const start: usize = @intFromFloat(v.off * @as(f64, @floatFromInt(SR)));
    const f = noteFreq(v.note);
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const e = adsr(i, n_samp, v.env);
        if (e <= 0) continue;
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(SR));
        var val = osc(v.osc, f, t) * e * v.gain;
        if (dist) val = std.math.tanh(val * 3.0);
        const j = start + i;
        if (j < buf.len) buf[j] += val;
    }
}

// Light Schroeder reverb (comb + allpass), wet-mixed.
fn reverb(alloc: std.mem.Allocator, buf: []f64, wet: f64) !void {
    const combs = [_]struct { d: usize, fb: f64 }{
        .{ .d = 1557, .fb = 0.77 }, .{ .d = 1617, .fb = 0.80 },
        .{ .d = 1491, .fb = 0.75 }, .{ .d = 1422, .fb = 0.73 },
    };
    const acc = try alloc.alloc(f64, buf.len);
    defer alloc.free(acc);
    @memset(acc, 0);
    const cb = try alloc.alloc(f64, buf.len);
    defer alloc.free(cb);
    for (combs) |cf| {
        @memset(cb, 0);
        for (buf, 0..) |x, i| {
            cb[i] = x + (if (i >= cf.d) cf.fb * cb[i - cf.d] else 0);
        }
        for (acc, 0..) |*a, i| a.* += cb[i] / @as(f64, combs.len);
    }
    const aps = [_]struct { d: usize, g: f64 }{ .{ .d = 225, .g = 0.7 }, .{ .d = 556, .g = 0.7 } };
    const ap = try alloc.alloc(f64, buf.len);
    defer alloc.free(ap);
    for (aps) |a| {
        @memset(ap, 0);
        for (0..buf.len) |i| {
            const d = if (i >= a.d) acc[i - a.d] else 0;
            ap[i] = -a.g * acc[i] + d + a.g * (if (i >= a.d) ap[i - a.d] else 0);
        }
        @memcpy(acc, ap);
    }
    for (buf, 0..) |*x, i| x.* = x.* * (1 - wet) + acc[i] * wet;
}

fn appendInt(out: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime T: type, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try out.appendSlice(alloc, &b);
}

/// Build a 16-bit mono WAV from the float buffer. Pure — caller owns the bytes.
pub fn buildWav(alloc: std.mem.Allocator, buf: []const f64) ![]u8 {
    var peak: f64 = 1e-9;
    for (buf) |x| peak = @max(peak, @abs(x));
    const scale = 0.7 / peak;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const data_len: u32 = @intCast(buf.len * 2);
    try out.appendSlice(alloc, "RIFF");
    try appendInt(&out, alloc, u32, 36 + data_len);
    try out.appendSlice(alloc, "WAVEfmt ");
    try appendInt(&out, alloc, u32, 16); // fmt size
    try appendInt(&out, alloc, u16, 1); // PCM
    try appendInt(&out, alloc, u16, 1); // mono
    try appendInt(&out, alloc, u32, @intCast(SR));
    try appendInt(&out, alloc, u32, @intCast(SR * 2)); // byte rate
    try appendInt(&out, alloc, u16, 2); // block align
    try appendInt(&out, alloc, u16, 16); // bits
    try out.appendSlice(alloc, "data");
    try appendInt(&out, alloc, u32, data_len);
    for (buf) |x| {
        const v = std.math.clamp(x * scale * 32767.0, -32767.0, 32767.0);
        try appendInt(&out, alloc, i16, @intFromFloat(v));
    }
    return out.toOwnedSlice(alloc);
}

/// Synthesize a cue into a float buffer. Pure — caller owns the buffer.
pub fn renderCueBuffer(alloc: std.mem.Allocator, cue: Cue) ![]f64 {
    var length: usize = 1;
    for (cue.voices) |v| {
        const end: usize = @intFromFloat((v.off + dur(v.n) + v.env.r + 0.4) * @as(f64, @floatFromInt(SR)));
        length = @max(length, end);
    }
    const buf = try alloc.alloc(f64, length);
    errdefer alloc.free(buf);
    @memset(buf, 0);
    for (cue.voices) |v| renderVoice(buf, v, cue.dist);
    if (cue.wet > 0) try reverb(alloc, buf, cue.wet);
    return buf;
}

pub fn renderCue(alloc: std.mem.Allocator, io: std.Io, cue: Cue, out_path: []const u8) !void {
    const buf = try renderCueBuffer(alloc, cue);
    defer alloc.free(buf);
    const bytes = try buildWav(alloc, buf);
    defer alloc.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = bytes });
}

pub const cues = [_]Cue{
    .{ .name = "send", .wet = 0.18, .voices = &.{
        .{ .off = 0.0, .osc = .sine, .note = "C5", .gain = 0.30, .n = 32, .env = .{ .a = 0.002, .d = 0.06, .s = 0, .r = 0.06 } },
        .{ .off = 0.05, .osc = .sine, .note = "G5", .gain = 0.30, .n = 32, .env = .{ .a = 0.002, .d = 0.06, .s = 0, .r = 0.06 } },
    } },
    .{ .name = "tick", .wet = 0.15, .voices = &.{
        .{ .off = 0.0, .osc = .sine, .note = "G4", .gain = 0.25, .n = 32, .env = .{ .a = 0.002, .d = 0.08, .s = 0, .r = 0.10 } },
    } },
    .{ .name = "permission", .wet = 0.2, .voices = &.{
        .{ .off = 0.0, .osc = .triangle, .note = "G5", .gain = 0.6, .n = 16, .env = .{ .a = 0.001, .d = 0.05, .s = 0, .r = 0.05 } },
        .{ .off = 0.16, .osc = .triangle, .note = "G5", .gain = 0.6, .n = 16, .env = .{ .a = 0.001, .d = 0.05, .s = 0, .r = 0.05 } },
    } },
    .{ .name = "reset", .wet = 0.22, .voices = &.{
        .{ .off = 0.0, .osc = .sine, .note = "G3", .gain = 0.55, .n = 16, .env = .{ .a = 0.004, .d = 0.18, .s = 0, .r = 0.12 } },
        .{ .off = 0.1, .osc = .sine, .note = "C3", .gain = 0.55, .n = 16, .env = .{ .a = 0.004, .d = 0.18, .s = 0, .r = 0.12 } },
    } },
    .{ .name = "running", .wet = 0.2, .voices = &.{
        .{ .off = 0.0, .osc = .sine, .note = "E4", .gain = 0.25, .n = 32, .env = .{ .a = 0.002, .d = 0.08, .s = 0, .r = 0.1 } },
    } },
    .{ .name = "failure", .wet = 0.25, .voices = &.{
        .{ .off = 0.0, .osc = .sawtooth, .note = "D2", .gain = 0.65, .n = 4, .env = .{ .a = 0.02, .d = 0.4, .s = 0.1, .r = 0.8 } },
    } },
};

pub fn renderAll(alloc: std.mem.Allocator, io: std.Io, dir: []const u8) !void {
    var buf: [512]u8 = undefined;
    for (cues) |cue| {
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}.wav", .{ dir, cue.name });
        try renderCue(alloc, io, cue, path);
    }
    const flag = try std.fmt.bufPrint(&buf, "{s}/.rendered", .{dir});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = flag, .data = "" });
}

test "render a cue builds a valid WAV (pure)" {
    const a = std.testing.allocator;
    const buf = try renderCueBuffer(a, cues[0]);
    defer a.free(buf);
    const data = try buildWav(a, buf);
    defer a.free(data);
    try std.testing.expect(data.len > 44);
    try std.testing.expectEqualStrings("RIFF", data[0..4]);
    try std.testing.expectEqualStrings("WAVE", data[8..12]);
    var nonzero = false;
    for (data[44..]) |b| {
        if (b != 0) {
            nonzero = true;
            break;
        }
    }
    try std.testing.expect(nonzero);
}

test "noteFreq A4 = 440" {
    try std.testing.expectApproxEqAbs(@as(f64, 440.0), noteFreq("A4"), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 261.6256), noteFreq("C4"), 0.01);
}
