const std = @import("std");
const builtin = @import("builtin");
const CoraError = @import("../error.zig").CoraError;
const CallerIdentity = @import("identity.zig").CallerIdentity;
const max_path_len = @import("identity.zig").max_path_len;

const HANDLE = *anyopaque;
const BOOL = i32;
const DWORD = u32;
const PDWORD = *u32;
const LPWSTR = [*]u16;

const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;

extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn QueryFullProcessImageNameW(hProcess: HANDLE, dwFlags: DWORD, lpExeName: LPWSTR, lpdwSize: PDWORD) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;

/// Tier 1 preview: Windows AF_UNIX sockets do not expose peer PID, so this
/// returns the server's own identity. Caller verification on Windows
/// degenerates to "trust same-user filesystem ACL on the socket file".
/// Tier 2 will switch the Windows IPC backend to Named Pipes and use
/// GetNamedPipeClientProcessId for kernel-level peer verification.
pub fn verify(fd: std.posix.fd_t) CoraError!CallerIdentity {
    _ = fd;
    const own_pid: i32 = @intCast(GetCurrentProcessId());
    return lookupByPid(own_pid);
}

pub fn lookupByPid(pid: i32) CoraError!CallerIdentity {
    var ident = CallerIdentity{ .pid = pid, .uid = 0 };
    try fillPath(pid, &ident);
    return ident;
}

fn fillPath(pid: i32, ident: *CallerIdentity) CoraError!void {
    const h_opt = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, @intCast(pid));
    const h = h_opt orelse return CoraError.CallerNotAllowed;
    defer _ = CloseHandle(h);

    var wide_buf: [max_path_len]u16 = undefined;
    var size: DWORD = @intCast(wide_buf.len);
    if (QueryFullProcessImageNameW(h, 0, &wide_buf, &size) == 0) return CoraError.CallerNotAllowed;

    const wide_slice = wide_buf[0..@intCast(size)];
    const n = std.unicode.utf16LeToUtf8(&ident.binary_path_buf, wide_slice) catch
        return CoraError.CallerNotAllowed;
    ident.binary_path_len = n;
}

test "lookupByPid finds own binary on windows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const my_pid: i32 = @intCast(GetCurrentProcessId());
    const ident = try lookupByPid(my_pid);
    try std.testing.expect(ident.binary_path_len > 0);
}
