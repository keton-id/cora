const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = Io.net;
const proto = @import("proto.zig");
const pipe_windows = @import("pipe_windows.zig");
const CoraError = @import("../error.zig").CoraError;

/// Per-platform client connection holder.
///
/// POSIX:   AF_UNIX socket via `net.Stream`.
/// Windows: Named Pipe HANDLE wrapped in `Io.File` so the existing
///          `proto.readFrame` / `writeFrame` (which take any `Io.Reader`
///          / `Io.Writer`) keep working unchanged.
pub const Conn = if (builtin.os.tag == .windows) struct {
    pipe: pipe_windows.HANDLE,
    file: Io.File,
    io: Io,
    allocator: std.mem.Allocator,
    rbuf: [4096]u8 = undefined,
    wbuf: [4096]u8 = undefined,

    pub fn deinit(self: *Conn) void {
        pipe_windows.closeHandle(self.pipe);
    }

    pub fn writeFrame(self: *Conn, op: proto.Op, payload: []const u8) !void {
        var writer = self.file.writerStreaming(self.io, &self.wbuf);
        try proto.writeFrame(&writer.interface, op, payload);
        try writer.interface.flush();
    }

    pub fn readFrame(self: *Conn) !proto.Frame {
        var reader = self.file.readerStreaming(self.io, &self.rbuf);
        return proto.readFrame(&reader.interface, self.allocator);
    }

    pub fn roundtrip(self: *Conn, op: proto.Op, payload: []const u8) !proto.Frame {
        try self.writeFrame(op, payload);
        return self.readFrame();
    }
} else struct {
    stream: net.Stream,
    io: Io,
    allocator: std.mem.Allocator,
    rbuf: [4096]u8 = undefined,
    wbuf: [4096]u8 = undefined,

    pub fn deinit(self: *Conn) void {
        self.stream.close(self.io);
    }

    pub fn writeFrame(self: *Conn, op: proto.Op, payload: []const u8) !void {
        var writer = net.Stream.Writer.init(self.stream, self.io, &self.wbuf);
        try proto.writeFrame(&writer.interface, op, payload);
        try writer.interface.flush();
    }

    pub fn readFrame(self: *Conn) !proto.Frame {
        var reader = net.Stream.Reader.init(self.stream, self.io, &self.rbuf);
        return proto.readFrame(&reader.interface, self.allocator);
    }

    pub fn roundtrip(self: *Conn, op: proto.Op, payload: []const u8) !proto.Frame {
        try self.writeFrame(op, payload);
        return self.readFrame();
    }
};

pub fn connect(allocator: std.mem.Allocator, io: Io, socket_path: []const u8) !Conn {
    if (builtin.os.tag == .windows) {
        var name_wide_buf: [pipe_windows.PipeNameMaxWide]u16 = undefined;
        // socket_path on Windows is already the UTF-8 pipe name string
        // (`\\.\pipe\cora-<user>`); convert it to UTF-16Z for CreateFileW.
        if (socket_path.len + 1 > name_wide_buf.len) return CoraError.Io;
        const n = std.unicode.utf8ToUtf16Le(&name_wide_buf, socket_path) catch return CoraError.Io;
        name_wide_buf[n] = 0;
        const name_z: [*:0]const u16 = @ptrCast(&name_wide_buf);

        const pipe = try pipe_windows.connectClient(name_z);
        return .{
            .pipe = pipe,
            .file = .{ .handle = pipe, .flags = .{ .nonblocking = false } },
            .io = io,
            .allocator = allocator,
        };
    } else {
        const ua = try net.UnixAddress.init(socket_path);
        const stream = try ua.connect(io);
        return .{ .stream = stream, .io = io, .allocator = allocator };
    }
}

pub fn isRunning(io: Io, socket_path: []const u8) bool {
    var alloc = std.heap.DebugAllocator(.{}){};
    defer _ = alloc.deinit();
    var conn = connect(alloc.allocator(), io, socket_path) catch return false;
    defer conn.deinit();
    var f = conn.roundtrip(.ping, "") catch return false;
    defer f.deinit(alloc.allocator());
    return f.op == @intFromEnum(proto.Op.ping);
}

