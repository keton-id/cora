const std = @import("std");
const Io = std.Io;
const derive = @import("../crypto/derive.zig");
const aead = @import("../crypto/aead.zig");
const format = @import("format.zig");
const codec = @import("secrets_codec.zig");
const MemStore = @import("mem.zig").MemStore;
const CoraError = @import("../error.zig").CoraError;

pub const min_passphrase_len: usize = 8;

pub const InitParams = struct {
    passphrase: []const u8,
    config_bytes: []const u8 = "",
    secrets_plaintext: []const u8 = "{}",
};

pub const EncodedFile = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EncodedFile) void {
        self.allocator.free(self.bytes);
    }
};

pub fn createEncrypted(
    allocator: std.mem.Allocator,
    io: Io,
    p: InitParams,
) !EncodedFile {
    if (p.passphrase.len < min_passphrase_len) return CoraError.PassphraseTooShort;

    var header: format.Header = undefined;
    derive.randomSalt(io, &header.salt);
    aead.randomNonce(io, &header.nonce);

    var key: [derive.key_len]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    try derive.deriveKey(&key, p.passphrase, &header.salt, allocator, io);

    const ct = try allocator.alloc(u8, p.secrets_plaintext.len);
    defer allocator.free(ct);
    var tag: [aead.tag_len]u8 = undefined;

    var aad_buf: [format.header_size]u8 = undefined;
    const aad = buildAad(&aad_buf, &header);

    aead.encrypt(ct, &tag, p.secrets_plaintext, aad, &header.nonce, &key);

    const bytes = try format.encode(allocator, header, p.config_bytes, ct, &tag);
    return .{ .bytes = bytes, .allocator = allocator };
}

pub const Decrypted = struct {
    config_bytes: []const u8,
    secrets_plaintext: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Decrypted) void {
        std.crypto.secureZero(u8, self.secrets_plaintext);
        self.allocator.free(self.secrets_plaintext);
    }
};

pub fn decrypt(
    allocator: std.mem.Allocator,
    io: Io,
    passphrase: []const u8,
    encoded: []const u8,
) !Decrypted {
    const parsed = try format.decode(encoded);

    var key: [derive.key_len]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    try derive.deriveKey(&key, passphrase, &parsed.header.salt, allocator, io);

    var aad_buf: [format.header_size]u8 = undefined;
    const aad = buildAad(&aad_buf, &parsed.header);

    const pt = try allocator.alloc(u8, parsed.secrets_ct.len);
    errdefer {
        std.crypto.secureZero(u8, pt);
        allocator.free(pt);
    }

    try aead.decrypt(pt, parsed.secrets_ct, &parsed.secrets_tag, aad, &parsed.header.nonce, &key);

    return .{
        .config_bytes = parsed.config_bytes,
        .secrets_plaintext = pt,
        .allocator = allocator,
    };
}

fn buildAad(buf: *[format.header_size]u8, header: *const format.Header) []const u8 {
    @memcpy(buf[0..format.magic.len], &format.magic);
    buf[format.magic.len] = format.version;
    @memcpy(buf[format.magic.len + 1 ..][0..derive.salt_len], &header.salt);
    @memcpy(buf[format.magic.len + 1 + derive.salt_len ..][0..aead.nonce_len], &header.nonce);
    return buf[0..];
}

/// Atomic write: stream to `<path>.tmp`, fsync, then rename onto the target.
/// On crash or partial write the original `path` is untouched. `<path>.tmp`
/// is removed on any error before rename.
pub fn writeFile(io: Io, dir: Io.Dir, path: []const u8, bytes: []const u8) !void {
    var tmp_buf: [std.posix.PATH_MAX]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});

    {
        var file = try dir.createFile(io, tmp_path, .{ .exclusive = false, .truncate = true });
        errdefer dir.deleteFile(io, tmp_path) catch {};
        defer file.close(io);

        if (@hasDecl(std.posix, "fchmod")) {
            std.posix.fchmod(file.handle, 0o600) catch {};
        }
        try file.writeStreamingAll(io, bytes);
        try file.sync(io);
    }

    errdefer dir.deleteFile(io, tmp_path) catch {};
    try dir.rename(tmp_path, dir, path, io);
}

