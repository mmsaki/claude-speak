//! The player state machine — queue, position, follow-mode, mute/pause, and
//! response-boundary navigation. Pure (no threads/IO) so it's fully testable;
//! the daemon wires threads + FIFO + afplay around it.
//!
//! Positions are 0-based. `pos == count()` means "at the live edge" (nothing to
//! play yet) — the daemon idles there until a new segment arrives.
const std = @import("std");

pub const Segment = struct {
    text: []const u8, // owned
    audio: ?[]const u8 = null, // owned synth path, set once rendered
    resp_start: bool = false, // first segment of a response (for rprev/rnext)
};

pub const Queue = struct {
    alloc: std.mem.Allocator,
    segs: std.ArrayList(Segment) = .empty,
    pos: usize = 0,
    paused: bool = false,
    muted: bool = false,
    max_lag: ?usize = null,
    pending_response: bool = true,

    pub fn init(alloc: std.mem.Allocator) Queue {
        return .{ .alloc = alloc };
    }
    pub fn deinit(self: *Queue) void {
        for (self.segs.items) |s| {
            self.alloc.free(s.text);
            if (s.audio) |a| self.alloc.free(a);
        }
        self.segs.deinit(self.alloc);
    }

    pub fn count(self: *const Queue) usize {
        return self.segs.items.len;
    }

    /// Append a segment; marks a response boundary if one is pending. Returns index.
    pub fn enqueue(self: *Queue, text: []const u8) !usize {
        const rs = self.pending_response or self.count() == 0;
        try self.segs.append(self.alloc, .{ .text = try self.alloc.dupe(u8, text), .resp_start = rs });
        self.pending_response = false;
        return self.count() - 1;
    }

    /// Mark that the current response is finished — the next enqueue starts a new one.
    pub fn endResponse(self: *Queue) void {
        self.pending_response = true;
    }

    pub fn setAudio(self: *Queue, idx: usize, path: []const u8) !void {
        if (idx >= self.count()) return;
        const seg = &self.segs.items[idx];
        if (seg.audio) |a| self.alloc.free(a);
        seg.audio = try self.alloc.dupe(u8, path);
    }

    pub fn current(self: *Queue) ?*Segment {
        if (self.pos >= self.count()) return null;
        return &self.segs.items[self.pos];
    }

    fn clamp(self: *Queue) void {
        if (self.pos > self.count()) self.pos = self.count();
    }

    pub fn advance(self: *Queue) void { // natural end of a segment
        self.pos += 1;
        self.clamp();
    }
    pub fn next(self: *Queue) void {
        self.pos += 1;
        self.clamp();
    }
    pub fn prev(self: *Queue) void {
        self.pos = if (self.pos > 0) self.pos - 1 else 0;
    }
    pub fn last(self: *Queue) void {
        self.pos = if (self.count() > 0) self.count() - 1 else 0;
    }
    pub fn goto(self: *Queue, i: usize) void {
        self.pos = i;
        self.clamp();
    }

    /// Jump to the start of the previous response (or the first segment).
    pub fn rprev(self: *Queue) void {
        var target: usize = 0;
        var i: usize = 0;
        while (i < self.pos and i < self.count()) : (i += 1) {
            if (self.segs.items[i].resp_start) target = i;
        }
        self.pos = target;
    }
    /// Jump to the start of the next response (no-op if none).
    pub fn rnext(self: *Queue) void {
        var i: usize = self.pos + 1;
        while (i < self.count()) : (i += 1) {
            if (self.segs.items[i].resp_start) {
                self.pos = i;
                return;
            }
        }
    }

    /// Follow mode: never trail more than max_lag behind the newest segment.
    pub fn catchUp(self: *Queue) void {
        const ml = self.max_lag orelse return;
        const total = self.count();
        if (total > ml and (total - self.pos) > ml) self.pos = total - ml;
    }

    pub fn setMuted(self: *Queue, m: bool) void {
        self.muted = m;
    }
    /// While muted, the daemon parks at the live edge so unmute is current.
    pub fn liveEdge(self: *const Queue) usize {
        return self.count();
    }
};

test "enqueue, count, current" {
    const a = std.testing.allocator;
    var q = Queue.init(a);
    defer q.deinit();
    _ = try q.enqueue("one");
    _ = try q.enqueue("two");
    try std.testing.expectEqual(@as(usize, 2), q.count());
    try std.testing.expectEqualStrings("one", q.current().?.text);
    q.advance();
    try std.testing.expectEqualStrings("two", q.current().?.text);
    q.advance();
    try std.testing.expect(q.current() == null); // live edge
}

test "next/prev clamp" {
    const a = std.testing.allocator;
    var q = Queue.init(a);
    defer q.deinit();
    _ = try q.enqueue("a");
    _ = try q.enqueue("b");
    _ = try q.enqueue("c");
    q.prev(); // clamp at 0
    try std.testing.expectEqual(@as(usize, 0), q.pos);
    q.next();
    q.next();
    q.next();
    q.next(); // clamp at count
    try std.testing.expectEqual(@as(usize, 3), q.pos);
    q.last();
    try std.testing.expectEqual(@as(usize, 2), q.pos);
}

test "follow-mode catch-up bounds lag" {
    const a = std.testing.allocator;
    var q = Queue.init(a);
    defer q.deinit();
    q.max_lag = 2;
    var i: usize = 0;
    while (i < 10) : (i += 1) _ = try q.enqueue("x");
    q.pos = 0;
    q.catchUp(); // 10 segments, lag>2 -> jump to 8
    try std.testing.expectEqual(@as(usize, 8), q.pos);
}

test "response boundaries + rprev/rnext" {
    const a = std.testing.allocator;
    var q = Queue.init(a);
    defer q.deinit();
    _ = try q.enqueue("r1a"); // response 1 start (idx 0)
    _ = try q.enqueue("r1b");
    q.endResponse();
    _ = try q.enqueue("r2a"); // response 2 start (idx 2)
    q.endResponse();
    _ = try q.enqueue("r3a"); // response 3 start (idx 3)
    try std.testing.expect(q.segs.items[0].resp_start);
    try std.testing.expect(!q.segs.items[1].resp_start);
    try std.testing.expect(q.segs.items[2].resp_start);
    try std.testing.expect(q.segs.items[3].resp_start);
    q.pos = 3;
    q.rprev();
    try std.testing.expectEqual(@as(usize, 2), q.pos); // start of response 2
    q.rprev();
    try std.testing.expectEqual(@as(usize, 0), q.pos); // start of response 1
    q.rnext();
    try std.testing.expectEqual(@as(usize, 2), q.pos);
}
