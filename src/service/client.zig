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

    var f2 = try conn.roundtrip(.spawn, payload);
    defer f2.deinit(allocator);
    if (f2.op == @intFromEnum(proto.Op.err)) return CoraError.SecretNotAllowedForTask;
    if (f2.op != @intFromEnum(proto.Op.spawn)) return CoraError.Io;

    return proto.SpawnResp.decode(f2.payload);
}