pub fn status(allocator: std.mem.Allocator, io: Io, socket_path: []const u8) !proto.StatusResp {
    var conn = try connect(allocator, io, socket_path);
    defer conn.deinit();
    var f = try conn.roundtrip(.status, "");
    defer f.deinit(allocator);
    if (f.op != @intFromEnum(proto.Op.status)) return CoraError.Io;
    return proto.StatusResp.decode(f.payload);
}

/// Fetch the list of secret NAMES held by the running service. Returns
/// owned copies — caller must free each element and the outer slice. The
/// service exposes names (no values) via an unauthenticated op so that
/// `cr secrets list` can skip the passphrase prompt while the vault is
/// already unlocked.
pub fn secretsList(allocator: std.mem.Allocator, io: Io, socket_path: []const u8) ![][]const u8 {
    var conn = try connect(allocator, io, socket_path);
    defer conn.deinit();
    var f = try conn.roundtrip(.secrets_list, "");
    defer f.deinit(allocator);
    if (f.op != @intFromEnum(proto.Op.secrets_list)) return CoraError.Io;

    var iter = try proto.decodeNameList(f.payload);
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |n| allocator.free(n);
        out.deinit(allocator);
    }
    while (iter.next()) |name| {
        const copy = try allocator.dupe(u8, name);
        errdefer allocator.free(copy);
        try out.append(allocator, copy);
    }
    return out.toOwnedSlice(allocator);
}

/// Fetch the human-readable policy summary from the running service.
/// Returns an owned text buffer ready to write to stdout verbatim — the
/// service formats it identically to the offline `cr policy show` path.
pub fn policyShow(allocator: std.mem.Allocator, io: Io, socket_path: []const u8) ![]u8 {
    var conn = try connect(allocator, io, socket_path);
    defer conn.deinit();
    var f = try conn.roundtrip(.policy_show, "");
    defer f.deinit(allocator);
    if (f.op != @intFromEnum(proto.Op.policy_show)) return CoraError.Io;
    return allocator.dupe(u8, f.payload);
}

pub fn lock(allocator: std.mem.Allocator, io: Io, socket_path: []const u8) !void {
    var conn = try connect(allocator, io, socket_path);
    defer conn.deinit();
    var f = try conn.roundtrip(.lock, "");
    defer f.deinit(allocator);
    if (f.op != @intFromEnum(proto.Op.lock)) return CoraError.Io;
}

pub fn exec(
    allocator: std.mem.Allocator,
    io: Io,
    socket_path: []const u8,
    task_name: []const u8,
    argv: []const []const u8,
) !proto.SpawnResp {
    var conn = try connect(allocator, io, socket_path);
    defer conn.deinit();

    var f1 = try conn.roundtrip(.task_declare, task_name);
    defer f1.deinit(allocator);
    if (f1.op == @intFromEnum(proto.Op.err)) return CoraError.NoActiveTask;
    if (f1.op != @intFromEnum(proto.Op.task_declare)) return CoraError.Io;

    const payload = try proto.encodeSpawnPayload(allocator, task_name, argv);
    defer allocator.free(payload);

    if (builtin.os.tag == .windows) {
        // Windows: Named Pipes don't carry ancillary data the SCM_RIGHTS
        // way. Instead we ship the *values* of our stdin/stdout/stderr
        // handles as a 24-byte prefix on the spawn payload, and the
        // daemon `DuplicateHandle`s them out of our process via
        // `OpenProcess(PROCESS_DUP_HANDLE, GetNamedPipeClientProcessId)`.
        // The duplicated handles get plugged into STARTUPINFOW so the
        // spawned child inherits our terminal, mirroring POSIX SCM_RIGHTS.
        const win_payload = try encodeSpawnPayloadWithStdio(allocator, payload);
        defer allocator.free(win_payload);

        var f2 = try conn.roundtrip(.spawn, win_payload);
        defer f2.deinit(allocator);
        if (f2.op == @intFromEnum(proto.Op.err)) return CoraError.SecretNotAllowedForTask;
        if (f2.op != @intFromEnum(proto.Op.spawn)) return CoraError.Io;
        return proto.SpawnResp.decode(f2.payload);
    }

    // POSIX: send the spawn frame via `sendmsg` so we can attach our own
    // stdin/stdout/stderr to the message via SCM_RIGHTS. The service
    // dup2s them into the child process, which lets `cr exec` show the
    // child's output on the caller's terminal instead of dropping it
    // into the daemon's `/dev/null` stdio (inherited from fork+setsid).
    var frame_buf = try allocator.alloc(u8, 6 + payload.len);
    defer allocator.free(frame_buf);
    frame_buf[0] = proto.protocol_version;
    frame_buf[1] = @intFromEnum(proto.Op.spawn);
    std.mem.writeInt(u32, frame_buf[2..6], @intCast(payload.len), .little);
    @memcpy(frame_buf[6..], payload);

    try sendFrameWithStdioFds(conn.stream.socket.handle, frame_buf);

    var f2 = try conn.readFrame();
    defer f2.deinit(allocator);
    if (f2.op == @intFromEnum(proto.Op.err)) return CoraError.SecretNotAllowedForTask;
    if (f2.op != @intFromEnum(proto.Op.spawn)) return CoraError.Io;
    return proto.SpawnResp.decode(f2.payload);
}

