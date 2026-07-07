const std = @import("std");
const CoraError = @import("../error.zig").CoraError;
const SecretBuf = @import("../crypto/secret_buf.zig").SecretBuf;

/// One stored secret: the value buffer plus optional lifetime metadata.
/// `expires_ms` of 0 means "never expires" (the default and the shape of
/// every secret written before TTLs existed). `created_ms` of 0 means
/// "unknown" for the same backward-compatibility reason.
pub const Entry = struct {
    secret: SecretBuf = .{},
    expires_ms: i64 = 0,
    created_ms: i64 = 0,

    pub fn isExpired(self: *const Entry, now_ms: i64) bool {
        return self.expires_ms != 0 and now_ms >= self.expires_ms;
    }
};

pub const MemStore = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(*Entry) = .{},

    pub fn init(allocator: std.mem.Allocator) MemStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MemStore) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.secret.zero();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.map.deinit(self.allocator);
    }

    pub fn put(self: *MemStore, name: []const u8, value: []const u8) !void {
        try self.putWithMeta(name, value, 0, 0);
    }

    /// Insert or overwrite a secret with lifetime metadata. Overwriting an
    /// existing name zeroes the old value first and replaces its metadata.
    pub fn putWithMeta(self: *MemStore, name: []const u8, value: []const u8, expires_ms: i64, created_ms: i64) !void {
        const gop = try self.map.getOrPut(self.allocator, name);
        if (gop.found_existing) {
            gop.value_ptr.*.secret.zero();
            try gop.value_ptr.*.secret.set(value);
            gop.value_ptr.*.expires_ms = expires_ms;
            gop.value_ptr.*.created_ms = created_ms;
            return;
        }
        const key_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key_copy);
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        entry.* = Entry{};
        try entry.secret.set(value);
        entry.expires_ms = expires_ms;
        entry.created_ms = created_ms;
        gop.key_ptr.* = key_copy;
        gop.value_ptr.* = entry;
    }

    pub fn copyInto(self: *MemStore, name: []const u8, out: *SecretBuf) CoraError!void {
        const entry = self.map.get(name) orelse return CoraError.SecretNotFound;
        try out.set(entry.secret.constSlice());
    }

    /// Return the full entry (value + metadata) for `name`, or null. The
    /// service uses this to gate injection on expiry: an expired secret must
    /// be treated as missing so it never reaches a child process.
    pub fn getEntry(self: *const MemStore, name: []const u8) ?*const Entry {
        return self.map.get(name);
    }

    pub fn delete(self: *MemStore, name: []const u8) bool {
        const kv = self.map.fetchRemove(name) orelse return false;
        kv.value.secret.zero();
        self.allocator.destroy(kv.value);
        self.allocator.free(kv.key);
        return true;
    }

    pub fn count(self: *const MemStore) usize {
        return self.map.count();
    }

    pub fn names(self: *const MemStore, allocator: std.mem.Allocator) ![][]const u8 {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer list.deinit(allocator);
        var it = self.map.keyIterator();
        while (it.next()) |k| try list.append(allocator, k.*);
        return list.toOwnedSlice(allocator);
    }
};

test "MemStore put + copyInto roundtrip" {
    var store = MemStore.init(std.testing.allocator);
    defer store.deinit();

    try store.put("GITHUB_TOKEN", "ghp_xxx");
    var out = SecretBuf{};
    defer out.zero();
    try store.copyInto("GITHUB_TOKEN", &out);
    try std.testing.expectEqualStrings("ghp_xxx", out.constSlice());
}

test "MemStore overwrite existing key zeroes old value" {
    var store = MemStore.init(std.testing.allocator);
    defer store.deinit();
    try store.put("K", "first");
    try store.put("K", "second");
    var out = SecretBuf{};
    defer out.zero();
    try store.copyInto("K", &out);
    try std.testing.expectEqualStrings("second", out.constSlice());
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "MemStore delete removes entry" {
    var store = MemStore.init(std.testing.allocator);
    defer store.deinit();
    try store.put("K", "v");
    try std.testing.expect(store.delete("K"));
    try std.testing.expect(!store.delete("K"));
    var out = SecretBuf{};
    defer out.zero();
    try std.testing.expectError(error.SecretNotFound, store.copyInto("K", &out));
}

test "MemStore names returns all keys" {
    var store = MemStore.init(std.testing.allocator);
    defer store.deinit();
    try store.put("A", "1");
    try store.put("B", "2");
    const ns = try store.names(std.testing.allocator);
    defer std.testing.allocator.free(ns);
    try std.testing.expectEqual(@as(usize, 2), ns.len);
}

test "MemStore put has no expiry by default" {
    var store = MemStore.init(std.testing.allocator);
    defer store.deinit();
    try store.put("K", "v");
    const e = store.getEntry("K").?;
    try std.testing.expectEqual(@as(i64, 0), e.expires_ms);
    try std.testing.expect(!e.isExpired(9_999_999_999));
}

test "MemStore putWithMeta records expiry and isExpired honors now" {
    var store = MemStore.init(std.testing.allocator);
    defer store.deinit();
    try store.putWithMeta("K", "v", 1000, 500);
    const e = store.getEntry("K").?;
    try std.testing.expectEqual(@as(i64, 1000), e.expires_ms);
    try std.testing.expectEqual(@as(i64, 500), e.created_ms);
    try std.testing.expect(!e.isExpired(999));
    try std.testing.expect(e.isExpired(1000));
    try std.testing.expect(e.isExpired(2000));
}
