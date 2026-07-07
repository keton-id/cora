const std = @import("std");
const Io = std.Io;

/// A SHA-256 digest rendered as 64 lowercase hex characters.
pub const hex_len: usize = 64;

/// Compute the lowercase-hex SHA-256 of `data`. Used to pin an allowed
/// caller to a specific binary image: the path-based allowlist alone lets a
/// same-uid attacker swap the binary at an approved path, so a pinned caller
/// additionally commits to the exact bytes of that binary.
pub fn sha256Hex(data: []const u8) [hex_len]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Hash the file at `path` (relative to `dir`, or absolute) and return the
/// lowercase-hex SHA-256. The whole file is read into memory once; caller
/// binaries are bounded well under the 256 MiB cap. Errors bubble up so the
/// service can fail closed (reject the caller) rather than skip the check.
pub fn hashFileHex(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    path: []const u8,
) ![hex_len]u8 {
    const bytes = try dir.readFileAlloc(io, path, allocator, .limited(256 * 1024 * 1024));
    defer allocator.free(bytes);
    return sha256Hex(bytes);
}

/// Constant-time-ish equality of two hex digests. Length-checked first, then
/// a byte compare that does not early-exit on the first mismatch. A hash
/// comparison is not a high-value timing target (the attacker would need to
/// grind a preimage, not guess a MAC), but the constant-time form costs
/// nothing and documents intent.
pub fn hexEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

test "sha256Hex matches known vector for 'abc'" {
    const got = sha256Hex("abc");
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &got,
    );
}

test "sha256Hex of empty input" {
    const got = sha256Hex("");
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &got,
    );
}

test "hexEql true for identical, false for differing" {
    try std.testing.expect(hexEql("deadbeef", "deadbeef"));
    try std.testing.expect(!hexEql("deadbeef", "deadbeff"));
    try std.testing.expect(!hexEql("dead", "deadbeef"));
}

test "hashFileHex matches sha256Hex of file contents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blob", .data = "abc" });
    const got = try hashFileHex(std.testing.allocator, std.testing.io, tmp.dir, "blob");
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &got,
    );
}