pub fn readFile(allocator: std.mem.Allocator, io: Io, dir: Io.Dir, path: []const u8) ![]u8 {
    return dir.readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
}

pub fn loadSecrets(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    path: []const u8,
    passphrase: []const u8,
    out: *MemStore,
) !void {
    const encoded = try readFile(allocator, io, dir, path);
    defer allocator.free(encoded);
    var d = try decrypt(allocator, io, passphrase, encoded);
    defer d.deinit();
    try codec.decode(allocator, d.secrets_plaintext, out);
}

pub fn saveSecrets(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    path: []const u8,
    passphrase: []const u8,
    secrets: *const MemStore,
    config_bytes: []const u8,
) !void {
    var enc = try codec.encode(allocator, secrets);
    defer enc.deinit();

    var ef = try createEncrypted(allocator, io, .{
        .passphrase = passphrase,
        .config_bytes = config_bytes,
        .secrets_plaintext = enc.bytes,
    });
    defer ef.deinit();

    try writeFile(io, dir, path, ef.bytes);
}

test "createEncrypted + decrypt roundtrip" {
    const allocator = std.testing.allocator;
    var ef = try createEncrypted(allocator, std.testing.io, .{
        .passphrase = "correct horse battery staple",
        .config_bytes = "v=1",
        .secrets_plaintext = "{\"K\":\"v\"}",
    });
    defer ef.deinit();

    var d = try decrypt(allocator, std.testing.io, "correct horse battery staple", ef.bytes);
    defer d.deinit();

    try std.testing.expectEqualStrings("v=1", d.config_bytes);
    try std.testing.expectEqualStrings("{\"K\":\"v\"}", d.secrets_plaintext);
}

test "decrypt rejects wrong passphrase" {
    const allocator = std.testing.allocator;
    var ef = try createEncrypted(allocator, std.testing.io, .{
        .passphrase = "correct horse battery staple",
    });
    defer ef.deinit();

    try std.testing.expectError(
        error.AuthFailed,
        decrypt(allocator, std.testing.io, "wrong passphrase here", ef.bytes),
    );
}

test "decrypt rejects tampered file" {
    const allocator = std.testing.allocator;
    var ef = try createEncrypted(allocator, std.testing.io, .{
        .passphrase = "correct horse battery staple",
    });
    defer ef.deinit();

    ef.bytes[ef.bytes.len - 1] ^= 0xff;
    try std.testing.expectError(
        error.AuthFailed,
        decrypt(allocator, std.testing.io, "correct horse battery staple", ef.bytes),
    );
}

test "createEncrypted rejects short passphrase" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.PassphraseTooShort,
        createEncrypted(allocator, std.testing.io, .{ .passphrase = "short" }),
    );
}

test "loadSecrets/saveSecrets in-memory roundtrip via tmp dir" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = "cora.zon";
    const passphrase = "correct horse battery staple";

    var initial = MemStore.init(allocator);
    defer initial.deinit();
    try initial.put("GITHUB_TOKEN", "ghp_xxx");
    try initial.put("STRIPE_KEY", "sk_yyy");

    try saveSecrets(allocator, std.testing.io, tmp.dir, path, passphrase, &initial, "");

    var loaded = MemStore.init(allocator);
    defer loaded.deinit();
    try loadSecrets(allocator, std.testing.io, tmp.dir, path, passphrase, &loaded);

    try std.testing.expectEqual(@as(usize, 2), loaded.count());
    var out = @import("../crypto/secret_buf.zig").SecretBuf{};
    defer out.zero();
    try loaded.copyInto("GITHUB_TOKEN", &out);
    try std.testing.expectEqualStrings("ghp_xxx", out.constSlice());
    out.zero();
    try loaded.copyInto("STRIPE_KEY", &out);
    try std.testing.expectEqualStrings("sk_yyy", out.constSlice());
}

