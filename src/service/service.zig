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
const spawn_windows = @import("spawn_windows.zig");
const binhash = @import("../crypto/binhash.zig");
const CoraError = @import("../error.zig").CoraError;

/// Per-platform stdio passthrough handle carried from `handle` into
/// `handleSpawn`. POSIX: three fds captured from SCM_RIGHTS. Windows:
/// three HANDLEs duplicated into the daemon process via
/// `pipe_windows.duplicateClientStdio`.
const StdioPassthrough = if (builtin.os.tag == .windows)
    ?[3]pipe_windows.HANDLE
else
    ?[3]std.posix.fd_t;

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
/// POSIX:   AF_UNIX socket path `/tmp/cora-<uid>.sock`.
/// Windows: Named Pipe name `\\.\pipe\cora-<username>`.
///
/// Returns the path bytes inside `buf`. Windows uses Named Pipes
/// (`pipe_windows.zig`) so the kernel can report the connected client's
/// PID via `GetNamedPipeClientProcessId` — same trust surface as
/// `SO_PEERCRED` on Linux and `LOCAL_PEERPID` on macOS. The string is
/// opaque to callers — `service.start` and `client.connect` interpret
/// it per-platform.
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
    /// Base environment for spawned children. When set, the child
    /// inherits these variables with the task's secrets overlaid on
    /// top. When null the child env contains only the secrets.
    environ: ?*const std.process.Environ.Map = null,
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
    environ: ?*const std.process.Environ.Map,

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
            .environ = cfg.environ,
        };
        svc.emit(.{ .service_unlocked = .{ .ts_ms = nowMs(svc.io) } });
        return svc;
    }

    fn emit(self: *Service, ev: audit.Event) void {
        if (self.audit_logger) |l| l.log(ev) catch |err| {
            std.log.warn("audit log error: {s}", .{@errorName(err)});
        };
    }

    /// Enforce the optional per-caller binary-hash pin. Returns true when the
    /// caller is unpinned (no requirement) or the binary at `path` hashes to
    /// the pinned digest. Fails closed: any error hashing the file (missing,
    /// unreadable) returns false, so a caller that cannot be verified is
    /// rejected rather than admitted.
    fn callerHashOk(self: *Service, path: []const u8) bool {
        const expected = self.policy.callerExpectedHash(path) orelse return true;
        const got = binhash.hashFileHex(self.allocator, self.io, Io.Dir.cwd(), path) catch return false;
        return binhash.hexEql(&got, expected);
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
        // Reuse the single named-pipe HANDLE across accept iterations.
        // DisconnectNamedPipe + ConnectNamedPipe puts the same handle
        // back into the listening state, so the same kernel pipe object
        // serves every connection. Closing + re-creating with
        // FILE_FLAG_FIRST_PIPE_INSTANCE between iterations is racy:
        // after CloseHandle the kernel still references the previous
        // instance briefly while a disconnecting client is reaped, and
        // a back-to-back createServerPipe call hits that window and
        // fails. Polling clients (cr status loops, the new Windows
        // integration tests' pollStatus) hit it deterministically and
        // caused the accept loop to break, killing the daemon
        // mid-test.
        while (!self.shutdown.load(.acquire)) {
            pipe_windows.connectServer(self.server.pipe) catch break;
            if (self.shutdown.load(.acquire)) break;

            var stream = Stream.fromConnectedPipe(self.server.pipe);
            self.handle(&stream) catch |err| {
                std.log.warn("handler error: {s}", .{@errorName(err)});
            };
            pipe_windows.disconnectClient(self.server.pipe);
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

            if (requiresCallerPolicy(op) and !self.policy.isCallerAllowed(ident.path())) {
                _ = self.rejected.fetchAdd(1, .monotonic);
                self.emit(.{ .caller_rejected = .{
                    .ts_ms = nowMs(self.io),
                    .pid = ident.pid,
                    .binary = ident.path(),
                    .reason = "binary not in allowed_callers",
                } });
                try proto.writeFrame(&writer.interface, .err, "caller not allowed");
                try writer.interface.flush();
                return;
            }

            if (requiresCallerPolicy(op) and !self.callerHashOk(ident.path())) {
                _ = self.rejected.fetchAdd(1, .monotonic);
                self.emit(.{ .caller_rejected = .{
                    .ts_ms = nowMs(self.io),
                    .pid = ident.pid,
                    .binary = ident.path(),
                    .reason = "caller binary hash mismatch",
                } });
                try proto.writeFrame(&writer.interface, .err, "caller hash mismatch");
                try writer.interface.flush();
                return;
            }

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
                    // Cancel the accept loop so the daemon exits promptly
                    // instead of staying blocked on the next iteration.
                    // Without this, `cr lock` returned exit 0 but the
                    // daemon process kept running — the next `cr unlock`
                    // would then spawn a second daemon, accumulating
                    // indefinitely. `Server.cancel` is platform-aware
                    // (closes the AF_UNIX socket on POSIX, closes the
                    // pipe handle on Windows) and is the same wakeup the
                    // idle watcher already uses on timeout.
                    self.server.cancel(self.io);
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
                    // Drop out of the buffered-read loop. The next frame is
                    // the spawn message and the POSIX client attaches its
                    // stdio fds to it via SCM_RIGHTS — we have to use raw
                    // recvmsg to receive those fds, and that has to happen
                    // on a clean socket with no pre-buffered bytes ahead of
                    // it. The synchronous task_declare ack guarantees the
                    // client has not yet sent the spawn frame, so the
                    // socket buffer is empty when we exit the loop.
                    break;
                },
                .spawn => {
                    // Protocol violation: spawn without prior task_declare.
                    // (Normal clients break out of the loop on task_declare
                    // and never re-enter this arm.)
                    try proto.writeFrame(&writer.interface, .err, "no task declared");
                    try writer.interface.flush();
                    return;
                },
                .secrets_list => {
                    const names = self.secrets.names(self.allocator) catch |err| {
                        try proto.writeFrame(&writer.interface, .err, @errorName(err));
                        try writer.interface.flush();
                        continue;
                    };
                    defer self.allocator.free(names);
                    const payload = proto.encodeNameList(self.allocator, names) catch |err| {
                        try proto.writeFrame(&writer.interface, .err, @errorName(err));
                        try writer.interface.flush();
                        continue;
                    };
                    defer self.allocator.free(payload);
                    try proto.writeFrame(&writer.interface, .secrets_list, payload);
                    try writer.interface.flush();
                },
                .policy_show => {
                    var aw: std.Io.Writer.Allocating = .init(self.allocator);
                    defer aw.deinit();
                    renderPolicy(&aw.writer, &self.policy) catch |err| {
                        try proto.writeFrame(&writer.interface, .err, @errorName(err));
                        try writer.interface.flush();
                        continue;
                    };
                    try proto.writeFrame(&writer.interface, .policy_show, aw.written());
                    try writer.interface.flush();
                },
                else => {
                    try proto.writeFrame(&writer.interface, .err, "unknown op");
                    try writer.interface.flush();
                },
            }
        }

        // Reached here only via the `.task_declare` break above. Now read
        // the spawn frame and (on POSIX) the SCM_RIGHTS-attached stdio fds.
        if (task_name_len == 0) return;

        var stdio_passthrough: StdioPassthrough = null;
        defer {
            if (stdio_passthrough) |handles| {
                if (builtin.os.tag == .windows) {
                    pipe_windows.closeStdioDups(handles);
                } else {
                    for (handles) |fd| _ = std.c.close(fd);
                }
            }
        }

        var spawn_frame = blk: {
            if (builtin.os.tag == .windows) {
                // Windows: Named Pipes cannot carry ancillary data the
                // SCM_RIGHTS way. The client ships the *values* of its
                // stdin/stdout/stderr handles as a 24-byte prefix on the
                // spawn payload. We `DuplicateHandle` them across via
                // `OpenProcess(PROCESS_DUP_HANDLE, client_pid)` so they
                // become valid in the daemon process, then plug them
                // into the spawned child's STARTUPINFOW.
                var f = proto.readFrame(&reader.interface, self.allocator) catch return;
                if (f.payload.len < 24) {
                    f.deinit(self.allocator);
                    return;
                }
                var src: [3]pipe_windows.HANDLE = undefined;
                inline for (0..3) |i| {
                    const v = std.mem.readInt(u64, f.payload[i * 8 ..][0..8], .little);
                    src[i] = @ptrFromInt(@as(usize, @intCast(v)));
                }
                const client_pid = pipe_windows.clientProcessId(stream.idHandle()) catch {
                    f.deinit(self.allocator);
                    return;
                };
                stdio_passthrough = pipe_windows.duplicateClientStdio(client_pid, src) catch null;
                // Strip the 24-byte stdio prefix so `decodeSpawnPayload`
                // sees the same layout it does on POSIX.
                const stripped = self.allocator.dupe(u8, f.payload[24..]) catch {
                    f.deinit(self.allocator);
                    return;
                };
                f.deinit(self.allocator);
                break :blk proto.Frame{ .op = @intFromEnum(proto.Op.spawn), .payload = stripped };
            }
            break :blk recvFrameWithStdioFds(stream.idHandle(), self.allocator, &stdio_passthrough) catch return;
        };
        defer spawn_frame.deinit(self.allocator);

        if (requiresCallerPolicy(.spawn) and !self.policy.isCallerAllowed(ident.path())) {
            _ = self.rejected.fetchAdd(1, .monotonic);
            self.emit(.{ .caller_rejected = .{
                .ts_ms = nowMs(self.io),
                .pid = ident.pid,
                .binary = ident.path(),
                .reason = "binary not in allowed_callers",
            } });
            try proto.writeFrame(&writer.interface, .err, "caller not allowed");
            try writer.interface.flush();
            return;
        }

        if (spawn_frame.op != @intFromEnum(proto.Op.spawn)) {
            try proto.writeFrame(&writer.interface, .err, "expected spawn");
            try writer.interface.flush();
            return;
        }

        self.handleSpawn(&writer.interface, &ident, task_name_buf[0..task_name_len], spawn_frame.payload, stdio_passthrough) catch |err| {
            std.log.warn("spawn failed: {s}", .{@errorName(err)});
            proto.writeFrame(&writer.interface, .err, @errorName(err)) catch {};
            writer.interface.flush() catch {};
        };
    }

    fn handleSpawn(
        self: *Service,
        writer: *Io.Writer,
        ident: *const identity.CallerIdentity,
        declared_task: []const u8,
        payload: []const u8,
        stdio: StdioPassthrough,
    ) !void {
        var parsed = try proto.decodeSpawnPayload(self.allocator, payload);
        defer parsed.deinit();

        if (!std.mem.eql(u8, parsed.task_name, declared_task)) return CoraError.NoActiveTask;
        const task = self.policy.findTask(declared_task) orelse return CoraError.NoActiveTask;
        if (parsed.argv.len == 0) return CoraError.InvalidConfig;

        // Resolve argv[0] to an absolute path and gate it against the
        // task's allowed_targets. Without this gate a trusted caller can
        // still leak a secret value by asking the service to spawn
        // /bin/echo $TOKEN or /bin/cat /proc/self/environ — the caller
        // policy doesn't stop that because the caller IS supposed to be
        // trusted; the missing layer is "what is the trusted caller
        // allowed to run." See policy.isTargetAllowedForTask. The
        // resolution is also useful in dev-mode (no targets configured):
        // it normalizes argv[0] so the audit log records the resolved
        // path, not a relative name.
        var resolved_buf: [identity.max_path_len]u8 = undefined;
        const resolved = resolveTargetPath(parsed.argv[0], &resolved_buf) catch {
            self.emit(.{ .target_rejected = .{
                .ts_ms = nowMs(self.io),
                .caller_pid = ident.pid,
                .caller_bin = ident.path(),
                .task = declared_task,
                .target = parsed.argv[0],
                .reason = "binary not found in daemon PATH",
            } });
            try proto.writeFrame(writer, .err, "target not found");
            try writer.flush();
            return CoraError.TargetNotFound;
        };

        if (!policy_mod.isTargetAllowedForTask(task, resolved)) {
            self.emit(.{ .target_rejected = .{
                .ts_ms = nowMs(self.io),
                .caller_pid = ident.pid,
                .caller_bin = ident.path(),
                .task = declared_task,
                .target = resolved,
                .reason = "target not in allowed_targets",
            } });
            try proto.writeFrame(writer, .err, "target not allowed");
            try writer.flush();
            return CoraError.TargetNotAllowed;
        }

        // Rewrite argv[0] in place with the resolved absolute path so the
        // child sees a deterministic argv and the spawn never falls back
        // to its own PATH search (which might pick a different binary).
        parsed.argv[0] = resolved;

        var env_map = std.process.Environ.Map.init(self.allocator);
        // Environ.Map.put copies each value onto the heap; deinit alone
        // would free those secret copies without wiping them.
        defer {
            // values() is const-qualified API-side, but each entry is a
            // heap dupe owned by the map — writable, safe to constCast.
            for (env_map.values()) |v| std.crypto.secureZero(u8, @constCast(v));
            env_map.deinit();
        }

        // Base environment first, secrets overlaid after — SpawnOptions
        // with a non-null environ_map replaces the child env entirely,
        // so without this merge the child would lose PATH/HOME/TERM.
        if (self.environ) |base| {
            var base_it = base.iterator();
            while (base_it.next()) |entry| {
                try env_map.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        var injected_names = std.ArrayList([]const u8).empty;
        defer injected_names.deinit(self.allocator);
        var missing_names = std.ArrayList([]const u8).empty;
        defer missing_names.deinit(self.allocator);

        var tmp = SecretBuf{};
        defer tmp.zero();
        for (task.allowed_secrets) |name| {
            self.secrets.copyInto(name, &tmp) catch {
                try missing_names.append(self.allocator, name);
                continue;
            };
            try env_map.put(name, tmp.constSlice());
            try injected_names.append(self.allocator, name);
        }

        const start_ms = nowMs(self.io);

        var child_pid: i32 = 0;
        var code: i32 = 0;

        if (builtin.os.tag == .windows) {
            // Windows path: build wide command line + Windows env block
            // from the same argv + env_map, then CreateProcessW the child
            // inheriting the three already-duplicated stdio handles.
            const cmdline = try spawn_windows.buildCommandLineWide(self.allocator, parsed.argv);
            defer self.allocator.free(cmdline);

            // Translate env_map into pair list for buildEnvBlockWide. The
            // env_block carries secret values verbatim — secureZero it
            // before freeing.
            var pairs = std.ArrayList(spawn_windows.EnvPair).empty;
            defer pairs.deinit(self.allocator);
            var env_it = env_map.iterator();
            while (env_it.next()) |entry| {
                try pairs.append(self.allocator, .{
                    .name = entry.key_ptr.*,
                    .value = entry.value_ptr.*,
                });
            }
            const env_block = try spawn_windows.buildEnvBlockWide(self.allocator, pairs.items);
            defer {
                std.crypto.secureZero(u16, env_block);
                self.allocator.free(env_block);
            }

            // Convert exe path to UTF-16Z for lpApplicationName.
            const exe_utf8 = parsed.argv[0];
            var exe_wide_buf = try self.allocator.alloc(u16, exe_utf8.len + 1);
            defer self.allocator.free(exe_wide_buf);
            const exe_n = try std.unicode.utf8ToUtf16Le(exe_wide_buf, exe_utf8);
            exe_wide_buf[exe_n] = 0;

            // Use caller-supplied stdio handles when present; fall back
            // to the daemon's NUL stdio if the dup somehow failed (the
            // child still runs, output goes nowhere — same as the
            // pre-DuplicateHandle Windows behavior, but never silent
            // because we already accepted the spawn frame).
            const stdio_handles: [3]pipe_windows.HANDLE = if (stdio) |h| h else .{
                pipe_windows.INVALID_HANDLE_VALUE,
                pipe_windows.INVALID_HANDLE_VALUE,
                pipe_windows.INVALID_HANDLE_VALUE,
            };

            const child = try spawn_windows.spawnInheritingStdio(
                @ptrCast(exe_wide_buf.ptr),
                @ptrCast(cmdline.ptr),
                @ptrCast(env_block.ptr),
                stdio_handles,
            );
            child_pid = @intCast(child.pid);

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

            const exit_code = try spawn_windows.waitForExit(child);
            // NTSTATUS exit codes from crashed children (e.g. 0xC0000005)
            // exceed maxInt(i32); @intCast would panic and kill the daemon.
            code = @bitCast(exit_code);
        } else {
            // POSIX path: hand the caller's terminal to the child via
            // the SCM_RIGHTS-captured fds. Without them the child inherits
            // the daemon's `/dev/null` stdio (set up by fork+setsid in
            // cmdUnlock), which silently swallows stdout.
            var spawn_opts: std.process.SpawnOptions = .{
                .argv = parsed.argv,
                .environ_map = &env_map,
            };
            if (stdio) |fds| {
                spawn_opts.stdin = .{ .file = .{ .handle = fds[0], .flags = .{ .nonblocking = false } } };
                spawn_opts.stdout = .{ .file = .{ .handle = fds[1], .flags = .{ .nonblocking = false } } };
                spawn_opts.stderr = .{ .file = .{ .handle = fds[2], .flags = .{ .nonblocking = false } } };
            }

            var child = try std.process.spawn(self.io, spawn_opts);
            child_pid = childPid(child);

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
            code = switch (term) {
                .exited => |c| @intCast(c),
                .signal => |s| -@as(i32, @intCast(@intFromEnum(s))),
                .stopped, .unknown => -1,
            };
        }

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

/// Return true when the requested protocol op accesses secret values and
/// therefore must be gated by `allowed_callers`. Management ops (ping /
/// status / lock) operate on liveness or shutdown only — they do not leak
/// secret values, so the same-uid + chmod 0600 (POSIX) / Named Pipe DACL
/// (Windows) trust is sufficient and the cr CLI itself can drive them
/// without being whitelisted.
///
/// Regression context: gating ping/status/lock by `allowed_callers` made
/// `cr status` report "not running" whenever the user added any caller to
/// the policy, because the cr binary itself was not on the list and the
/// service silently dropped the connection.
pub fn requiresCallerPolicy(op: proto.Op) bool {
    return switch (op) {
        .task_declare, .spawn => true,
        else => false,
    };
}

/// POSIX-only. Read the spawn frame from `fd` via `recvmsg`, capturing
/// any SCM_RIGHTS control message the client attached (three stdio fds
/// for the child process). Returns the parsed frame; the captured fds
/// land in `fds_out` for the caller to dup into the child and then
/// close. Falls back to leaving `fds_out` as `null` if the client did
/// not attach a cmsg, in which case the child inherits the daemon's
/// stdio (which is `/dev/null` on the standard fork+setsid path).
fn recvFrameWithStdioFds(
    fd: std.posix.fd_t,
    allocator: std.mem.Allocator,
    fds_out: *StdioPassthrough,
) !proto.Frame {
    if (builtin.os.tag == .windows) unreachable;

    var hdr: [6]u8 = undefined;
    var hdr_got: usize = 0;

    while (hdr_got < hdr.len) {
        var iov = [_]std.posix.iovec{
            .{ .base = @ptrCast(&hdr[hdr_got]), .len = hdr.len - hdr_got },
        };
        var cmsg_buf: [@sizeOf(std.c.cmsghdr) + @sizeOf([3]std.posix.fd_t)]u8 align(@alignOf(std.c.cmsghdr)) = undefined;
        var msg: std.c.msghdr = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = @ptrCast(&cmsg_buf),
            .controllen = @intCast(cmsg_buf.len),
            .flags = 0,
        };
        const n = std.c.recvmsg(fd, &msg, 0);
        if (n <= 0) return CoraError.Io;
        hdr_got += @intCast(n);

        // Ancillary data is delivered with the first recvmsg covering a
        // given sendmsg. Capture once; later recvs for the rest of the
        // header (rare for our small frames) won't carry cmsg again.
        if (fds_out.* == null and msg.controllen >= @sizeOf(std.c.cmsghdr)) {
            const cmsg: *const std.c.cmsghdr = @ptrCast(@alignCast(&cmsg_buf));
            if (cmsg.level == std.posix.SOL.SOCKET and cmsg.type == std.posix.SCM.RIGHTS) {
                const hdr_len = @sizeOf(std.c.cmsghdr);
                const expected_len = hdr_len + @sizeOf([3]std.posix.fd_t);
                if (cmsg.len == expected_len) {
                    var fds: [3]std.posix.fd_t = undefined;
                    @memcpy(std.mem.asBytes(&fds), cmsg_buf[hdr_len..][0..@sizeOf(@TypeOf(fds))]);
                    fds_out.* = fds;
                } else if (cmsg.len > hdr_len) {
                    // Client attached a different fd count. Reading three
                    // regardless would treat garbage stack bytes as fds
                    // and later close() them — potentially closing the
                    // daemon's own descriptors. Close what was actually
                    // delivered and proceed without stdio passthrough.
                    const delivered: usize = @min(
                        (@as(usize, cmsg.len) - hdr_len) / @sizeOf(std.posix.fd_t),
                        @as(usize, 3),
                    );
                    var fds: [3]std.posix.fd_t = undefined;
                    const n_bytes = delivered * @sizeOf(std.posix.fd_t);
                    @memcpy(std.mem.asBytes(&fds)[0..n_bytes], cmsg_buf[hdr_len..][0..n_bytes]);
                    for (fds[0..delivered]) |dfd| _ = std.c.close(dfd);
                }
            }
        }
    }

    if (hdr[0] != proto.protocol_version) return CoraError.UnsupportedVersion;
    const op = hdr[1];
    const len = std.mem.readInt(u32, hdr[2..6], .little);
    if (len > proto.max_payload_len) return CoraError.Io;

    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);

    var payload_got: usize = 0;
    while (payload_got < len) {
        const n = std.c.recv(fd, @ptrCast(&buf[payload_got]), len - payload_got, 0);
        if (n <= 0) return CoraError.Io;
        payload_got += @intCast(n);
    }

    return .{ .op = op, .payload = buf };
}

/// Resolve `target` to an absolute path. Absolute inputs pass through
/// verbatim. Relative inputs are searched against the daemon's `PATH`
/// (inherited from the shell that ran `cr unlock`) and the first match
/// that is executable for the daemon UID wins. Returns the resolved
/// path stored in `out_buf`. Errors if the target cannot be found.
///
/// We do this server-side (rather than letting `std.process.spawn`
/// resolve later) for two reasons:
/// 1. The allowed_targets check needs the absolute path to compare.
/// 2. After resolution we replace argv[0] with the absolute path so the
///    actual spawn cannot drift into a different `PATH` and end up
///    invoking a different binary than the one we audited / approved.
fn resolveTargetPath(target: []const u8, out_buf: []u8) ![]const u8 {
    if (target.len == 0) return error.TargetNotFound;

    if (builtin.os.tag == .windows) return resolveTargetPathWindows(target, out_buf);

    if (target[0] == '/' or (target.len >= 2 and target[0] == '.' and target[1] == '/') or
        (target.len >= 3 and target[0] == '.' and target[1] == '.' and target[2] == '/'))
    {
        // Absolute or explicit relative: trust as-is, but it must
        // actually exist and be executable.
        if (target.len > out_buf.len) return error.TargetNotFound;
        @memcpy(out_buf[0..target.len], target);
        if (!isExecutable(out_buf[0..target.len])) return error.TargetNotFound;
        return out_buf[0..target.len];
    }

    // Search daemon PATH.
    const path_env_ptr = std.c.getenv("PATH") orelse return error.TargetNotFound;
    const path_env = std.mem.span(path_env_ptr);

    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const need_sep: usize = if (dir[dir.len - 1] == '/') 0 else 1;
        const total = dir.len + need_sep + target.len;
        if (total > out_buf.len) continue;
        @memcpy(out_buf[0..dir.len], dir);
        if (need_sep == 1) out_buf[dir.len] = '/';
        @memcpy(out_buf[dir.len + need_sep ..][0..target.len], target);
        const candidate = out_buf[0..total];
        if (isExecutable(candidate)) return candidate;
    }
    return error.TargetNotFound;
}

