const std = @import("std");
const CoraError = @import("../error.zig").CoraError;
const CallerIdentity = @import("identity.zig").CallerIdentity;
const max_path_len = @import("identity.zig").max_path_len;

const SOL_LOCAL: i32 = 0;
const LOCAL_PEERPID: u32 = 0x002;

extern "c" fn proc_pidpath(pid: c_int, buffer: ?*anyopaque, buffersize: u32) c_int;

pub fn verify(fd: std.posix.fd_t) CoraError!CallerIdentity {
    var pid: c_int = 0;
    var len: std.posix.socklen_t = @sizeOf(c_int);
    const rc = std.c.getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len);
    if (rc != 0) return CoraError.CallerNotAllowed;

    // macOS does not expose PEERUID via getsockopt on Unix sockets.
    // The socket file is chmod'd to 0600 by Service.start, so any connecting
    // process must already share our uid (or be root). We surface our own uid
    // here for the audit trail.
    var ident = CallerIdentity{ .pid = @intCast(pid), .uid = @intCast(std.c.getuid()) };
    try fillPath(@intCast(pid), &ident);
    return ident;
}

pub fn lookupByPid(pid: i32) CoraError!CallerIdentity {
    var ident = CallerIdentity{ .pid = pid, .uid = 0 };
    try fillPath(pid, &ident);
    return ident;
}

fn fillPath(pid: i32, ident: *CallerIdentity) CoraError!void {
    var buf: [max_path_len]u8 = undefined;
    const n = proc_pidpath(@intCast(pid), &buf, @intCast(buf.len));
    if (n <= 0) return CoraError.CallerNotAllowed;
    const len: usize = @intCast(n);
    @memcpy(ident.binary_path_buf[0..len], buf[0..len]);
    ident.binary_path_len = len;
}
