const std = @import("std");
const builtin = @import("builtin");
const CoraError = @import("../error.zig").CoraError;

pub const max_path_len: usize = 1024;

pub const CallerIdentity = struct {
    pid: i32,
    uid: u32,
    binary_path_buf: [max_path_len]u8 = undefined,
    binary_path_len: usize = 0,

    pub fn path(self: *const CallerIdentity) []const u8 {
        return self.binary_path_buf[0..self.binary_path_len];
    }
};

pub fn verify(fd: std.posix.fd_t) CoraError!CallerIdentity {
    return switch (builtin.os.tag) {
        .linux => @import("linux.zig").verify(fd),
        .macos, .ios, .tvos, .watchos, .visionos => @import("macos.zig").verify(fd),
        .windows => @import("windows.zig").verify(fd),
        else => CoraError.InvalidConfig,
    };
}

pub fn lookupByPid(pid: i32) CoraError!CallerIdentity {
    return switch (builtin.os.tag) {
        .linux => @import("linux.zig").lookupByPid(pid),
        .macos, .ios, .tvos, .watchos, .visionos => @import("macos.zig").lookupByPid(pid),
        .windows => @import("windows.zig").lookupByPid(pid),
        else => CoraError.InvalidConfig,
    };
}

test "CallerIdentity path slice" {
    var c = CallerIdentity{ .pid = 1, .uid = 0 };
    const p = "/bin/cat";
    @memcpy(c.binary_path_buf[0..p.len], p);
    c.binary_path_len = p.len;
    try std.testing.expectEqualStrings("/bin/cat", c.path());
}

test "lookupByPid finds own binary" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const my_pid: i32 = @intCast(std.c.getpid());
    const ident = try lookupByPid(my_pid);
    try std.testing.expect(ident.binary_path_len > 0);
}
