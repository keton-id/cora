//! Thin Zig wrappers over the Win32 Named Pipe API used by the Cora
//! service on Windows.
//!
//! AF_UNIX is implemented on Windows 10+ but does not expose peer
//! credentials. Named Pipes do — `GetNamedPipeClientProcessId` returns
//! the kernel-verified PID of the connected client — which is what
//! Tier 2 wants. The wire framing in `proto.zig` is unchanged; only the
//! transport changes.
//!
//! Pipe naming: `\\.\pipe\cora-<username>`. The trailing `<username>`
//! segment partitions instances per Windows user so concurrent
//! sessions on the same machine do not collide, mirroring the per-uid
//! socket path on POSIX (`/tmp/cora-<uid>.sock`).
//!
//! DACL: the pipe is created with the default security descriptor.
//! That grants access to the creating user's token (and SYSTEM/admins),
//! same as the inherited NTFS ACL on the Tier-1 AF_UNIX socket path.
//! What promotes us to Tier 2 is the *kernel-verified peer PID*, not
//! the DACL — the policy gate at `service.zig` still filters by binary
//! path the same way POSIX does after `SO_PEERCRED`.

const std = @import("std");
const builtin = @import("builtin");

pub const HANDLE = *anyopaque;
pub const BOOL = i32;
pub const DWORD = u32;
pub const LPDWORD = *u32;
pub const LPCWSTR = [*:0]const u16;
pub const LPVOID = ?*anyopaque;
pub const LPSECURITY_ATTRIBUTES = ?*anyopaque;
pub const LPOVERLAPPED = ?*anyopaque;

pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

// CreateNamedPipeW dwOpenMode
pub const PIPE_ACCESS_DUPLEX: DWORD = 0x00000003;
pub const FILE_FLAG_FIRST_PIPE_INSTANCE: DWORD = 0x00080000;

// CreateNamedPipeW dwPipeMode
pub const PIPE_TYPE_BYTE: DWORD = 0x00000000;
pub const PIPE_READMODE_BYTE: DWORD = 0x00000000;
pub const PIPE_WAIT: DWORD = 0x00000000;
pub const PIPE_REJECT_REMOTE_CLIENTS: DWORD = 0x00000008;

// CreateFileW dwDesiredAccess
pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;

// CreateFileW dwCreationDisposition
pub const OPEN_EXISTING: DWORD = 3;

// CreateFileW dwFlagsAndAttributes
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x00000080;

// GetLastError
pub const ERROR_PIPE_BUSY: DWORD = 231;
pub const ERROR_PIPE_CONNECTED: DWORD = 535;
pub const ERROR_BROKEN_PIPE: DWORD = 109;
pub const ERROR_MORE_DATA: DWORD = 234;
pub const ERROR_INSUFFICIENT_BUFFER: DWORD = 122;

// Pipe sizing — small enough for our framed protocol (max 1 MB payload
// + 6 byte header). The kernel ringbuffer per direction.
pub const PIPE_BUFFER_SIZE: DWORD = 64 * 1024;
pub const PIPE_DEFAULT_TIMEOUT_MS: DWORD = 5000;

extern "kernel32" fn CreateNamedPipeW(
    lpName: LPCWSTR,
    dwOpenMode: DWORD,
    dwPipeMode: DWORD,
    nMaxInstances: DWORD,
    nOutBufferSize: DWORD,
    nInBufferSize: DWORD,
    nDefaultTimeOut: DWORD,
    lpSecurityAttributes: LPSECURITY_ATTRIBUTES,
) callconv(.winapi) HANDLE;

extern "kernel32" fn ConnectNamedPipe(
    hNamedPipe: HANDLE,
    lpOverlapped: LPOVERLAPPED,
) callconv(.winapi) BOOL;

extern "kernel32" fn DisconnectNamedPipe(hNamedPipe: HANDLE) callconv(.winapi) BOOL;

extern "kernel32" fn FlushFileBuffers(hFile: HANDLE) callconv(.winapi) BOOL;

