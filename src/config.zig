//! Settings resolution. Reads the shell-style `~/.claude/claude-speak/config`
//! (KEY=VALUE / `export KEY=VALUE` lines) and lets environment variables
//! override it — matching the bash hooks. Parser is pure/testable.
const std = @import("std");

pub const Config = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .empty,
    environ: std.process.Environ,

    pub fn get(self: Config, key: []const u8) ?[]const u8 {
        if (self.environ.getPosix(key)) |v| {
            if (v.len > 0) return v;
        }
        return self.map.get(key);
    }
    pub fn getOr(self: Config, key: []const u8, default: []const u8) []const u8 {
        return self.get(key) orelse default;
    }
    pub fn flag(self: Config, key: []const u8, default: bool) bool {
        const v = self.get(key) orelse return default;
        return !std.mem.eql(u8, v, "0");
    }
};

/// Parse a config blob into `map` (allocated in `arena`). Pure.
pub fn parseInto(
    arena: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged([]const u8),
    bytes: []const u8,
) !void {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) {
            line = std.mem.trimStart(u8, line[7..], " \t");
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) continue;
        var val = line[eq + 1 ..];
        if (std.mem.indexOf(u8, val, " #")) |h| val = val[0..h]; // strip inline comment
        val = std.mem.trim(u8, val, " \t");
        if (val.len >= 2 and (val[0] == '"' or val[0] == '\'') and val[val.len - 1] == val[0]) {
            val = val[1 .. val.len - 1];
        }
        try map.put(arena, try arena.dupe(u8, key), try arena.dupe(u8, val));
    }
}

/// CS_HOME: $CLAUDE_SPEAK_HOME or $HOME/.claude/claude-speak. Allocated in arena.
pub fn home(arena: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    if (environ.getPosix("CLAUDE_SPEAK_HOME")) |h| {
        if (h.len > 0) return arena.dupe(u8, h);
    }
    const hd = environ.getPosix("HOME") orelse "/tmp";
    return std.fmt.allocPrint(arena, "{s}/.claude/claude-speak", .{hd});
}

/// Load config from `<home>/config` (missing file is fine). Allocates in arena.
pub fn load(arena: std.mem.Allocator, io: std.Io, environ: std.process.Environ, home_dir: []const u8) !Config {
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    const path = try std.fmt.allocPrint(arena, "{s}/config", .{home_dir});
    if (std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited)) |bytes| {
        try parseInto(arena, &map, bytes);
    } else |_| {}
    return .{ .map = map, .environ = environ };
}

/// Resolve the TTS engine: explicit override, else key-file/env autodetect.
pub fn engine(cfg: Config, has_elevenlabs: bool, has_openai: bool) []const u8 {
    if (cfg.get("CLAUDE_TTS_ENGINE")) |e| {
        if (e.len > 0) return e;
    }
    if (has_elevenlabs) return "elevenlabs";
    if (has_openai) return "openai";
    return "say";
}

test "parse config: export, comments, quotes, override" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    const blob =
        \\# a comment
        \\export CLAUDE_TTS_ENGINE=elevenlabs
        \\export CLAUDE_TTS_SPEED=1.2          # inline comment
        \\export CLAUDE_TTS_VOICE="21m00Tcm"
        \\CLAUDE_CUES=0
    ;
    try parseInto(arena.allocator(), &map, blob);
    try std.testing.expectEqualStrings("elevenlabs", map.get("CLAUDE_TTS_ENGINE").?);
    try std.testing.expectEqualStrings("1.2", map.get("CLAUDE_TTS_SPEED").?);
    try std.testing.expectEqualStrings("21m00Tcm", map.get("CLAUDE_TTS_VOICE").?);
    try std.testing.expectEqualStrings("0", map.get("CLAUDE_CUES").?);
    try std.testing.expect(map.get("missing") == null);
}

test "engine autodetect order" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    const cfg = Config{ .map = map, .environ = .{ .block = .{ .slice = &.{} } } };
    try std.testing.expectEqualStrings("elevenlabs", engine(cfg, true, true));
    try std.testing.expectEqualStrings("openai", engine(cfg, false, true));
    try std.testing.expectEqualStrings("say", engine(cfg, false, false));
    _ = &map;
}
