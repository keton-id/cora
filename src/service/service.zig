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
const pipe_windows = @import("pipe_windows.zig");
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

/// Resolve the per-user IPC endpoint string used by `cr unlock` and clients.
///
/// POSIX: AF_UNIX socket path `/tmp/cora-<uid>.sock`.
/// Windows (Tier 2): Named Pipe name `\\.\pipe\cora-<username>`.
///
/// Returns the path bytes inside `buf`. Tier-2 Windows uses Named Pipes
/// (`pipe_windows.zig`) so the kernel can report the connected client's
/// PID via `GetNamedPipeClientProcessId`. The string is opaque to
/// callers — `service.start` and `client.connect` interpret it
/// per-platform.
pub fn defaultSocketPath(buf: []u8) ![]u8 {
    if (builtin.os.tag == .windows) {
        return pipe_windows.defaultPipeNameUtf8(buf);
    }
    const uid: u64 = @intCast(std.c.getuid());
    return std.fmt.bufPrint(buf, default_socket_format, .{uid});
}

pub const Config = struct {
    socket_path: []const u8,
    idle_timeout_ms: i64 = 15 * 60 * 1000,
    policy: policy_mod.Policy = .{},
    audit_logger: ?*audit.Logger = null,
};

/// Per-platform server holder. On POSIX wraps `net.Server`; on Windows
/// holds the persistent Named Pipe HANDLE plus the wide pipe name used
/// to re-create instances between client connections.
const Server = if (builtin.os.tag == .windows) struct {
    pipe: pipe_windows.HANDLE,
    name_wide: [pipe_windows.PipeNameMaxWide]u16,

    fn start(io: Io, socket_path: []const u8) !Server {
        _ = io;
        _ = socket_path;
        var s: Server = .{ .pipe = pipe_windows.INVALID_HANDLE_VALUE, .name_wide = undefined };
        const name_z = try pipe_windows.defaultPipeNameWide(&s.name_wide);
        s.pipe = try pipe_windows.createServerPipe(name_z.ptr);
        return s;
    }

    fn deinit(self: *Server, io: Io) void {
        _ = io;
        if (@intFromPtr(self.pipe) != @intFromPtr(pipe_windows.INVALID_HANDLE_VALUE)) {
            pipe_windows.closeHandle(self.pipe);
            self.pipe = pipe_windows.INVALID_HANDLE_VALUE;
        }
    }

    fn cancel(self: *Server, io: Io) void {
        // Closing the pipe handle from the idle watcher thread cancels a
        // pending `ConnectNamedPipe` in the accept loop, mirroring the
        // POSIX `server.socket.close` cancellation path.
        self.deinit(io);
    }
} else struct {
    inner: net.Server,

    fn start(io: Io, socket_path: []const u8) !Server {
        Io.Dir.cwd().deleteFile(io, socket_path) catch {};
        const ua = try net.UnixAddress.init(socket_path);
        const inner = try ua.listen(io, .{});
        try restrictSocketPermissions(socket_path);
        return .{ .inner = inner };
    }

    fn deinit(self: *Server, io: Io) void {
        self.inner.deinit(io);
    }

    fn cancel(self: *Server, io: Io) void {
        self.inner.socket.close(io);
    }
};

