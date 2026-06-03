const std = @import("std");
const Io = std.Io;
const CoraError = @import("error.zig").CoraError;

pub const default_subdir = ".cora";
pub const default_filename = "audit.jsonl";

pub const Event = union(enum) {
    service_unlocked: struct { ts_ms: i64 },
    service_locked: struct { ts_ms: i64, reason: []const u8 },
    caller_rejected: struct { ts_ms: i64, pid: i32, binary: []const u8, reason: []const u8 },
    task_start: struct { ts_ms: i64, caller_pid: i32, caller_bin: []const u8, task: []const u8 },
    secret_injected: struct { ts_ms: i64, task: []const u8, secret_name: []const u8, target_pid: i32 },
    secret_missing: struct { ts_ms: i64, task: []const u8, secret_name: []const u8, target_pid: i32 },
    task_end: struct { ts_ms: i64, task: []const u8, exit_code: i32, duration_ms: i64 },
    /// Emitted when the spawn target (argv[0] after PATH resolution) is
    /// not in the task's `allowed_targets`. Distinct from `caller_rejected`
    /// — the caller passed kernel identity verification and the task
    /// exists; what failed is the second gate (which binary the caller
    /// asked us to spawn).
    target_rejected: struct {
        ts_ms: i64,
        caller_pid: i32,
        caller_bin: []const u8,
        task: []const u8,
        target: []const u8,
        reason: []const u8,
    },
};

pub const Logger = struct {
    allocator: std.mem.Allocator,
    io: Io,
    file: ?Io.File,
    path: []u8,
    enabled: bool,
    // Tracked append offset. Windows `createFile` does not grant
    // FILE_READ_ATTRIBUTES on the resulting handle, so calling `file.length()`
    // on the write handle fails with ACCESS_DENIED at every log event. We
    // seed the offset once from a separate read-only probe and advance it
    // ourselves per write, avoiding the stat round-trip entirely.
    offset: u64,

    pub fn init(allocator: std.mem.Allocator, io: Io, path: []const u8, enabled: bool) !Logger {
        var logger: Logger = .{
            .allocator = allocator,
            .io = io,
            .file = null,
            .path = try allocator.dupe(u8, path),
            .enabled = enabled,
            .offset = 0,
        };
        if (enabled) try logger.open();
        return logger;
    }

    pub fn deinit(self: *Logger) void {
        if (self.file) |f| f.close(self.io);
        self.allocator.free(self.path);
        self.* = undefined;
    }

    fn open(self: *Logger) !void {
        const cwd = Io.Dir.cwd();
        if (std.fs.path.dirname(self.path)) |dir| {
            cwd.createDirPath(self.io, dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        // Probe the existing size with a separate read handle so the
        // subsequent write handle does not need FILE_READ_ATTRIBUTES.
        // Missing file == fresh log == offset 0.
        const initial_size: u64 = blk: {
            var probe = cwd.openFile(self.io, self.path, .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk 0,
                else => return err,
            };
            defer probe.close(self.io);
            break :blk probe.length(self.io) catch 0;
        };

        const f = try cwd.createFile(self.io, self.path, .{ .exclusive = false, .truncate = false });
        if (@hasDecl(std.posix, "fchmod")) {
            std.posix.fchmod(f.handle, 0o600) catch {};
        }
        self.offset = initial_size;
        self.file = f;
    }

    pub fn log(self: *Logger, ev: Event) !void {
        if (!self.enabled) return;
        if (self.file == null) return;

        var buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer buf.deinit();
        try encode(ev, &buf.writer);
        try buf.writer.writeByte('\n');
        const bytes = buf.written();
        try self.file.?.writePositionalAll(self.io, bytes, self.offset);
        self.offset += bytes.len;
    }
};

pub fn encode(ev: Event, w: *Io.Writer) !void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{} };
    try s.beginObject();
    try s.objectField("kind");
    try s.write(@tagName(ev));
    switch (ev) {
        .service_unlocked => |v| {
            try s.objectField("ts_ms");
            try s.write(v.ts_ms);
        },
        .service_locked => |v| {
            try s.objectField("ts_ms");
            try s.write(v.ts_ms);
            try s.objectField("reason");
            try s.write(v.reason);
        },
        .caller_rejected => |v| {
            try s.objectField("ts_ms");
            try s.write(v.ts_ms);
            try s.objectField("pid");
            try s.write(v.pid);
            try s.objectField("binary");
            try s.write(v.binary);
            try s.objectField("reason");
            try s.write(v.reason);
        },
        .task_start => |v| {
            try s.objectField("ts_ms");
            try s.write(v.ts_ms);
            try s.objectField("caller_pid");
            try s.write(v.caller_pid);
            try s.objectField("caller_bin");
            try s.write(v.caller_bin);
            try s.objectField("task");
            try s.write(v.task);
        },
        .secret_injected => |v| {
            try s.objectField("ts_ms");
            try s.write(v.ts_ms);
            try s.objectField("task");
            try s.write(v.task);
            try s.objectField("secret_name");
            try s.write(v.secret_name);
            try s.objectField("target_pid");
            try s.write(v.target_pid);
        },
        .secret_missing => |v| {
            try s.objectField("ts_ms");
            try s.write(v.ts_ms);
            try s.objectField("task");
            try s.write(v.task);
            try s.objectField("secret_name");
            try s.write(v.secret_name);
            try s.objectField("target_pid");
            try s.write(v.target_pid);
        },
        .task_end => |v| {
            try s.objectField("ts_ms");
            try s.write(v.ts_ms);
            try s.objectField("task");
            try s.write(v.task);
            try s.objectField("exit_code");
            try s.write(v.exit_code);
            try s.objectField("duration_ms");
            try s.write(v.duration_ms);
        },
        .target_rejected => |v| {
            try s.objectField("ts_ms");
            try s.write(v.ts_ms);
            try s.objectField("caller_pid");
            try s.write(v.caller_pid);
            try s.objectField("caller_bin");
            try s.write(v.caller_bin);
            try s.objectField("task");
            try s.write(v.task);
            try s.objectField("target");
            try s.write(v.target);
            try s.objectField("reason");
            try s.write(v.reason);
        },
    }
    try s.endObject();
}

