const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = Io.net;
const MemStore = @import("../store/mem.zig").MemStore;
const SecretBuf = @import("../crypto/secret_buf.zig").SecretBuf;
const idle_mod = @import("idle.zig");
const proto = @import("proto.zig");
const identity = @import("../identity/identity.zig");
const policy_mod = @import("../policy/policy.zig");
const audit = @import("../audit.zig");
const CoraError = @import("../error.zig").CoraError;

extern "kernel32" fn GetProcessId(Process: *anyopaque) callconv(.winapi) u32;

fn childPid(child: anytype) i32 {
    if (child.id) |id| {
        if (builtin.os.tag == .windows) return @intCast(GetProcessId(@ptrCast(id)));
        return @intCast(id);
    }
    return 0;
}

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toMilliseconds();
}

pub const default_socket_format = "/tmp/cora-{d}.sock";

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: ?[*]u16, nSize: u32) callconv(.winapi) u32;
extern "kernel32" fn CreateDirectoryW(lpPathName: [*:0]const u16, lpSecurityAttributes: ?*anyopaque) callconv(.winapi) i32;

/// Resolve the AF_UNIX socket path used by `cr unlock` and clients.
/// POSIX: `/tmp/cora-<uid>.sock`.
/// Windows: `%LOCALAPPDATA%\cora\cora.sock`. AF_UNIX is supported on
/// Windows 10 1803+. Peer PID is not exposed on Windows AF_UNIX sockets,
/// so Tier 1 trusts the user-only NTFS ACL inherited from %LOCALAPPDATA%.
pub fn defaultSocketPath(buf: []u8) ![]u8 {
    if (builtin.os.tag == .windows) {
        const name = std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA");
        var wide: [260]u16 = undefined;
        const n = GetEnvironmentVariableW(name, &wide, wide.len);
        if (n == 0 or n >= wide.len) return error.NoLocalAppData;
        var tmp: [520]u8 = undefined;
        const m = try std.unicode.utf16LeToUtf8(&tmp, wide[0..n]);
        return std.fmt.bufPrint(buf, "{s}\\cora\\cora.sock", .{tmp[0..m]});
    }
    const uid: u64 = @intCast(std.c.getuid());
    return std.fmt.bufPrint(buf, default_socket_format, .{uid});
}

/// Validate that `socket_path` is a child of `<local_app_data>\cora\`. Split
/// out as a pure helper so it can be exercised without touching the live
/// %LOCALAPPDATA% env on test runners.
fn checkSocketUnderBase(local_app_data: []const u8, socket_path: []const u8) !void {
    var expected_buf: [600]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{s}\\cora\\", .{local_app_data});
    if (socket_path.len <= expected.len) return error.UnexpectedSocketLocation;
    if (!std.ascii.eqlIgnoreCase(socket_path[0..expected.len], expected)) {
        return error.UnexpectedSocketLocation;
    }
}

/// Verify on Windows that the AF_UNIX socket path resolves under
/// `%LOCALAPPDATA%\cora`. The Tier 1 trust model relies on the user-only
/// NTFS ACL inherited from %LOCALAPPDATA%; if the path is elsewhere (env
/// hijack, explicit override into a world-writable directory, etc.) the
/// assumption is broken and the service must refuse to start. No-op on
/// POSIX where socket permissions are enforced via chmod 0600 instead.
fn verifyWindowsSocketParent(socket_path: []const u8) !void {
    if (builtin.os.tag != .windows) return;
    const name = std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA");
    var wide: [260]u16 = undefined;
    const n = GetEnvironmentVariableW(name, &wide, wide.len);
    if (n == 0 or n >= wide.len) return error.NoLocalAppData;
    var base_buf: [520]u8 = undefined;
    const base_len = try std.unicode.utf16LeToUtf8(&base_buf, wide[0..n]);
    return checkSocketUnderBase(base_buf[0..base_len], socket_path);
}

/// Ensure the parent directory of `socket_path` exists on Windows.
/// AF_UNIX bind fails if `%LOCALAPPDATA%\cora` is missing. No-op on POSIX
/// (we use /tmp which always exists).
fn ensureParentDir(path: []const u8) void {
    if (builtin.os.tag != .windows) return;
    const sep = std.mem.lastIndexOfScalar(u8, path, '\\') orelse return;
    const dir = path[0..sep];
    var wide_buf: [520]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide_buf, dir) catch return;
    if (n >= wide_buf.len) return;
    wide_buf[n] = 0;
    _ = CreateDirectoryW(@ptrCast(&wide_buf), null);
}