/// Per-platform transport for a single accepted connection. Both
/// platforms expose `handle()` (for `identity.verify`), `close(io)`,
/// and a `.interface`-bearing reader/writer pair compatible with
/// `proto.readFrame`/`writeFrame`.
const Stream = if (builtin.os.tag == .windows) struct {
    pipe: pipe_windows.HANDLE,
    file: Io.File,

    fn fromConnectedPipe(pipe: pipe_windows.HANDLE) Stream {
        return .{
            .pipe = pipe,
            .file = .{ .handle = pipe, .flags = .{ .nonblocking = false } },
        };
    }

    fn close(self: *Stream, io: Io) void {
        _ = io;
        pipe_windows.disconnectClient(self.pipe);
    }

    fn idHandle(self: *Stream) std.posix.fd_t {
        return self.pipe;
    }

    fn reader(self: *Stream, io: Io, buf: []u8) Io.File.Reader {
        return self.file.readerStreaming(io, buf);
    }

    fn writer(self: *Stream, io: Io, buf: []u8) Io.File.Writer {
        return self.file.writerStreaming(io, buf);
    }
} else struct {
    inner: net.Stream,

    fn fromAccepted(s: net.Stream) Stream {
        return .{ .inner = s };
    }

    fn close(self: *Stream, io: Io) void {
        self.inner.close(io);
    }

    fn idHandle(self: *Stream) std.posix.fd_t {
        return self.inner.socket.handle;
    }

    fn reader(self: *Stream, io: Io, buf: []u8) net.Stream.Reader {
        return net.Stream.Reader.init(self.inner, io, buf);
    }

    fn writer(self: *Stream, io: Io, buf: []u8) net.Stream.Writer {
        return net.Stream.Writer.init(self.inner, io, buf);
    }
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    io: Io,
    secrets: *MemStore,
    timer: idle_mod.IdleTimer,
    server: Server,
    socket_path: []const u8,
    shutdown: std.atomic.Value(bool),
    policy: policy_mod.Policy,
    rejected: std.atomic.Value(u32),
    audit_logger: ?*audit.Logger,

    pub fn start(allocator: std.mem.Allocator, io: Io, cfg: Config, secrets: *MemStore) !Service {
        const server = try Server.start(io, cfg.socket_path);
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

        if (builtin.os.tag == .windows) {
            try self.runWindows();
        } else {
            try self.runPosix();
        }
    }

    fn runPosix(self: *Service) !void {
        while (!self.shutdown.load(.acquire)) {
            const accepted = self.server.inner.accept(self.io) catch |err| switch (err) {
                error.SocketNotListening, error.Canceled => break,
                else => return err,
            };
            var stream = Stream.fromAccepted(accepted);
            self.handle(&stream) catch |err| {
                std.log.warn("handler error: {s}", .{@errorName(err)});
            };
            if (self.shutdown.load(.acquire)) break;
        }
    }

    fn runWindows(self: *Service) !void {
        while (!self.shutdown.load(.acquire)) {
            // Recreate the pipe instance once the previous client
            // disconnects so we can wait for the next one. The very first
            // iteration uses the instance created in Server.start.
            if (@intFromPtr(self.server.pipe) == @intFromPtr(pipe_windows.INVALID_HANDLE_VALUE)) {
                self.server.pipe = pipe_windows.createServerPipe(@ptrCast(&self.server.name_wide)) catch break;
            }
            pipe_windows.connectServer(self.server.pipe) catch break;
            if (self.shutdown.load(.acquire)) break;

            var stream = Stream.fromConnectedPipe(self.server.pipe);
            self.handle(&stream) catch |err| {
                std.log.warn("handler error: {s}", .{@errorName(err)});
            };
            // Disconnect + recreate next instance.
            pipe_windows.disconnectClient(self.server.pipe);
            pipe_windows.closeHandle(self.server.pipe);
            self.server.pipe = pipe_windows.INVALID_HANDLE_VALUE;
            if (self.shutdown.load(.acquire)) break;
        }
    }

    pub fn deinit(self: *Service) void {
        self.emit(.{ .service_locked = .{ .ts_ms = nowMs(self.io), .reason = "exit" } });
        self.shutdown.store(true, .release);
        self.server.deinit(self.io);
        if (builtin.os.tag != .windows) {
            Io.Dir.cwd().deleteFile(self.io, self.socket_path) catch {};
        }
        zeroAll(self.secrets);
    }

    fn handle(self: *Service, stream: *Stream) !void {
        defer stream.close(self.io);

        const ident = identity.verify(stream.idHandle()) catch {
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
        var reader = stream.reader(self.io, &rbuf);
        var writer = stream.writer(self.io, &wbuf);

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
                self.server.cancel(self.io);
                return;
            }
        }
    }
};

fn zeroAll(s: *MemStore) void {
    var it = s.map.iterator();
    while (it.next()) |entry| entry.value_ptr.*.zero();
}

/// Force the bound AF_UNIX socket to mode 0600. No-op on Windows where
/// the analogous protection is the Named Pipe DACL.
fn restrictSocketPermissions(path: []const u8) !void {
    if (builtin.os.tag == .windows) return;
    const path_z = try std.posix.toPosixPath(path);
    if (std.c.chmod(&path_z, 0o600) != 0) return error.SocketChmodFailed;
}

test "defaultSocketPath builds platform-appropriate path" {
    var buf: [520]u8 = undefined;
    const p = try defaultSocketPath(&buf);
    if (builtin.os.tag == .windows) {
        try std.testing.expect(std.mem.startsWith(u8, p, "\\\\.\\pipe\\cora-"));
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

    var file = try Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const st = try file.stat(io);
    try std.testing.expectEqual(
        @as(std.posix.mode_t, 0o600),
        st.permissions.toMode() & 0o777,
    );
}