/// Resolve `target` to an absolute path on Windows, searching `PATH`
/// (`;`-separated) and trying each entry in `PATHEXT` (default
/// `.COM;.EXE;.BAT;.CMD`) just like `cmd.exe` does. Absolute inputs
/// (containing a drive letter or starting with `\\`) pass through after
/// the existence check.
fn resolveTargetPathWindows(target: []const u8, out_buf: []u8) ![]const u8 {
    if (isAbsoluteWindowsPath(target)) {
        if (target.len > out_buf.len) return error.TargetNotFound;
        @memcpy(out_buf[0..target.len], target);
        if (!fileExistsWindows(out_buf[0..target.len])) return error.TargetNotFound;
        return out_buf[0..target.len];
    }

    const path_env_ptr = std.c.getenv("PATH") orelse return error.TargetNotFound;
    const path_env = std.mem.span(path_env_ptr);

    const pathext_default = ".COM;.EXE;.BAT;.CMD";
    const pathext_env: []const u8 = if (std.c.getenv("PATHEXT")) |p|
        std.mem.span(p)
    else
        pathext_default;

    const has_ext = std.mem.lastIndexOfScalar(u8, target, '.') != null and
        std.mem.lastIndexOfScalar(u8, target, '\\') == null;

    var path_it = std.mem.tokenizeScalar(u8, path_env, ';');
    while (path_it.next()) |dir| {
        if (dir.len == 0) continue;
        const need_sep: usize = if (dir[dir.len - 1] == '\\' or dir[dir.len - 1] == '/') 0 else 1;

        // Try the bare target first when it already has an extension.
        if (has_ext) {
            const total = dir.len + need_sep + target.len;
            if (total <= out_buf.len) {
                @memcpy(out_buf[0..dir.len], dir);
                if (need_sep == 1) out_buf[dir.len] = '\\';
                @memcpy(out_buf[dir.len + need_sep ..][0..target.len], target);
                if (fileExistsWindows(out_buf[0..total])) return out_buf[0..total];
            }
        }

        var ext_it = std.mem.tokenizeScalar(u8, pathext_env, ';');
        while (ext_it.next()) |ext| {
            if (ext.len == 0) continue;
            const total = dir.len + need_sep + target.len + ext.len;
            if (total > out_buf.len) continue;
            @memcpy(out_buf[0..dir.len], dir);
            if (need_sep == 1) out_buf[dir.len] = '\\';
            @memcpy(out_buf[dir.len + need_sep ..][0..target.len], target);
            @memcpy(out_buf[dir.len + need_sep + target.len ..][0..ext.len], ext);
            if (fileExistsWindows(out_buf[0..total])) return out_buf[0..total];
        }
    }
    return error.TargetNotFound;
}

