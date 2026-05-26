const std = @import("std");
const CoraError = @import("../error.zig").CoraError;
const CallerIdentity = @import("identity.zig").CallerIdentity;
const max_path_len = @import("identity.zig").max_path_len;

const UCred = extern struct {
    pid: i32,
    uid: u32,
    gid: u32,
};

pub fn verify(fd: std.posix.fd_t) CoraError!CallerIdentity {
    var cred: UCred = undefined;
    var len: std.posix.socklen_t = @sizeOf(UCred);
    const rc = std.c.getsockopt(fd, std.c.SOL.SOCKET, std.c.SO.PEERCRED, &cred, &len);
    if (rc != 0) return CoraError.CallerNotAllowed;

    var ident = CallerIdentity{ .pid = cred.pid, .uid = cred.uid };
    try fillPath(cred.pid, &ident);
    return ident;
}

pub fn lookupByPid(pid: i32) CoraError!CallerIdentity {
    var ident = CallerIdentity{ .pid = pid, .uid = 0 };
    try fillPath(pid, &ident);
    return ident;
}

fn fillPath(pid: i32, ident: *CallerIdentity) CoraError!void {
    var link_buf: [64]u8 = undefined;
    const link = std.fmt.bufPrint(&link_buf, "/proc/{d}/exe", .{pid}) catch return CoraError.CallerNotAllowed;
    var out: [max_path_len]u8 = undefined;
    const path = std.fs.readLinkAbsolute(link, &out) catch return CoraError.CallerNotAllowed;
    @memcpy(ident.binary_path_buf[0..path.len], path);
    ident.binary_path_len = path.len;
}
