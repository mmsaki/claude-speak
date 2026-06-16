//! Prose cleaning: turn Claude's markdown reply into speakable text.
//! Drops fenced/indented code and tables; keeps inline-code *content* but
//! removes its backticks; reduces links to their text; strips URLs and
//! markdown markers; turns code-ish symbols into spaces so TTS doesn't read
//! "slash"/"underscore". Mirrors the bash cs_clean pipeline.
const std = @import("std");

/// Symbols that should become a space (not spoken). Excludes sentence
/// punctuation . , ! ? : ; ' " which TTS handles as natural pauses.
fn symbolToSpace(c: u8) bool {
    return switch (c) {
        '/', '\\', '|', '=', '+', '<', '>', '{', '}', '(', ')',
        '[', ']', '@', '#', '$', '%', '^', '&', '_', '-' => true,
        else => false,
    };
}

fn leadingSpaces(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') : (n += 1) {}
    return n;
}

fn isTableRow(t: []const u8) bool {
    const r = std.mem.trimEnd(u8, t, " \t");
    return r.len >= 2 and r[0] == '|' and r[r.len - 1] == '|';
}

/// Strip a single leading markdown marker (header / blockquote / bullet).
fn stripLeadingMarker(t: []const u8) []const u8 {
    if (t.len == 0) return t;
    if (t[0] == '#') {
        var i: usize = 0;
        while (i < t.len and t[i] == '#') : (i += 1) {}
        while (i < t.len and t[i] == ' ') : (i += 1) {}
        return t[i..];
    }
    if (t[0] == '>') {
        var i: usize = 1;
        if (i < t.len and t[i] == ' ') i += 1;
        return t[i..];
    }
    if ((t[0] == '-' or t[0] == '*' or t[0] == '+') and t.len > 1 and t[1] == ' ') {
        var i: usize = 1;
        while (i < t.len and t[i] == ' ') : (i += 1) {}
        return t[i..];
    }
    return t;
}

fn cleanLine(alloc: std.mem.Allocator, out: *std.ArrayList(u8), line_in: []const u8) !void {
    const s = stripLeadingMarker(line_in);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        // inline code: drop the backtick, keep the content
        if (c == '`') {
            i += 1;
            continue;
        }
        // image ![alt](url): drop entirely
        if (c == '!' and i + 1 < s.len and s[i + 1] == '[') {
            i += 2;
            while (i < s.len and s[i] != ']') : (i += 1) {}
            if (i < s.len) i += 1; // skip ]
            if (i < s.len and s[i] == '(') {
                while (i < s.len and s[i] != ')') : (i += 1) {}
                if (i < s.len) i += 1; // skip )
            }
            continue;
        }
        // link [text](url): keep text, drop url
        if (c == '[') {
            i += 1;
            const start = i;
            while (i < s.len and s[i] != ']') : (i += 1) {}
            try out.appendSlice(alloc, s[start..i]);
            if (i < s.len) i += 1; // skip ]
            if (i < s.len and s[i] == '(') {
                while (i < s.len and s[i] != ')') : (i += 1) {}
                if (i < s.len) i += 1; // skip )
            }
            continue;
        }
        // bare URL: drop to next whitespace
        if (c == 'h' and (std.mem.startsWith(u8, s[i..], "http://") or
            std.mem.startsWith(u8, s[i..], "https://")))
        {
            while (i < s.len and s[i] != ' ' and s[i] != '\t') : (i += 1) {}
            continue;
        }
        // emphasis markers: drop
        if (c == '*' or c == '~') {
            i += 1;
            continue;
        }
        if (symbolToSpace(c)) {
            try out.append(alloc, ' ');
            i += 1;
            continue;
        }
        try out.append(alloc, c);
        i += 1;
    }
}

/// Clean a full markdown block into speakable prose. Caller owns the result.
pub fn cleanProse(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var in_fence = false;
    var blank_run: usize = 0;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;
        if (leadingSpaces(line) >= 4 and trimmed.len > 0) continue; // indented code
        if (isTableRow(trimmed)) continue;

        var lbuf: std.ArrayList(u8) = .empty;
        defer lbuf.deinit(alloc);
        try cleanLine(alloc, &lbuf, trimmed);

        const cleaned = std.mem.trim(u8, lbuf.items, " \t");
        if (cleaned.len == 0) {
            blank_run += 1;
            if (blank_run < 2) try out.append(alloc, '\n');
            continue;
        }
        blank_run = 0;
        try out.appendSlice(alloc, cleaned);
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

/// Collapse all whitespace runs to single spaces and trim — the speakable form.
pub fn collapse(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var prev_space = true; // trim leading
    for (input) |c| {
        const is_space = c == ' ' or c == '\t' or c == '\n' or c == '\r';
        if (is_space) {
            if (!prev_space) try out.append(alloc, ' ');
            prev_space = true;
        } else {
            try out.append(alloc, c);
            prev_space = false;
        }
    }
    var items = out.items;
    if (items.len > 0 and items[items.len - 1] == ' ') items = items[0 .. items.len - 1];
    return alloc.dupe(u8, items);
}

test "inline code content kept, backticks and symbols gone" {
    const a = std.testing.allocator;
    const raw = try cleanProse(a, "Call `runMigration()` and set `my_var` = 3 at /tmp/foo-bar.");
    defer a.free(raw);
    const out = try collapse(a, raw);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "runMigration") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "my var") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "foo bar") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "`") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_") == null);
}

test "fenced code block removed, prose kept" {
    const a = std.testing.allocator;
    const out = try cleanProse(a, "before it\n```js\nconsole.log(1);\n```\nafter it");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "console") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "before it") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "after it") != null);
}

test "link text kept, url dropped" {
    const a = std.testing.allocator;
    const raw = try cleanProse(a, "see the [docs](https://example.com/x) now");
    defer a.free(raw);
    const out = try collapse(a, raw);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "docs") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "example.com") == null);
    try std.testing.expectEqualStrings("see the docs now", out);
}

test "headers and bullets stripped" {
    const a = std.testing.allocator;
    const raw = try cleanProse(a, "## Title here\n- a point\n- another");
    defer a.free(raw);
    const out = try collapse(a, raw);
    defer a.free(out);
    try std.testing.expectEqualStrings("Title here a point another", out);
}
