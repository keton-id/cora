const std = @import("std");
const Io = std.Io;

pub const IdleTimer = struct {
    start: Io.Timestamp,
    last_access_ms: std.atomic.Value(i64),
    timeout_ms: i64,

    pub fn init(io: Io, timeout_ms: i64) IdleTimer {
        return .{
            .start = Io.Timestamp.now(io, .awake),
            .last_access_ms = std.atomic.Value(i64).init(0),
            .timeout_ms = timeout_ms,
        };
    }

    pub fn touch(self: *IdleTimer, io: Io) void {
        self.last_access_ms.store(self.elapsed(io), .release);
    }

    pub fn isExpired(self: *const IdleTimer, io: Io) bool {
        if (self.timeout_ms == 0) return false;
        return self.elapsed(io) - self.last_access_ms.load(.acquire) > self.timeout_ms;
    }

    pub fn remainingMs(self: *const IdleTimer, io: Io) u64 {
        if (self.timeout_ms == 0) return std.math.maxInt(u64);
        const since = self.elapsed(io) - self.last_access_ms.load(.acquire);
        if (since >= self.timeout_ms) return 0;
        return @intCast(self.timeout_ms - since);
    }

    fn elapsed(self: *const IdleTimer, io: Io) i64 {
        const now = Io.Timestamp.now(io, .awake);
        return self.start.durationTo(now).toMilliseconds();
    }
};

fn sleepMs(io: Io, ms: i64) void {
    io.sleep(.{ .nanoseconds = ms * std.time.ns_per_ms }, .awake) catch {};
}

test "IdleTimer touch resets remaining" {
    var t = IdleTimer.init(std.testing.io, 1_000);
    sleepMs(std.testing.io, 50);
    const before = t.remainingMs(std.testing.io);
    t.touch(std.testing.io);
    const after = t.remainingMs(std.testing.io);
    try std.testing.expect(after >= before);
}

test "IdleTimer zero timeout never expires" {
    var t = IdleTimer.init(std.testing.io, 0);
    try std.testing.expect(!t.isExpired(std.testing.io));
    try std.testing.expectEqual(std.math.maxInt(u64), t.remainingMs(std.testing.io));
}

test "IdleTimer expires after timeout" {
    var t = IdleTimer.init(std.testing.io, 10);
    sleepMs(std.testing.io, 30);
    try std.testing.expect(t.isExpired(std.testing.io));
    try std.testing.expectEqual(@as(u64, 0), t.remainingMs(std.testing.io));
}