pub const Config = struct {
    socket_path: []const u8,
    idle_timeout_ms: i64 = 15 * 60 * 1000,
    policy: policy_mod.Policy = .{},
    audit_logger: ?*audit.Logger = null,
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    io: Io,
    secrets: *MemStore,
    timer: idle_mod.IdleTimer,
    server: net.Server,
    socket_path: []const u8,
    shutdown: std.atomic.Value(bool),
    policy: policy_mod.Policy,
    rejected: std.atomic.Value(u32),
    audit_logger: ?*audit.Logger,

    pub fn start(allocator: std.mem.Allocator, io: Io, cfg: Config, secrets: *MemStore) !Service {
        try verifyWindowsSocketParent(cfg.socket_path);
        ensureParentDir(cfg.socket_path);
        removeSocketIfStale(io, cfg.socket_path);
        const ua = try net.UnixAddress.init(cfg.socket_path);
        const server = try ua.listen(io, .{});
        try restrictSocketPermissions(cfg.socket_path);
        var svc: Service = .{
            .allocator = allocator,
            .io = io,
            .secrets = secrets,
            .timer = idle_mod.IdleTimer.init(io, cfg.idle_timeout_ms),
            .server = server,
            .socket_path = cfg.socket_path,
            .shutdown = .init(false),
            .policy = cfg.policy,
            .rejected = .init(0),
            .audit_logger = cfg.audit_logger,
        };
        svc.emit(.{ .service_unlocked = .{ .ts_ms = nowMs(svc.io) } });
        return svc;
    }

    fn emit(self: *Service, ev: audit.Event) void {
        if (self.audit_logger) |l| l.log(ev) catch |err| {
            std.log.warn("audit log error: {s}", .{@errorName(err)});
        };
    }

    pub fn run(self: *Service) !void {
        var idle_thread = try std.Thread.spawn(.{}, idleWatch, .{self});
        defer idle_thread.join();

        while (!self.shutdown.load(.acquire)) {
            const stream = self.server.accept(self.io) catch |err| switch (err) {
                error.SocketNotListening, error.Canceled => break,
                else => return err,
            };
            self.handle(stream) catch |err| {
                std.log.warn("handler error: {s}", .{@errorName(err)});
            };
            if (self.shutdown.load(.acquire)) break;
        }
    }

    pub fn deinit(self: *Service) void {
        self.emit(.{ .service_locked = .{ .ts_ms = nowMs(self.io), .reason = "exit" } });
        self.shutdown.store(true, .release);
        self.server.deinit(self.io);
        Io.Dir.cwd().deleteFile(self.io, self.socket_path) catch {};
        zeroAll(self.secrets);
    }

    fn handle(self: *Service, stream: net.Stream) !void {
        defer stream.close(self.io);

        const ident = identity.verify(stream.socket.handle) catch {
            _ = self.rejected.fetchAdd(1, .monotonic);
            self.emit(.{ .caller_rejected = .{
                .ts_ms = nowMs(self.io),
                .pid = 0,
                .binary = "unknown",
                .reason = "identity verification failed",
            } });
            return;
        };
        if (!self.policy.isCallerAllowed(ident.path())) {
            _ = self.rejected.fetchAdd(1, .monotonic);
            self.emit(.{ .caller_rejected = .{
                .ts_ms = nowMs(self.io),
                .pid = ident.pid,
                .binary = ident.path(),
                .reason = "binary not in allowed_callers",
            } });
            return;
        }

        var rbuf: [4096]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var reader = net.Stream.Reader.init(stream, self.io, &rbuf);
        var writer = net.Stream.Writer.init(stream, self.io, &wbuf);

        var task_name_buf: [128]u8 = undefined;
        var task_name_len: usize = 0;

        while (true) {
            var frame = proto.readFrame(&reader.interface, self.allocator) catch return;
            defer frame.deinit(self.allocator);

            self.timer.touch(self.io);
            const op: proto.Op = @enumFromInt(frame.op);

            switch (op) {
                .ping => {
                    try proto.writeFrame(&writer.interface, .ping, "");
                    try writer.interface.flush();
                },
                .status => {
                    var buf: [proto.StatusResp.wire_len]u8 = undefined;
                    const resp: proto.StatusResp = .{
                        .running = 1,
                        .secrets_count = @intCast(self.secrets.count()),
                        .idle_remaining_ms = self.timer.remainingMs(self.io),
                    };
                    resp.encode(&buf);
                    try proto.writeFrame(&writer.interface, .status, &buf);
                    try writer.interface.flush();
                },
                .lock => {
                    try proto.writeFrame(&writer.interface, .lock, "");
                    try writer.interface.flush();
                    self.shutdown.store(true, .release);
                    return;
                },
                .task_declare => {
                    if (frame.payload.len > task_name_buf.len) {
                        try proto.writeFrame(&writer.interface, .err, "task name too long");
                        try writer.interface.flush();
                        continue;
                    }
                    const task_name = frame.payload;
                    if (self.policy.findTask(task_name) == null) {
                        try proto.writeFrame(&writer.interface, .err, "unknown task");
                        try writer.interface.flush();
                        continue;
                    }
                    @memcpy(task_name_buf[0..task_name.len], task_name);
                    task_name_len = task_name.len;
                    self.emit(.{ .task_start = .{
                        .ts_ms = nowMs(self.io),
                        .caller_pid = ident.pid,
                        .caller_bin = ident.path(),
                        .task = task_name,
                    } });
                    try proto.writeFrame(&writer.interface, .task_declare, "");
                    try writer.interface.flush();
                },
                .spawn => {
                    if (task_name_len == 0) {
                        try proto.writeFrame(&writer.interface, .err, "no task declared");
                        try writer.interface.flush();
                        continue;
                    }
                    self.handleSpawn(&writer.interface, task_name_buf[0..task_name_len], frame.payload) catch |err| {
                        std.log.warn("spawn failed: {s}", .{@errorName(err)});
                        try proto.writeFrame(&writer.interface, .err, @errorName(err));
                        try writer.interface.flush();
                    };
                },
                else => {
                    try proto.writeFrame(&writer.interface, .err, "unknown op");
                    try writer.interface.flush();
                },
            }
        }
    }

    fn handleSpawn(self: *Service, writer: *Io.Writer, declared_task: []const u8, payload: []const u8) !void {
        var parsed = try proto.decodeSpawnPayload(self.allocator, payload);
        defer parsed.deinit();

        if (!std.mem.eql(u8, parsed.task_name, declared_task)) return CoraError.NoActiveTask;
        const task = self.policy.findTask(declared_task) orelse return CoraError.NoActiveTask;
        if (parsed.argv.len == 0) return CoraError.InvalidConfig;

        var env_map = std.process.Environ.Map.init(self.allocator);
        defer env_map.deinit();

        var bufs = std.ArrayList(SecretBuf).empty;
        defer {
            for (bufs.items) |*b| b.zero();
            bufs.deinit(self.allocator);
        }

        var injected_names = std.ArrayList([]const u8).empty;
        defer injected_names.deinit(self.allocator);
        var missing_names = std.ArrayList([]const u8).empty;
        defer missing_names.deinit(self.allocator);

        for (task.allowed_secrets) |name| {
            var b = SecretBuf{};
            self.secrets.copyInto(name, &b) catch {
                try missing_names.append(self.allocator, name);
                continue;
            };
            try bufs.append(self.allocator, b);
            try env_map.put(name, bufs.items[bufs.items.len - 1].constSlice());
            try injected_names.append(self.allocator, name);
        }

        const start_ms = nowMs(self.io);
        var child = try std.process.spawn(self.io, .{
            .argv = parsed.argv,
            .environ_map = &env_map,
        });
        const child_pid: i32 = childPid(child);

        for (injected_names.items) |name| {
            self.emit(.{ .secret_injected = .{
                .ts_ms = nowMs(self.io),
                .task = declared_task,
                .secret_name = name,
                .target_pid = child_pid,
            } });
        }
        for (missing_names.items) |name| {
            self.emit(.{ .secret_missing = .{
                .ts_ms = nowMs(self.io),
                .task = declared_task,
                .secret_name = name,
                .target_pid = child_pid,
            } });
        }

        const term = try child.wait(self.io);
        const code: i32 = switch (term) {
            .exited => |c| @intCast(c),
            .signal => |s| -@as(i32, @intCast(@intFromEnum(s))),
            .stopped, .unknown => -1,
        };

        self.emit(.{ .task_end = .{
            .ts_ms = nowMs(self.io),
            .task = declared_task,
            .exit_code = code,
            .duration_ms = nowMs(self.io) - start_ms,
        } });

        var buf: [proto.SpawnResp.wire_len]u8 = undefined;
        const resp: proto.SpawnResp = .{ .child_pid = child_pid, .exit_code = code };
        resp.encode(&buf);
        try proto.writeFrame(writer, .spawn, &buf);
        try writer.flush();
    }

    fn idleWatch(self: *Service) void {
        while (!self.shutdown.load(.acquire)) {
            self.io.sleep(.{ .nanoseconds = 250 * std.time.ns_per_ms }, .awake) catch return;
            if (self.timer.isExpired(self.io)) {
                self.shutdown.store(true, .release);
                self.server.socket.close(self.io);
                return;
            }
        }
    }
};

