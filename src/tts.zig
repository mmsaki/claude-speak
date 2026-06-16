//! Text-to-speech over HTTP (std.http) — ElevenLabs / OpenAI. Writes the
//! returned audio to a file. JSON escaping is pure/testable.
const std = @import("std");

/// Minimal JSON string escaping for the request body. Caller owns the result.
pub fn jsonEscape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => if (c < 0x20) {
            var buf: [6]u8 = undefined;
            try out.appendSlice(alloc, try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}));
        } else try out.append(alloc, c),
    };
    return out.toOwnedSlice(alloc);
}

pub const Error = error{HttpStatus} || std.mem.Allocator.Error;

/// POST to ElevenLabs TTS and write the mp3 to `out_path`.
pub fn elevenlabs(
    alloc: std.mem.Allocator,
    io: std.Io,
    key: []const u8,
    voice: []const u8,
    model: []const u8,
    speed: []const u8,
    text: []const u8,
    out_path: []const u8,
) !void {
    const esc = try jsonEscape(alloc, text);
    defer alloc.free(esc);
    const body = try std.fmt.allocPrint(alloc, "{{\"model_id\":\"{s}\",\"text\":\"{s}\",\"voice_settings\":{{\"speed\":{s}}}}}", .{ model, esc, speed });
    defer alloc.free(body);
    const url = try std.fmt.allocPrint(alloc, "https://api.elevenlabs.io/v1/text-to-speech/{s}?output_format=mp3_44100_128", .{voice});
    defer alloc.free(url);

    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{
            .{ .name = "xi-api-key", .value = key },
            .{ .name = "content-type", .value = "application/json" },
        },
        .response_writer = &aw.writer,
    });
    if (res.status != .ok) return error.HttpStatus;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = aw.written() });
}

test "json escape quotes, backslash, control" {
    const a = std.testing.allocator;
    const out = try jsonEscape(a, "a\"b\\c\nd");
    defer a.free(out);
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\nd", out);
}
