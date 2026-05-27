const std = @import("std");
const CoraError = @import("../error.zig").CoraError;

pub const default_idle_timeout_ms: i64 = 15 * 60 * 1000;

pub const Task = struct {
    name: []const u8,
    allowed_secrets: []const []const u8 = &.{},
};

pub const Policy = struct {
    allowed_callers: []const []const u8 = &.{},
    idle_timeout_ms: i64 = default_idle_timeout_ms,
    tasks: []const Task = &.{},

    pub fn isCallerAllowed(self: *const Policy, path: []const u8) bool {
        if (self.allowed_callers.len == 0) return true;
        for (self.allowed_callers) |a| {
            if (std.mem.eql(u8, a, path)) return true;
        }
        return false;
    }

    pub fn findTask(self: *const Policy, name: []const u8) ?*const Task {
        for (self.tasks) |*t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }
};

pub fn isSecretAllowedForTask(task: *const Task, secret: []const u8) bool {
    for (task.allowed_secrets) |s| {
        if (std.mem.eql(u8, s, secret)) return true;
    }
    return false;
}

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Policy {
    if (source.len == 0) return .{};
    const z = try allocator.allocSentinel(u8, source.len, 0);
    defer allocator.free(z);
    @memcpy(z, source);
    return std.zon.parse.fromSliceAlloc(Policy, allocator, z, null, .{ .ignore_unknown_fields = true }) catch return CoraError.InvalidConfig;
}

pub fn free(allocator: std.mem.Allocator, p: *Policy) void {
    std.zon.parse.free(allocator, p.*);
    p.* = .{};
}

pub fn serialize(allocator: std.mem.Allocator, p: Policy) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try std.zon.stringify.serialize(p, .{}, &aw.writer);
    return aw.toOwnedSlice();
}

test "empty source returns default" {
    var p = try parse(std.testing.allocator, "");
    defer free(std.testing.allocator, &p);
    try std.testing.expectEqual(default_idle_timeout_ms, p.idle_timeout_ms);
    try std.testing.expectEqual(@as(usize, 0), p.allowed_callers.len);
}

test "parse populated policy" {
    const src =
        \\.{
        \\    .allowed_callers = .{ "/usr/local/bin/openclaw", "/opt/bin/agent" },
        \\    .idle_timeout_ms = 60000,
        \\}
    ;
    var p = try parse(std.testing.allocator, src);
    defer free(std.testing.allocator, &p);
    try std.testing.expectEqual(@as(i64, 60000), p.idle_timeout_ms);
    try std.testing.expectEqual(@as(usize, 2), p.allowed_callers.len);
    try std.testing.expectEqualStrings("/usr/local/bin/openclaw", p.allowed_callers[0]);
    try std.testing.expect(p.isCallerAllowed("/opt/bin/agent"));
    try std.testing.expect(!p.isCallerAllowed("/nope"));
}

test "empty allowed_callers means allow-all (dev mode)" {
    var p = Policy{};
    try std.testing.expect(p.isCallerAllowed("/anything"));
}

test "task lookup + secret check" {
    const t = Task{ .name = "gh", .allowed_secrets = &.{ "GH_TOKEN", "GH_PAT" } };
    const pol = Policy{ .tasks = &.{t} };
    const found = pol.findTask("gh").?;
    try std.testing.expectEqualStrings("gh", found.name);
    try std.testing.expect(isSecretAllowedForTask(found, "GH_TOKEN"));
    try std.testing.expect(!isSecretAllowedForTask(found, "AWS_KEY"));
    try std.testing.expect(pol.findTask("missing") == null);
}

test "allow/deny mutation preserves tasks" {
    // Mirrors cmdPolicy allow/deny in main.zig: build a new Policy struct
    // changing only allowed_callers, then serialize+reparse. Tasks must survive.
    const allocator = std.testing.allocator;
    const original = Policy{
        .allowed_callers = &.{"/usr/local/bin/cr"},
        .idle_timeout_ms = 900000,
        .tasks = &.{
            .{ .name = "demo", .allowed_secrets = &.{"API_KEY"} },
        },
    };

    const new_pol = Policy{
        .allowed_callers = &.{ "/usr/local/bin/cr", "/bin/echo" },
        .idle_timeout_ms = original.idle_timeout_ms,
        .tasks = original.tasks,
    };
    const text = try serialize(allocator, new_pol);
    defer allocator.free(text);

    var back = try parse(allocator, text);
    defer free(allocator, &back);
    try std.testing.expectEqual(@as(usize, 1), back.tasks.len);
    try std.testing.expectEqualStrings("demo", back.tasks[0].name);
    try std.testing.expectEqual(@as(usize, 1), back.tasks[0].allowed_secrets.len);
    try std.testing.expectEqualStrings("API_KEY", back.tasks[0].allowed_secrets[0]);
    try std.testing.expectEqual(@as(usize, 2), back.allowed_callers.len);
}

test "serialize/parse roundtrip" {
    const original = Policy{
        .allowed_callers = &.{ "/a", "/b/c" },
        .idle_timeout_ms = 12345,
    };
    const text = try serialize(std.testing.allocator, original);
    defer std.testing.allocator.free(text);

    var back = try parse(std.testing.allocator, text);
    defer free(std.testing.allocator, &back);
    try std.testing.expectEqual(original.idle_timeout_ms, back.idle_timeout_ms);
    try std.testing.expectEqual(original.allowed_callers.len, back.allowed_callers.len);
    try std.testing.expectEqualStrings(original.allowed_callers[0], back.allowed_callers[0]);
}
