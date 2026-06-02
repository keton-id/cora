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
extern "kernel32" fn GetNamedPipeClientProcessId(Pipe: HANDLE, ClientProcessId: PDWORD) callconv(.winapi) BOOL;

/// Tier 2: the service-side Named Pipe HANDLE is passed in. The kernel
/// reports the connected client's PID via `GetNamedPipeClientProcessId`;
/// we then resolve the binary path with `QueryFullProcessImageNameW`
/// against that PID. Matches the POSIX `SO_PEERCRED` + `readlink
/// /proc/<pid>/exe` chain.
///
/// The argument type stays `posix.fd_t` because on Windows that type
/// is itself a HANDLE — see `std.posix.fd_t` and `service.zig`'s
/// `identity.verify(stream.socket.handle)` call site. After Tier 2
/// rewires the transport to Named Pipes, the same field will carry
/// the pipe handle and this code remains correct.
pub fn verify(pipe_handle: std.posix.fd_t) CoraError!CallerIdentity {
    var pid: DWORD = 0;
    if (GetNamedPipeClientProcessId(pipe_handle, &pid) == 0) return CoraError.CallerNotAllowed;
    return lookupByPid(@intCast(pid));
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

test "verify rejects an invalid handle (Windows-only)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // The pseudo-handle -1 is documented as INVALID_HANDLE_VALUE; it is
    // not a Named Pipe in the connected state, so GetNamedPipeClientProcessId
    // must fail. This is the regression rail for "no caller verified ==
    // reject" — the Tier 1 stub used to *accept* the call by always
    // returning the server's own PID.
    const invalid: std.posix.fd_t = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
    try std.testing.expectError(CoraError.CallerNotAllowed, verify(invalid));
}