test "loadSecrets rejects wrong passphrase" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var s = MemStore.init(allocator);
    defer s.deinit();
    try s.put("K", "v");
    try saveSecrets(allocator, std.testing.io, tmp.dir, "cora.zon", "correct horse battery staple", &s, "");

    var loaded = MemStore.init(allocator);
    defer loaded.deinit();
    try std.testing.expectError(
        error.AuthFailed,
        loadSecrets(allocator, std.testing.io, tmp.dir, "cora.zon", "wrong-passphrase-here", &loaded),
    );
}

test "writeFile leaves no .tmp sibling on success" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = "cora.zon";
    try writeFile(std.testing.io, tmp.dir, path, "hello atomic world");

    // Target file present with right content.
    const got = try tmp.dir.readFileAlloc(std.testing.io, path, allocator, .limited(4096));
    defer allocator.free(got);
    try std.testing.expectEqualStrings("hello atomic world", got);

    // No stale temp file.
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(std.testing.io, "cora.zon.tmp", .{}),
    );
}

// Regression for WINDOWS-AUDIT.md claim #2: rewrite of an existing target must
// succeed on every supported platform. Zig 0.16's Io.Dir.rename invokes
// NtSetInformationFile with REPLACE_IF_EXISTS=true on Windows, so writeFile is
// already atomic-replace there; this test pins that contract so a stdlib
// regression cannot silently break Windows mutation flows (secrets set/delete,
// policy edits).
test "writeFile replaces existing target across platforms" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = "cora.zon";
    try writeFile(std.testing.io, tmp.dir, path, "first payload");
    try writeFile(std.testing.io, tmp.dir, path, "second payload");

    const got = try tmp.dir.readFileAlloc(std.testing.io, path, allocator, .limited(4096));
    defer allocator.free(got);
    try std.testing.expectEqualStrings("second payload", got);

    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(std.testing.io, "cora.zon.tmp", .{}),
    );
}

test "saveSecrets preserves config_bytes across mutation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = "cora.zon";
    const passphrase = "correct horse battery staple";
    const initial_cfg =
        \\.{
        \\    .allowed_callers = .{ "/usr/local/bin/cr" },
        \\    .idle_timeout_ms = 900000,
        \\    .tasks = .{ .{ .name = "demo", .allowed_secrets = .{ "API_KEY" } } },
        \\}
    ;

    var initial = MemStore.init(allocator);
    defer initial.deinit();
    try initial.put("API_KEY", "sk-aaa");
    try saveSecrets(allocator, std.testing.io, tmp.dir, path, passphrase, &initial, initial_cfg);

    // Simulate `cr secrets set`: read existing, mutate, write back with same config.
    const encoded = try readFile(allocator, std.testing.io, tmp.dir, path);
    defer allocator.free(encoded);
    var dec = try decrypt(allocator, std.testing.io, passphrase, encoded);
    defer dec.deinit();

    var loaded = MemStore.init(allocator);
    defer loaded.deinit();
    try codec.decode(allocator, dec.secrets_plaintext, &loaded);
    try loaded.put("NEW_KEY", "sk-bbb");
    try saveSecrets(allocator, std.testing.io, tmp.dir, path, passphrase, &loaded, dec.config_bytes);

    // Re-decrypt and assert config_bytes survived.
    const encoded2 = try readFile(allocator, std.testing.io, tmp.dir, path);
    defer allocator.free(encoded2);
    var dec2 = try decrypt(allocator, std.testing.io, passphrase, encoded2);
    defer dec2.deinit();
    try std.testing.expectEqualStrings(initial_cfg, dec2.config_bytes);
}

test "two encryptions of same passphrase produce different ciphertexts" {
    const allocator = std.testing.allocator;
    var a = try createEncrypted(allocator, std.testing.io, .{
        .passphrase = "correct horse battery staple",
    });
    defer a.deinit();
    var b = try createEncrypted(allocator, std.testing.io, .{
        .passphrase = "correct horse battery staple",
    });
    defer b.deinit();
    try std.testing.expect(!std.mem.eql(u8, a.bytes, b.bytes));
}
