const std = @import("std");
const json = std.json;
const CoraError = @import("../error.zig").CoraError;
const MemStore = @import("mem.zig").MemStore;
const max_secret_len = @import("../crypto/secret_buf.zig").max_secret_len;

pub const max_key_len: usize = 128;

pub fn decode(allocator: std.mem.Allocator, source: []const u8, out: *MemStore) !void {
    var scanner = json.Scanner.initCompleteInput(allocator, source);
    defer scanner.deinit();

    const first = try scanner.next();
    if (first != .object_begin) return CoraError.InvalidConfig;

    while (true) {
        // Audit-2026-06: Translate the JSON scanner's raw ValueTooLong into
        // CoraError.InvalidConfig at the codec boundary. The input-boundary
        // check in cmdSecretsSet / cmdSecretsDelete prevents new corruption,
        // but any future caller that hands us data from a source other than
        // argv (e.g. importing a vault from another tool) would otherwise
        // see an unhandled std-lib error. `scanner.nextAllocMax` already
        // caps allocation at max_key_len, so the post-decode length check
        // below is defensive only — kept because it costs nothing and
        // documents the invariant.
        const tok = scanner.nextAllocMax(allocator, .alloc_always, max_key_len) catch |err| switch (err) {
            error.ValueTooLong => return CoraError.InvalidConfig,
            else => return err,
        };
        switch (tok) {
            .object_end => return,
            .allocated_string => |key| {
                defer allocator.free(key);
                if (key.len > max_key_len) return CoraError.InvalidConfig;

                const vtok = try scanner.nextAllocMax(allocator, .alloc_always, max_secret_len);
                switch (vtok) {
                    .allocated_string => |value| {
                        defer {
                            std.crypto.secureZero(u8, value);
                            allocator.free(value);
                        }
                        try out.put(key, value);
                    },
                    else => return CoraError.InvalidConfig,
                }
            },
            else => return CoraError.InvalidConfig,
        }
    }
}

pub const Encoded = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Encoded) void {
        std.crypto.secureZero(u8, self.bytes);
        self.allocator.free(self.bytes);
    }
};

pub fn encode(allocator: std.mem.Allocator, store_: *const MemStore) !Encoded {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    var stringify: json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try stringify.beginObject();

    var it = store_.map.iterator();
    while (it.next()) |entry| {
        try stringify.objectField(entry.key_ptr.*);
        try stringify.write(entry.value_ptr.*.constSlice());
    }

    try stringify.endObject();

    const bytes = try aw.toOwnedSlice();
    return .{ .bytes = bytes, .allocator = allocator };
}

test "decode empty object" {
    var store_ = MemStore.init(std.testing.allocator);
    defer store_.deinit();
    try decode(std.testing.allocator, "{}", &store_);
    try std.testing.expectEqual(@as(usize, 0), store_.count());
}

test "decode populated object" {
    var store_ = MemStore.init(std.testing.allocator);
    defer store_.deinit();
    try decode(std.testing.allocator, "{\"GITHUB_TOKEN\":\"ghp_xxx\",\"STRIPE_KEY\":\"sk_yyy\"}", &store_);
    try std.testing.expectEqual(@as(usize, 2), store_.count());

    var out = @import("../crypto/secret_buf.zig").SecretBuf{};
    defer out.zero();
    try store_.copyInto("GITHUB_TOKEN", &out);
    try std.testing.expectEqualStrings("ghp_xxx", out.constSlice());
    out.zero();
    try store_.copyInto("STRIPE_KEY", &out);
    try std.testing.expectEqualStrings("sk_yyy", out.constSlice());
}

test "decode rejects non-object" {
    var store_ = MemStore.init(std.testing.allocator);
    defer store_.deinit();
    try std.testing.expectError(error.InvalidConfig, decode(std.testing.allocator, "[1,2,3]", &store_));
}

test "decode rejects nested object value" {
    var store_ = MemStore.init(std.testing.allocator);
    defer store_.deinit();
    try std.testing.expectError(error.InvalidConfig, decode(std.testing.allocator, "{\"K\":{\"x\":1}}", &store_));
}

test "encode empty store" {
    var store_ = MemStore.init(std.testing.allocator);
    defer store_.deinit();
    var enc = try encode(std.testing.allocator, &store_);
    defer enc.deinit();
    try std.testing.expectEqualStrings("{}", enc.bytes);
}

test "encode/decode roundtrip" {
    var src = MemStore.init(std.testing.allocator);
    defer src.deinit();
    try src.put("A", "alpha");
    try src.put("B", "beta\"quote\\back");

    var enc = try encode(std.testing.allocator, &src);
    defer enc.deinit();

    var dst = MemStore.init(std.testing.allocator);
    defer dst.deinit();
    try decode(std.testing.allocator, enc.bytes, &dst);

    var out = @import("../crypto/secret_buf.zig").SecretBuf{};
    defer out.zero();
    try dst.copyInto("A", &out);
    try std.testing.expectEqualStrings("alpha", out.constSlice());
    out.zero();
    try dst.copyInto("B", &out);
    try std.testing.expectEqualStrings("beta\"quote\\back", out.constSlice());
}
