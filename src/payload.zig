//! Parse Claude Code hook payloads and transcript JSONL. Pure over bytes
//! (caller does the file read), so it's fully unit-testable.
const std = @import("std");

fn getStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .string) f.string else null;
}

fn strEql(a: ?[]const u8, b: []const u8) bool {
    return a != null and std.mem.eql(u8, a.?, b);
}

pub const Payload = struct {
    transcript_path: ?[]u8 = null,
    session_id: ?[]u8 = null,
    source: ?[]u8 = null,
    tool_name: ?[]u8 = null,

    pub fn deinit(self: *Payload, alloc: std.mem.Allocator) void {
        if (self.transcript_path) |s| alloc.free(s);
        if (self.session_id) |s| alloc.free(s);
        if (self.source) |s| alloc.free(s);
        if (self.tool_name) |s| alloc.free(s);
    }
};

fn dupOpt(alloc: std.mem.Allocator, s: ?[]const u8) !?[]u8 {
    return if (s) |v| try alloc.dupe(u8, v) else null;
}

/// Parse a hook payload's top-level fields. Caller owns the returned Payload.
pub fn parsePayload(alloc: std.mem.Allocator, bytes: []const u8) !Payload {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return .{};
    defer parsed.deinit();
    const root = parsed.value;
    return .{
        .transcript_path = try dupOpt(alloc, getStr(root, "transcript_path")),
        .session_id = try dupOpt(alloc, getStr(root, "session_id")),
        .source = try dupOpt(alloc, getStr(root, "source")),
        .tool_name = try dupOpt(alloc, getStr(root, "tool_name")),
    };
}

/// Concatenate the text of every assistant message in a transcript (JSONL).
/// Raw (uncleaned) — the caller runs clean.cleanProse on the result.
pub fn assistantText(alloc: std.mem.Allocator, jsonl: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var lines = std.mem.splitScalar(u8, jsonl, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, t, .{}) catch continue;
        defer parsed.deinit();
        const root = parsed.value;
        if (!strEql(getStr(root, "type"), "assistant")) continue;
        if (root != .object) continue;
        const msg = root.object.get("message") orelse continue;
        if (msg != .object) continue;
        const content = msg.object.get("content") orelse continue;
        if (content != .array) continue;
        for (content.array.items) |item| {
            if (!strEql(getStr(item, "type"), "text")) continue;
            if (item.object.get("text")) |txt| {
                if (txt == .string) {
                    try out.appendSlice(alloc, txt.string);
                    try out.append(alloc, ' ');
                }
            }
        }
    }
    return out.toOwnedSlice(alloc);
}

test "parse payload top-level fields" {
    const a = std.testing.allocator;
    var p = try parsePayload(a,
        \\{"transcript_path":"/tmp/t.jsonl","session_id":"S1","source":"startup"}
    );
    defer p.deinit(a);
    try std.testing.expectEqualStrings("/tmp/t.jsonl", p.transcript_path.?);
    try std.testing.expectEqualStrings("S1", p.session_id.?);
    try std.testing.expectEqualStrings("startup", p.source.?);
    try std.testing.expect(p.tool_name == null);
}

test "assistant text concatenated across lines" {
    const a = std.testing.allocator;
    const jsonl =
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"Hello there."}]}}
        \\{"type":"user","message":{"content":[{"type":"text","text":"ignore me"}]}}
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"Second part."},{"type":"tool_use","name":"X"}]}}
    ;
    const txt = try assistantText(a, jsonl);
    defer a.free(txt);
    try std.testing.expect(std.mem.indexOf(u8, txt, "Hello there.") != null);
    try std.testing.expect(std.mem.indexOf(u8, txt, "Second part.") != null);
    try std.testing.expect(std.mem.indexOf(u8, txt, "ignore me") == null);
}