pub fn defaultPathAlloc(allocator: std.mem.Allocator) ![]u8 {
    const home_ptr = std.c.getenv("HOME") orelse return CoraError.InvalidConfig;
    const home = std.mem.span(home_ptr);
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ home, default_subdir, default_filename });
}

test "encode service_unlocked" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try encode(.{ .service_unlocked = .{ .ts_ms = 1000 } }, &aw.writer);
    try std.testing.expectEqualStrings("{\"kind\":\"service_unlocked\",\"ts_ms\":1000}", aw.written());
}

test "encode caller_rejected" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try encode(.{ .caller_rejected = .{
        .ts_ms = 9,
        .pid = 12345,
        .binary = "/bin/evil",
        .reason = "not allowed",
    } }, &aw.writer);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"caller_rejected\",\"ts_ms\":9,\"pid\":12345,\"binary\":\"/bin/evil\",\"reason\":\"not allowed\"}",
        aw.written(),
    );
}

test "encode secret_injected (no value field)" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try encode(.{ .secret_injected = .{
        .ts_ms = 1,
        .task = "github",
        .secret_name = "GH_TOKEN",
        .target_pid = 99,
    } }, &aw.writer);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"secret_name\":\"GH_TOKEN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "value") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "secret_value") == null);
}

test "Event union no longer carries windows_preview_mode variant" {
    // After Tier 2 (Named Pipes + GetNamedPipeClientProcessId), the
    // Windows trust model matches POSIX. The preview audit event was
    // removed in the same change; this test catches re-introductions
    // at compile time.
    try std.testing.expect(!@hasField(Event, "windows_preview_mode"));
}

test "encode secret_missing distinct from secret_injected" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try encode(.{ .secret_missing = .{
        .ts_ms = 7,
        .task = "demo",
        .secret_name = "MISSING_KEY",
        .target_pid = 42,
    } }, &aw.writer);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"secret_missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"secret_name\":\"MISSING_KEY\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "secret_injected") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "value") == null);
}

test "encode target_rejected" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try encode(.{ .target_rejected = .{
        .ts_ms = 17,
        .caller_pid = 4321,
        .caller_bin = "/usr/local/bin/cr",
        .task = "github",
        .target = "/bin/echo",
        .reason = "target not in allowed_targets",
    } }, &aw.writer);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"target_rejected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"task\":\"github\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"target\":\"/bin/echo\"") != null);
    // No secret value or env contents in the audit record.
    try std.testing.expect(std.mem.indexOf(u8, out, "value") == null);
}

test "Logger writes to tmp file then reads back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var name_buf: [256]u8 = undefined;
    const sub_path = try std.fmt.bufPrint(&name_buf, "{s}/audit.jsonl", .{tmp.sub_path});
    const cache_dir = Io.Dir.cwd().createDirPathOpen(std.testing.io, ".zig-cache/tmp", .{}) catch unreachable;
    var full_buf: [512]u8 = undefined;
    _ = cache_dir;
    const path = try std.fmt.bufPrint(&full_buf, ".zig-cache/tmp/{s}", .{sub_path});

    var logger = try Logger.init(std.testing.allocator, std.testing.io, path, true);
    defer logger.deinit();
    try logger.log(.{ .service_unlocked = .{ .ts_ms = 42 } });
    try logger.log(.{ .service_locked = .{ .ts_ms = 43, .reason = "test" } });

    const contents = try Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(8192));
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"ts_ms\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"reason\":\"test\"") != null);
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| if (line.len > 0) {
        lines += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), lines);
}