extern "kernel32" fn GetNamedPipeClientProcessId(
    Pipe: HANDLE,
    ClientProcessId: LPDWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn CreateFileW(
    lpFileName: LPCWSTR,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: LPSECURITY_ATTRIBUTES,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: LPVOID,
) callconv(.winapi) HANDLE;

extern "kernel32" fn WaitNamedPipeW(lpNamedPipeName: LPCWSTR, nTimeOut: DWORD) callconv(.winapi) BOOL;

extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

extern "advapi32" fn GetUserNameW(lpBuffer: [*]u16, pcbBuffer: LPDWORD) callconv(.winapi) BOOL;

pub const PipeNameMaxUtf8: usize = 256;
pub const PipeNameMaxWide: usize = 256;

/// Write `\\.\pipe\cora-<user>` into `buf` as a UTF-8 string. Used for
/// log/debug output and to compose the wide variant in `defaultPipeNameWide`.
pub fn defaultPipeNameUtf8(buf: []u8) ![]u8 {
    var user_wide: [128]u16 = undefined;
    var user_len: DWORD = @intCast(user_wide.len);
    if (GetUserNameW(&user_wide, &user_len) == 0) return error.GetUserName;
    if (user_len == 0) return error.GetUserName;
    // GetUserNameW writes count including the null terminator; drop it.
    const wide_slice = user_wide[0 .. user_len - 1];
    var user_utf8: [256]u8 = undefined;
    const n = try std.unicode.utf16LeToUtf8(&user_utf8, wide_slice);
    return std.fmt.bufPrint(buf, "\\\\.\\pipe\\cora-{s}", .{user_utf8[0..n]});
}

/// Compose the UTF-16 NUL-terminated pipe path expected by CreateNamedPipeW
/// and CreateFileW. Writes into `buf` and returns the slice (without the
/// trailing null, which is still present at `buf[n]`).
pub fn defaultPipeNameWide(buf: *[PipeNameMaxWide]u16) ![:0]const u16 {
    var utf8_buf: [PipeNameMaxUtf8]u8 = undefined;
    const utf8 = try defaultPipeNameUtf8(&utf8_buf);
    if (utf8.len + 1 > buf.len) return error.PipeNameTooLong;
    const n = try std.unicode.utf8ToUtf16Le(buf, utf8);
    buf[n] = 0;
    return buf[0..n :0];
}

/// Create a new server-side Named Pipe instance with `FILE_FLAG_FIRST_PIPE_INSTANCE`
/// so a stale/duplicate service on the same name fails-closed at start
/// instead of silently shadowing.
pub fn createServerPipe(name_wide_z: [*:0]const u16) !HANDLE {
    const handle = CreateNamedPipeW(
        name_wide_z,
        PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
        1, // single outstanding instance — one client at a time, matches POSIX
        PIPE_BUFFER_SIZE,
        PIPE_BUFFER_SIZE,
        PIPE_DEFAULT_TIMEOUT_MS,
        null, // default DACL — see file header comment
    );
    if (@intFromPtr(handle) == @intFromPtr(INVALID_HANDLE_VALUE)) {
        return error.CreatePipeFailed;
    }
    return handle;
}

/// Wait for a client to connect to the server-side pipe. Returns once
/// either a client has called `CreateFileW` against the same name or
/// the call has been cancelled (closing the pipe handle from another
/// thread is the cancellation mechanism).
pub fn connectServer(handle: HANDLE) !void {
    const ok = ConnectNamedPipe(handle, null);
    if (ok != 0) return;
    const err = GetLastError();
    // ERROR_PIPE_CONNECTED is the documented "client already connected
    // by the time we called this" path; not an error in our model.
    if (err == ERROR_PIPE_CONNECTED) return;
    return error.ConnectPipeFailed;
}

/// Tear down the current client connection so the next `connectServer`
/// can wait for a new one. Equivalent to a UDS `accept` loop reset.
pub fn disconnectClient(handle: HANDLE) void {
    _ = FlushFileBuffers(handle);
    _ = DisconnectNamedPipe(handle);
}

/// Get the kernel-verified PID of the connected client. This is the
/// Tier 2 promotion point: the kernel inspects the open client handle
/// and reports its process ID. The caller is responsible for ensuring
/// `pipe_handle` is in the connected state (post-`connectServer`).
pub fn clientProcessId(pipe_handle: HANDLE) !u32 {
    var pid: DWORD = 0;
    if (GetNamedPipeClientProcessId(pipe_handle, &pid) == 0) return error.GetClientPidFailed;
    return pid;
}

/// Open a client-side handle to an existing server pipe. Returns
/// `error.PipeUnavailable` if no server is listening on the name —
/// callers use this as the "service not running" probe, just like
/// `connect()` failure is on POSIX.
///
/// Retries once via `WaitNamedPipeW` on `ERROR_PIPE_BUSY` because the
/// server is single-instance and a previous client may not have
/// disconnected yet when we attempt to connect.
pub fn connectClient(name_wide_z: [*:0]const u16) !HANDLE {
    var attempts: u8 = 0;
    while (true) : (attempts += 1) {
        const handle = CreateFileW(
            name_wide_z,
            GENERIC_READ | GENERIC_WRITE,
            0, // no sharing
            null,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (@intFromPtr(handle) != @intFromPtr(INVALID_HANDLE_VALUE)) return handle;
        const err = GetLastError();
        if (err == ERROR_PIPE_BUSY and attempts < 3) {
            _ = WaitNamedPipeW(name_wide_z, 2000);
            continue;
        }
        return error.PipeUnavailable;
    }
}

pub fn closeHandle(handle: HANDLE) void {
    _ = CloseHandle(handle);
}

test "defaultPipeNameUtf8 prefixes pipe namespace (Windows-only)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var buf: [PipeNameMaxUtf8]u8 = undefined;
    const name = try defaultPipeNameUtf8(&buf);
    try std.testing.expect(std.mem.startsWith(u8, name, "\\\\.\\pipe\\cora-"));
    try std.testing.expect(name.len > "\\\\.\\pipe\\cora-".len);
}

test "defaultPipeNameWide is null-terminated and round-trips (Windows-only)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var wide: [PipeNameMaxWide]u16 = undefined;
    const wide_slice = try defaultPipeNameWide(&wide);
    try std.testing.expect(wide_slice.len > 0);
    try std.testing.expectEqual(@as(u16, 0), wide[wide_slice.len]);

    var back: [PipeNameMaxUtf8]u8 = undefined;
    const n = try std.unicode.utf16LeToUtf8(&back, wide_slice);
    try std.testing.expect(std.mem.startsWith(u8, back[0..n], "\\\\.\\pipe\\cora-"));
}