fn zeroAll(s: *MemStore) void {
    var it = s.map.iterator();
    while (it.next()) |entry| entry.value_ptr.*.zero();
}

fn removeSocketIfStale(io: Io, path: []const u8) void {
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// Force the bound AF_UNIX socket to mode 0600. Without this, the socket
/// file inherits the process umask (typically 022, leaving the socket
/// world-readable). On Windows AF_UNIX sockets, access is controlled by
/// the NTFS ACL of `%LOCALAPPDATA%\cora`, not POSIX modes.
fn restrictSocketPermissions(path: []const u8) !void {
    if (builtin.os.tag == .windows) return;
    const path_z = try std.posix.toPosixPath(path);
    if (std.c.chmod(&path_z, 0o600) != 0) return error.SocketChmodFailed;
}

test "checkSocketUnderBase accepts path inside cora subdir" {
    try checkSocketUnderBase(
        "C:\\Users\\u\\AppData\\Local",
        "C:\\Users\\u\\AppData\\Local\\cora\\cora.sock",
    );
}

test "checkSocketUnderBase rejects path outside cora subdir" {
    try std.testing.expectError(
        error.UnexpectedSocketLocation,
        checkSocketUnderBase(
            "C:\\Users\\u\\AppData\\Local",
            "C:\\Temp\\cora.sock",
        ),
    );
}

test "checkSocketUnderBase compares case-insensitively" {
    try checkSocketUnderBase(
        "C:\\users\\u\\appdata\\local",
        "C:\\Users\\u\\AppData\\Local\\CORA\\cora.sock",
    );
}

test "checkSocketUnderBase rejects bare base with no child" {
    try std.testing.expectError(
        error.UnexpectedSocketLocation,
        checkSocketUnderBase(
            "C:\\Users\\u\\AppData\\Local",
            "C:\\Users\\u\\AppData\\Local\\cora\\",
        ),
    );
}

test "defaultSocketPath builds path" {
    var buf: [520]u8 = undefined;
    const p = try defaultSocketPath(&buf);
    if (builtin.os.tag == .windows) {
        try std.testing.expect(std.mem.endsWith(u8, p, "\\cora\\cora.sock"));
    } else {
        try std.testing.expect(std.mem.startsWith(u8, p, "/tmp/cora-"));
        try std.testing.expect(std.mem.endsWith(u8, p, ".sock"));
    }
}

test "restrictSocketPermissions forces 0600" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buf,
        "/tmp/cora-test-chmod-{d}.tmp",
        .{std.c.getpid()},
    );
    const path_z = try std.posix.toPosixPath(path);

    // Create a regular file with a permissive baseline so a no-op chmod would
    // fail the assert below.
    const fd = std.c.open(
        &path_z,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        @as(std.c.mode_t, 0o666),
    );
    if (fd < 0) return error.OpenFailed;
    _ = std.c.close(fd);
    defer _ = std.c.unlink(&path_z);

    if (std.c.chmod(&path_z, 0o666) != 0) return error.SetupChmodFailed;

    try restrictSocketPermissions(path);

    // Verify via cross-platform Io.File.stat. std.c.fstat is `void` on Linux
    // (only macOS has the symbol via dispatch), so a libc fstat call would
    // fail to compile on linux runners.
    var file = try Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const st = try file.stat(io);
    try std.testing.expectEqual(
        @as(std.posix.mode_t, 0o600),
        st.permissions.toMode() & 0o777,
    );
}
