const std = @import("std");
const Io = std.Io;
const argon2 = std.crypto.pwhash.argon2;
const CoraError = @import("../error.zig").CoraError;

pub const key_len: usize = 32;
pub const salt_len: usize = 16;

pub const Params = argon2.Params{ .t = 3, .m = 65536, .p = 4 };

pub fn deriveKey(
    out: *[key_len]u8,
    passphrase: []const u8,
    salt: *const [salt_len]u8,
    allocator: std.mem.Allocator,
    io: Io,
) CoraError!void {
    argon2.kdf(allocator, out, passphrase, salt, Params, .argon2id, io) catch {
        return CoraError.InvalidPassphrase;
    };
}

pub fn randomSalt(io: Io, out: *[salt_len]u8) void {
    io.random(out);
}

test "deriveKey is deterministic for same passphrase+salt" {
    var salt: [salt_len]u8 = undefined;
    @memset(&salt, 0xab);
    var k1: [key_len]u8 = undefined;
    var k2: [key_len]u8 = undefined;
    defer @memset(&k1, 0);
    defer @memset(&k2, 0);
    try deriveKey(&k1, "correct horse", &salt, std.testing.allocator, std.testing.io);
    try deriveKey(&k2, "correct horse", &salt, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualSlices(u8, &k1, &k2);
}

test "deriveKey diverges on different salt" {
    var s1: [salt_len]u8 = undefined;
    var s2: [salt_len]u8 = undefined;
    @memset(&s1, 0x01);
    @memset(&s2, 0x02);
    var k1: [key_len]u8 = undefined;
    var k2: [key_len]u8 = undefined;
    defer @memset(&k1, 0);
    defer @memset(&k2, 0);
    try deriveKey(&k1, "same pass", &s1, std.testing.allocator, std.testing.io);
    try deriveKey(&k2, "same pass", &s2, std.testing.allocator, std.testing.io);
    try std.testing.expect(!std.mem.eql(u8, &k1, &k2));
}

test "randomSalt produces non-zero bytes" {
    var s: [salt_len]u8 = undefined;
    @memset(&s, 0);
    randomSalt(std.testing.io, &s);
    var all_zero = true;
    for (s) |b| if (b != 0) {
        all_zero = false;
        break;
    };
    try std.testing.expect(!all_zero);
}
