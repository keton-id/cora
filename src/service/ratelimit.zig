const std = @import("std");

/// Fixed-window spawn counter for one task. The service keeps one `Window`
/// per task name and consults it before every spawn, bounding how many
/// child processes a trusted caller can launch — and therefore how many
/// times it can pull a secret into a subprocess — within a time window.
///
/// Fixed-window (not token-bucket) on purpose: the threat is bulk
/// exfiltration attempts, not smoothing bursty legitimate traffic. A window
/// that resets wholesale is simpler to reason about and cannot leak more
/// than `max` spawns per `window_ms`, which is the property we want to state
/// in the audit log. The clock is injected so the logic is deterministic
/// under test.
pub const Window = struct {
    start_ms: i64 = 0,
    count: u32 = 0,

    /// Record a spawn attempt at `now_ms` and return whether it is allowed.
    /// `max == 0` disables the limit (always allowed). When the current
    /// window has elapsed the counter resets and the attempt starts a fresh
    /// window.
    pub fn allow(self: *Window, now_ms: i64, max: u32, window_ms: i64) bool {
        if (max == 0) return true;
        if (self.count == 0 or (now_ms - self.start_ms) >= window_ms) {
            self.start_ms = now_ms;
            self.count = 1;
            return true;
        }
        if (self.count >= max) return false;
        self.count += 1;
        return true;
    }
};

test "max 0 means unlimited" {
    var w = Window{};
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expect(w.allow(@intCast(i), 0, 1000));
    }
}

test "blocks after max within window, resets after window elapses" {
    var w = Window{};
    try std.testing.expect(w.allow(0, 2, 1000)); // 1st
    try std.testing.expect(w.allow(100, 2, 1000)); // 2nd
    try std.testing.expect(!w.allow(200, 2, 1000)); // 3rd — over limit
    try std.testing.expect(!w.allow(999, 2, 1000)); // still in window
    try std.testing.expect(w.allow(1000, 2, 1000)); // window elapsed — reset
    try std.testing.expect(w.allow(1100, 2, 1000)); // 2nd of new window
    try std.testing.expect(!w.allow(1200, 2, 1000)); // over again
}

test "max 1 allows exactly one per window" {
    var w = Window{};
    try std.testing.expect(w.allow(0, 1, 500));
    try std.testing.expect(!w.allow(499, 1, 500));
    try std.testing.expect(w.allow(500, 1, 500));
}
