const std = @import("std");
const derive = @import("../crypto/derive.zig");
const aead = @import("../crypto/aead.zig");
const CoraError = @import("../error.zig").CoraError;

pub const magic: [4]u8 = .{ 'C', 'O', 'R', 'A' };
pub const version: u8 = 1;

pub const Header = struct {
    salt: [derive.salt_len]u8,
    nonce: [aead.nonce_len]u8,
};

pub const header_size: usize = magic.len + 1 + derive.salt_len + aead.nonce_len;

pub const Parsed = struct {
    header: Header,
    config_bytes: []const u8,
    secrets_ct: []const u8,
    secrets_tag: [aead.tag_len]u8,

    pub fn additionalData(self: *const Parsed, buf: *[header_size]u8) []const u8 {
        @memcpy(buf[0..magic.len], &magic);
        buf[magic.len] = version;
        @memcpy(buf[magic.len + 1 ..][0..derive.salt_len], &self.header.salt);
        @memcpy(buf[magic.len + 1 + derive.salt_len ..][0..aead.nonce_len], &self.header.nonce);
        return buf[0..];
    }
};

pub fn encode(
    allocator: std.mem.Allocator,
    header: Header,
    config_bytes: []const u8,
    secrets_ct: []const u8,
    secrets_tag: *const [aead.tag_len]u8,
) ![]u8 {
    const total = header_size + 4 + config_bytes.len + 4 + secrets_ct.len + aead.tag_len;
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);

    var i: usize = 0;
    @memcpy(out[i..][0..magic.len], &magic);
    i += magic.len;
    out[i] = version;
    i += 1;
    @memcpy(out[i..][0..derive.salt_len], &header.salt);
    i += derive.salt_len;
    @memcpy(out[i..][0..aead.nonce_len], &header.nonce);
    i += aead.nonce_len;

    std.mem.writeInt(u32, out[i..][0..4], @intCast(config_bytes.len), .little);
    i += 4;
    @memcpy(out[i..][0..config_bytes.len], config_bytes);
    i += config_bytes.len;

    std.mem.writeInt(u32, out[i..][0..4], @intCast(secrets_ct.len), .little);
    i += 4;
    @memcpy(out[i..][0..secrets_ct.len], secrets_ct);
    i += secrets_ct.len;
    @memcpy(out[i..][0..aead.tag_len], secrets_tag);
    i += aead.tag_len;

    std.debug.assert(i == total);
    return out;
}

pub fn decode(bytes: []const u8) CoraError!Parsed {
    if (bytes.len < header_size + 4 + 4 + aead.tag_len) return CoraError.InvalidConfig;
    var i: usize = 0;
    if (!std.mem.eql(u8, bytes[i..][0..magic.len], &magic)) return CoraError.InvalidConfig;
    i += magic.len;
    const ver = bytes[i];
    i += 1;
    if (ver != version) return CoraError.UnsupportedVersion;

    var header: Header = undefined;
    @memcpy(&header.salt, bytes[i..][0..derive.salt_len]);
    i += derive.salt_len;
    @memcpy(&header.nonce, bytes[i..][0..aead.nonce_len]);
    i += aead.nonce_len;

    if (bytes.len < i + 4) return CoraError.InvalidConfig;
    const cfg_len = std.mem.readInt(u32, bytes[i..][0..4], .little);
    i += 4;
    if (bytes.len < i + cfg_len + 4 + aead.tag_len) return CoraError.InvalidConfig;
    const config_bytes = bytes[i..][0..cfg_len];
    i += cfg_len;

    const ct_len = std.mem.readInt(u32, bytes[i..][0..4], .little);
    i += 4;
    if (bytes.len < i + ct_len + aead.tag_len) return CoraError.InvalidConfig;
    const secrets_ct = bytes[i..][0..ct_len];
    i += ct_len;
    var tag: [aead.tag_len]u8 = undefined;
    @memcpy(&tag, bytes[i..][0..aead.tag_len]);
    i += aead.tag_len;
    if (i != bytes.len) return CoraError.InvalidConfig;

    return .{
        .header = header,
        .config_bytes = config_bytes,
        .secrets_ct = secrets_ct,
        .secrets_tag = tag,
    };
}

test "encode/decode roundtrip" {
    const allocator = std.testing.allocator;
    var header: Header = undefined;
    @memset(&header.salt, 0xaa);
    @memset(&header.nonce, 0xbb);
    const cfg = "policy=stub";
    const ct = [_]u8{ 1, 2, 3, 4, 5 };
    var tag: [aead.tag_len]u8 = undefined;
    @memset(&tag, 0xcc);
    const blob = try encode(allocator, header, cfg, &ct, &tag);
    defer allocator.free(blob);

    const parsed = try decode(blob);
    try std.testing.expectEqualSlices(u8, &header.salt, &parsed.header.salt);
    try std.testing.expectEqualSlices(u8, &header.nonce, &parsed.header.nonce);
    try std.testing.expectEqualStrings(cfg, parsed.config_bytes);
    try std.testing.expectEqualSlices(u8, &ct, parsed.secrets_ct);
    try std.testing.expectEqualSlices(u8, &tag, &parsed.secrets_tag);
}

test "decode rejects bad magic" {
    const bytes = [_]u8{ 'X', 'X', 'X', 'X' } ++ [_]u8{0} ** (header_size - 4 + 4 + 4 + aead.tag_len);
    try std.testing.expectError(error.InvalidConfig, decode(&bytes));
}

test "decode rejects truncated input" {
    const bytes = [_]u8{ 'C', 'O', 'R', 'A', 1 };
    try std.testing.expectError(error.InvalidConfig, decode(&bytes));
}
