const std = @import("std");
const CoraError = @import("../error.zig").CoraError;

pub const Cipher = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
pub const nonce_len: usize = Cipher.nonce_length;
pub const tag_len: usize = Cipher.tag_length;
pub const key_len: usize = Cipher.key_length;

pub fn encrypt(
    ciphertext: []u8,
    tag: *[tag_len]u8,
    plaintext: []const u8,
    additional_data: []const u8,
    nonce: *const [nonce_len]u8,
    key: *const [key_len]u8,
) void {
    std.debug.assert(ciphertext.len == plaintext.len);
    Cipher.encrypt(ciphertext, tag, plaintext, additional_data, nonce.*, key.*);
}

pub fn decrypt(
    plaintext: []u8,
    ciphertext: []const u8,
    tag: *const [tag_len]u8,
    additional_data: []const u8,
    nonce: *const [nonce_len]u8,
    key: *const [key_len]u8,
) CoraError!void {
    std.debug.assert(plaintext.len == ciphertext.len);
    Cipher.decrypt(plaintext, ciphertext, tag.*, additional_data, nonce.*, key.*) catch {
        return CoraError.AuthFailed;
    };
}

pub fn randomNonce(io: std.Io, out: *[nonce_len]u8) void {
    io.random(out);
}

test "encrypt/decrypt roundtrip" {
    var key: [key_len]u8 = undefined;
    @memset(&key, 0x11);
    var nonce: [nonce_len]u8 = undefined;
    @memset(&nonce, 0x22);
    const msg = "hello cora";
    var ct: [msg.len]u8 = undefined;
    var tag: [tag_len]u8 = undefined;
    encrypt(&ct, &tag, msg, "v1", &nonce, &key);
    var pt: [msg.len]u8 = undefined;
    try decrypt(&pt, &ct, &tag, "v1", &nonce, &key);
    try std.testing.expectEqualStrings(msg, &pt);
}

test "decrypt rejects wrong key" {
    var key: [key_len]u8 = undefined;
    @memset(&key, 0x11);
    var nonce: [nonce_len]u8 = undefined;
    @memset(&nonce, 0x22);
    const msg = "secret";
    var ct: [msg.len]u8 = undefined;
    var tag: [tag_len]u8 = undefined;
    encrypt(&ct, &tag, msg, "", &nonce, &key);

    key[0] ^= 1;
    var pt: [msg.len]u8 = undefined;
    try std.testing.expectError(error.AuthFailed, decrypt(&pt, &ct, &tag, "", &nonce, &key));
}

test "decrypt rejects tampered ciphertext" {
    var key: [key_len]u8 = undefined;
    @memset(&key, 0x11);
    var nonce: [nonce_len]u8 = undefined;
    @memset(&nonce, 0x22);
    const msg = "tampered";
    var ct: [msg.len]u8 = undefined;
    var tag: [tag_len]u8 = undefined;
    encrypt(&ct, &tag, msg, "", &nonce, &key);

    ct[0] ^= 0x80;
    var pt: [msg.len]u8 = undefined;
    try std.testing.expectError(error.AuthFailed, decrypt(&pt, &ct, &tag, "", &nonce, &key));
}

test "decrypt rejects wrong additional data" {
    var key: [key_len]u8 = undefined;
    @memset(&key, 0x11);
    var nonce: [nonce_len]u8 = undefined;
    @memset(&nonce, 0x22);
    const msg = "aad-bound";
    var ct: [msg.len]u8 = undefined;
    var tag: [tag_len]u8 = undefined;
    encrypt(&ct, &tag, msg, "v1", &nonce, &key);

    var pt: [msg.len]u8 = undefined;
    try std.testing.expectError(error.AuthFailed, decrypt(&pt, &ct, &tag, "v2", &nonce, &key));
}
