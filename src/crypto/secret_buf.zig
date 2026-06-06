const std = @import("std");
const CoraError = @import("../error.zig").CoraError;

pub const max_secret_len: usize = 512;

pub const SecretBuf = struct {
    buf: [max_secret_len]u8 = undefined,
    len: usize = 0,

    // Audit-2026-06: removed the unused mutable `slice()` accessor. The
    // type deliberately exposes only `constSlice()` (read-only) so the
    // contents cannot be written around the secureZero deinit path.
    // A mutable accessor would let callers splice untracked plaintext
    // into the buffer and break the compile-time "no format method"
    // invariant. constSlice is the only legitimate read path.

    pub fn constSlice(self: *const SecretBuf) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *SecretBuf, value: []const u8) CoraError!void {
        if (value.len > self.buf.len) return CoraError.SecretTooLarge;
        @memcpy(self.buf[0..value.len], value);
        self.len = value.len;
    }

    pub fn zero(self: *SecretBuf) void {
        std.crypto.secureZero(u8, &self.buf);
        self.len = 0;
    }
};

test "SecretBuf set roundtrip" {
    var s = SecretBuf{};
    defer s.zero();
    try s.set("ghp_abcdef");
    try std.testing.expectEqualStrings("ghp_abcdef", s.constSlice());
    try std.testing.expectEqual(@as(usize, 10), s.len);
}

test "SecretBuf zero clears buf and len" {
    var s = SecretBuf{};
    try s.set("super-secret-value");
    s.zero();
    try std.testing.expectEqual(@as(usize, 0), s.len);
    for (s.buf) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "SecretBuf rejects oversized input" {
    var s = SecretBuf{};
    defer s.zero();
    var big: [max_secret_len + 1]u8 = undefined;
    @memset(&big, 'x');
    try std.testing.expectError(error.SecretTooLarge, s.set(&big));
}

test "SecretBuf has no format method (compile-time check)" {
    try std.testing.expect(!@hasDecl(SecretBuf, "format"));
}