fn isAbsoluteWindowsPath(p: []const u8) bool {
    if (p.len >= 2 and p[1] == ':') return true; // drive-letter absolute (C:\...)
    if (p.len >= 2 and (p[0] == '\\' or p[0] == '/') and (p[1] == '\\' or p[1] == '/')) return true; // UNC
    return false;
}

fn fileExistsWindows(path: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    var wide_buf: [1024]u16 = undefined;
    if (path.len + 1 > wide_buf.len) return false;
    const n = std.unicode.utf8ToUtf16Le(&wide_buf, path) catch return false;
    wide_buf[n] = 0;
    const attrs = GetFileAttributesW(@ptrCast(&wide_buf));
    return attrs != INVALID_FILE_ATTRIBUTES;
}

const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;

extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(.winapi) u32;

fn isExecutable(path: []const u8) bool {
    if (builtin.os.tag == .windows) return fileExistsWindows(path);
    const path_z = std.posix.toPosixPath(path) catch return false;
    // X_OK = 0x01 on POSIX. std.posix.access is not in 0.16 in a
    // cross-portable shape, so use libc directly. Returns 0 on success.
    return std.c.access(&path_z, 0x01) == 0;
}

/// Render the same human-readable policy summary that `cr policy show`
/// emits when invoked against an offline vault. Used by the in-memory
/// `policy_show` service op so the on-the-wire response matches the
/// offline fallback verbatim — the CLI writes the response straight to
/// stdout without reformatting.
pub fn renderPolicy(w: *Io.Writer, pol: *const policy_mod.Policy) !void {
    try w.print("idle_timeout_ms: {d}\n", .{pol.idle_timeout_ms});
    try w.print("allowed_callers ({d}):\n", .{pol.allowed_callers.len});
    for (pol.allowed_callers) |c| try w.print("  {s}\n", .{c});
    try w.print("tasks ({d}):\n", .{pol.tasks.len});
    for (pol.tasks) |t| {
        try w.print("  {s}:\n", .{t.name});
        try w.print("    secrets ({d}):", .{t.allowed_secrets.len});
        for (t.allowed_secrets) |s| try w.print(" {s}", .{s});
        try w.print("\n", .{});
        if (t.allowed_targets.len == 0) {
            try w.print("    targets: (any — dev mode)\n", .{});
        } else {
            try w.print("    targets ({d}):\n", .{t.allowed_targets.len});
            for (t.allowed_targets) |tgt| try w.print("      {s}\n", .{tgt});
        }
    }
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

test "requiresCallerPolicy gates secret-touching ops only" {
    // Management ops must bypass `allowed_callers` so that `cr status` /
    // `cr lock` work even when the user has whitelisted other binaries
    // (e.g. only `gh`) and not the cr binary itself.
    try std.testing.expect(!requiresCallerPolicy(.ping));
    try std.testing.expect(!requiresCallerPolicy(.status));
    try std.testing.expect(!requiresCallerPolicy(.lock));

    // Secret-touching ops MUST stay gated.
    try std.testing.expect(requiresCallerPolicy(.task_declare));
    try std.testing.expect(requiresCallerPolicy(.spawn));
}