/// Windows-only. Prepend our three `GetStdHandle` values (little-endian
/// u64 each) to the existing spawn payload so the daemon can
/// `DuplicateHandle` them across after reading the frame. The plain
/// `proto.encodeSpawnPayload` body follows unchanged at byte 24.
fn encodeSpawnPayloadWithStdio(
    allocator: std.mem.Allocator,
    base_payload: []const u8,
) ![]u8 {
    if (builtin.os.tag != .windows) unreachable;
    const stdio = pipe_windows.callerStdioHandles();
    const out = try allocator.alloc(u8, 24 + base_payload.len);
    errdefer allocator.free(out);
    inline for (0..3) |i| {
        const v: u64 = @intCast(@intFromPtr(stdio[i]));
        std.mem.writeInt(u64, out[i * 8 ..][0..8], v, .little);
    }
    @memcpy(out[24..], base_payload);
    return out;
}

/// POSIX-only. Send `frame_bytes` over `fd` with our own stdin/stdout/stderr
/// attached as a single SCM_RIGHTS control message. The service receives
/// the frame and the three fds in one `recvmsg` call, so the child it
/// spawns can inherit the caller's terminal. Refuses to fall back to a
/// plain write — losing the fds would silently revert to the broken
/// `/dev/null` child-stdio behavior, and `cr exec` callers expect to see
/// their child's output.
fn sendFrameWithStdioFds(fd: std.posix.fd_t, frame_bytes: []const u8) !void {
    if (builtin.os.tag == .windows) unreachable;

    const Fds = [3]std.posix.fd_t;
    const fds: Fds = .{
        std.posix.STDIN_FILENO,
        std.posix.STDOUT_FILENO,
        std.posix.STDERR_FILENO,
    };

    const hdr_len = @sizeOf(std.c.cmsghdr);
    const data_len = @sizeOf(Fds);

    var cmsg_buf: [hdr_len + data_len]u8 align(@alignOf(std.c.cmsghdr)) = undefined;
    const cmsg: *std.c.cmsghdr = @ptrCast(@alignCast(&cmsg_buf));
    cmsg.* = .{
        .len = @intCast(hdr_len + data_len),
        .level = std.posix.SOL.SOCKET,
        .type = std.posix.SCM.RIGHTS,
    };
    @memcpy(cmsg_buf[hdr_len..][0..data_len], std.mem.asBytes(&fds));

    var iov = [_]std.posix.iovec_const{
        .{ .base = frame_bytes.ptr, .len = frame_bytes.len },
    };
    var msg: std.c.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = @ptrCast(&cmsg_buf),
        .controllen = @intCast(cmsg_buf.len),
        .flags = 0,
    };

    const n = std.c.sendmsg(fd, &msg, 0);
    if (n < 0) return CoraError.Io;
    // Spawn frames are bounded by max_payload_len (1 MiB) and our control
    // socket is SOCK_STREAM, so a short write is theoretically possible
    // but practically does not happen for the payload sizes we send.
    // Refuse rather than silently send the remainder without the fds.
    if (@as(usize, @intCast(n)) != frame_bytes.len) return CoraError.Io;
}
