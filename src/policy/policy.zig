const std = @import("std");
const CoraError = @import("../error.zig").CoraError;

pub const default_idle_timeout_ms: i64 = 15 * 60 * 1000;

pub const Task = struct {
    name: []const u8,
    allowed_secrets: []const []const u8 = &.{},
    /// Whitelist of absolute paths that may be the spawn target (argv[0])
    /// for this task. Empty list = dev-mode allow-all (preserves backward
    /// compatibility with tasks defined before this field existed).
    ///
    /// Without this gate a trusted caller can still leak a secret value by
    /// asking the service to spawn `/bin/echo $TOKEN` or
    /// `/bin/cat /proc/self/environ` — the secret reaches the child env,
    /// the child happily prints it to the caller-attached stdout. The
    /// caller policy alone does not stop this because the caller is
    /// supposed to be trusted; the missing layer is "what is the trusted
    /// caller allowed to run."
    allowed_targets: []const []const u8 = &.{},
};

/// Separator embedded in an `allowed_callers` entry to pin the caller to a
/// specific binary image: `"/usr/local/bin/cr@sha256=<64 hex>"`. Entries
/// without the separator are path-only (unpinned) and preserve backward
/// compatibility with configs written before hash pinning existed.
pub const hash_sep = "@sha256=";

pub const Caller = struct {
    path: []const u8,
    /// Lowercase-hex SHA-256 the caller binary must hash to, or null when the
    /// entry is path-only. Borrowed from the source entry.
    expected_hex: ?[]const u8,
};

/// Split an `allowed_callers` entry into its path and optional pinned hash.
/// The path is everything before the first `@sha256=`; the hash is the
/// remainder. A path-only entry returns `expected_hex = null`.
pub fn parseCaller(entry: []const u8) Caller {
    if (std.mem.indexOf(u8, entry, hash_sep)) |idx| {
        return .{
            .path = entry[0..idx],
            .expected_hex = entry[idx + hash_sep.len ..],
        };
    }
    return .{ .path = entry, .expected_hex = null };
}

pub const Policy = struct {
    allowed_callers: []const []const u8 = &.{},
    idle_timeout_ms: i64 = default_idle_timeout_ms,
    tasks: []const Task = &.{},

    pub fn isCallerAllowed(self: *const Policy, path: []const u8) bool {
        if (self.allowed_callers.len == 0) return true;
        for (self.allowed_callers) |a| {
            if (std.mem.eql(u8, parseCaller(a).path, path)) return true;
        }
        return false;
    }

    /// Return the pinned hash requirement for the caller at `path`, or null
    /// when the matching entry is path-only (or nothing matches). The service
    /// uses this to decide whether to hash the caller's binary and fail
    /// closed on mismatch.
    pub fn callerExpectedHash(self: *const Policy, path: []const u8) ?[]const u8 {
        for (self.allowed_callers) |a| {
            const c = parseCaller(a);
            if (std.mem.eql(u8, c.path, path)) return c.expected_hex;
        }
        return null;
    }

    pub fn findTask(self: *const Policy, name: []const u8) ?*const Task {
        for (self.tasks) |*t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }
};

/// Return true if `target_path` (an absolute resolved binary path) is
/// allowed as the spawn target for `task`. Empty `allowed_targets` =
/// dev-mode allow-all so pre-existing tasks defined without the field
/// keep working.
pub fn isTargetAllowedForTask(task: *const Task, target_path: []const u8) bool {
    if (task.allowed_targets.len == 0) return true;
    for (task.allowed_targets) |t| {
        if (std.mem.eql(u8, t, target_path)) return true;
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

test "task lookup" {
    // Audit-2026-06: dropped the isSecretAllowedForTask lines from this
    // test now that the helper itself has been removed. The remaining
    // assertion verifies the task lookup path that the service actually
    // uses (service.zig handleSpawn calls findTask to resolve the
    // declared task name).
    const t = Task{ .name = "gh", .allowed_secrets = &.{ "GH_TOKEN", "GH_PAT" } };
    const pol = Policy{ .tasks = &.{t} };
    const found = pol.findTask("gh").?;
    try std.testing.expectEqualStrings("gh", found.name);
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

test "parseCaller splits path and pinned hash" {
    const c = parseCaller("/usr/local/bin/cr@sha256=abc123");
    try std.testing.expectEqualStrings("/usr/local/bin/cr", c.path);
    try std.testing.expect(c.expected_hex != null);
    try std.testing.expectEqualStrings("abc123", c.expected_hex.?);
}

test "parseCaller plain path has no hash" {
    const c = parseCaller("/bin/agent");
    try std.testing.expectEqualStrings("/bin/agent", c.path);
    try std.testing.expect(c.expected_hex == null);
}

test "isCallerAllowed matches on path portion of pinned entry" {
    const p = Policy{ .allowed_callers = &.{"/usr/local/bin/cr@sha256=deadbeef"} };
    try std.testing.expect(p.isCallerAllowed("/usr/local/bin/cr"));
    try std.testing.expect(!p.isCallerAllowed("/usr/local/bin/cr@sha256=deadbeef"));
    try std.testing.expect(!p.isCallerAllowed("/bin/evil"));
}

test "callerExpectedHash returns pin only for pinned entries" {
    const p = Policy{ .allowed_callers = &.{ "/bin/plain", "/bin/pinned@sha256=cafe" } };
    try std.testing.expect(p.callerExpectedHash("/bin/plain") == null);
    try std.testing.expectEqualStrings("cafe", p.callerExpectedHash("/bin/pinned").?);
    try std.testing.expect(p.callerExpectedHash("/bin/absent") == null);
}

test "isTargetAllowedForTask: empty list is dev-mode allow-all" {
    const t = Task{ .name = "x", .allowed_secrets = &.{}, .allowed_targets = &.{} };
    try std.testing.expect(isTargetAllowedForTask(&t, "/anything"));
    try std.testing.expect(isTargetAllowedForTask(&t, "/usr/bin/gh"));
}

test "isTargetAllowedForTask: non-empty whitelist enforces exact match" {
    const t = Task{
        .name = "github",
        .allowed_secrets = &.{"GH_TOKEN"},
        .allowed_targets = &.{ "/usr/bin/gh", "/usr/bin/git" },
    };
    try std.testing.expect(isTargetAllowedForTask(&t, "/usr/bin/gh"));
    try std.testing.expect(isTargetAllowedForTask(&t, "/usr/bin/git"));
    try std.testing.expect(!isTargetAllowedForTask(&t, "/bin/echo"));
    try std.testing.expect(!isTargetAllowedForTask(&t, "/bin/cat"));
    // No prefix match — must be exact path.
    try std.testing.expect(!isTargetAllowedForTask(&t, "/usr/bin/gh-extension"));
}

test "serialize/parse roundtrip preserves allowed_targets" {
    const allocator = std.testing.allocator;
    const original = Policy{
        .tasks = &.{
            .{
                .name = "github",
                .allowed_secrets = &.{"GH_TOKEN"},
                .allowed_targets = &.{ "/usr/bin/gh", "/usr/bin/git" },
            },
        },
    };
    const text = try serialize(allocator, original);
    defer allocator.free(text);

    var back = try parse(allocator, text);
    defer free(allocator, &back);
    try std.testing.expectEqual(@as(usize, 1), back.tasks.len);
    try std.testing.expectEqual(@as(usize, 2), back.tasks[0].allowed_targets.len);
    try std.testing.expectEqualStrings("/usr/bin/gh", back.tasks[0].allowed_targets[0]);
    try std.testing.expectEqualStrings("/usr/bin/git", back.tasks[0].allowed_targets[1]);
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
