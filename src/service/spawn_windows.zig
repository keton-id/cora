//! Daemonize the Cora service on Windows by spawning the foreground
//! code path as a detached child process.
//!
//! POSIX uses fork() + setsid() + stdio redirection (`src/main.zig`
//! cmdUnlock). Windows has no fork; instead we re-exec `cr unlock
//! --foreground` via `CreateProcessW` with `DETACHED_PROCESS |
//! CREATE_NEW_PROCESS_GROUP` and pipe the passphrase across stdin
//! exactly once. The child's foreground-mode code reads from stdin
//! via the existing `readSecret` path (`main.zig`), then closes its
//! end of the pipe and proceeds normally.

const std = @import("std");
const builtin = @import("builtin");

pub const HANDLE = *anyopaque;
pub const BOOL = i32;
pub const DWORD = u32;
pub const LPDWORD = *u32;
pub const LPCWSTR = [*:0]const u16;
pub const LPWSTR = [*:0]u16;
pub const LPCVOID = *const anyopaque;
pub const LPVOID = ?*anyopaque;
pub const LPSECURITY_ATTRIBUTES = ?*anyopaque;

pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

pub const STARTF_USESTDHANDLES: DWORD = 0x00000100;
pub const HANDLE_FLAG_INHERIT: DWORD = 0x00000001;
pub const DETACHED_PROCESS: DWORD = 0x00000008;
pub const CREATE_NEW_PROCESS_GROUP: DWORD = 0x00000200;
pub const CREATE_UNICODE_ENVIRONMENT: DWORD = 0x00000400;

// SECURITY_ATTRIBUTES with bInheritHandle=1 used to make the read
// pipe handle inheritable by the child.
const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD,
    lpSecurityDescriptor: LPVOID,
    bInheritHandle: BOOL,
};

const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?LPWSTR,
    lpDesktop: ?LPWSTR,
    lpTitle: ?LPWSTR,
    dwX: DWORD,
    dwY: DWORD,
    dwXSize: DWORD,
    dwYSize: DWORD,
    dwXCountChars: DWORD,
    dwYCountChars: DWORD,
    dwFillAttribute: DWORD,
    dwFlags: DWORD,
    wShowWindow: u16,
    cbReserved2: u16,
    lpReserved2: ?*u8,
    hStdInput: ?HANDLE,
    hStdOutput: ?HANDLE,
    hStdError: ?HANDLE,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

extern "kernel32" fn CreatePipe(
    hReadPipe: *HANDLE,
    hWritePipe: *HANDLE,
    lpPipeAttributes: ?*SECURITY_ATTRIBUTES,
    nSize: DWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn SetHandleInformation(
    hObject: HANDLE,
    dwMask: DWORD,
    dwFlags: DWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?LPCWSTR,
    lpCommandLine: ?LPWSTR,
    lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
    lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: LPVOID,
    lpCurrentDirectory: ?LPCWSTR,
    lpStartupInfo: *STARTUPINFOW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;

extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: LPCVOID,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: ?LPDWORD,
    lpOverlapped: LPVOID,
) callconv(.winapi) BOOL;

extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

extern "kernel32" fn GetModuleFileNameW(
    hModule: ?HANDLE,
    lpFilename: [*]u16,
    nSize: DWORD,
) callconv(.winapi) DWORD;

extern "kernel32" fn GetCommandLineW() callconv(.winapi) LPWSTR;

pub const Spawned = struct {
    pid: u32,
};

/// Resolve the absolute path of the currently-running `cr.exe`. Used so
/// the daemon child re-execs the same binary it was invoked from rather
/// than relying on PATH lookup (which could shadow the trust chain).
fn currentExecutableWide(buf: *[512]u16) ![:0]const u16 {
    const n = GetModuleFileNameW(null, buf, @intCast(buf.len));
    if (n == 0 or n >= buf.len) return error.GetModuleFileName;
    buf[n] = 0;
    return buf[0..n :0];
}

/// Build the wide command-line `cr.exe unlock --foreground`. The
/// Windows command-line is a single string, not an argv array; we
/// quote the executable path defensively in case it contains spaces.
fn buildCommandLine(allocator: std.mem.Allocator, exe_wide: [:0]const u16) ![]u16 {
    const suffix_utf8 = "\" unlock --foreground";
    var out = std.ArrayList(u16).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    try out.appendSlice(allocator, exe_wide);
    var sb: [64]u16 = undefined;
    const sn = try std.unicode.utf8ToUtf16Le(&sb, suffix_utf8);
    try out.appendSlice(allocator, sb[0..sn]);
    try out.append(allocator, 0);
    return out.toOwnedSlice(allocator);
}

/// Spawn `cr.exe unlock --foreground` as a detached child, pipe the
/// passphrase across stdin once, close the write end, and return the
/// child's PID. The caller is responsible for `secureZero`-ing the
/// passphrase buffer after we return.
pub fn spawnDetachedForeground(
    allocator: std.mem.Allocator,
    passphrase: []const u8,
) !Spawned {
    var exe_buf: [512]u16 = undefined;
    const exe_wide = try currentExecutableWide(&exe_buf);

    const cmdline = try buildCommandLine(allocator, exe_wide);
    defer allocator.free(cmdline);

    var sa = SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = 1,
    };

    var read_h: HANDLE = INVALID_HANDLE_VALUE;
    var write_h: HANDLE = INVALID_HANDLE_VALUE;
    if (CreatePipe(&read_h, &write_h, &sa, 0) == 0) return error.CreatePipeFailed;

    // Make sure ONLY the read end is inherited by the child. The write
    // end stays parent-private so the child cannot accidentally read
    // back what it wrote.
    if (SetHandleInformation(write_h, HANDLE_FLAG_INHERIT, 0) == 0) {
        _ = CloseHandle(read_h);
        _ = CloseHandle(write_h);
        return error.SetHandleInformationFailed;
    }

    var si = STARTUPINFOW{
        .cb = @sizeOf(STARTUPINFOW),
        .lpReserved = null,
        .lpDesktop = null,
        .lpTitle = null,
        .dwX = 0,
        .dwY = 0,
        .dwXSize = 0,
        .dwYSize = 0,
        .dwXCountChars = 0,
        .dwYCountChars = 0,
        .dwFillAttribute = 0,
        .dwFlags = STARTF_USESTDHANDLES,
        .wShowWindow = 0,
        .cbReserved2 = 0,
        .lpReserved2 = null,
        .hStdInput = read_h,
        .hStdOutput = null,
        .hStdError = null,
    };

    var pi = std.mem.zeroes(PROCESS_INFORMATION);

    const ok = CreateProcessW(
        exe_wide,
        @ptrCast(cmdline.ptr),
        null,
        null,
        1, // bInheritHandles — required for the stdin pipe to cross
        DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP,
        null,
        null,
        &si,
        &pi,
    );

    // Read end is now owned by the child. Close our copy regardless of
    // whether CreateProcessW succeeded — leaving it open here would
    // prevent the child from observing EOF when we close our write end.
    _ = CloseHandle(read_h);

    if (ok == 0) {
        _ = CloseHandle(write_h);
        return error.CreateProcessFailed;
    }

    // Hand the passphrase to the child once, then drop the pipe.
    var written: DWORD = 0;
    if (WriteFile(write_h, passphrase.ptr, @intCast(passphrase.len), &written, null) == 0) {
        _ = CloseHandle(write_h);
        _ = CloseHandle(pi.hProcess);
        _ = CloseHandle(pi.hThread);
        return error.WritePassphraseFailed;
    }
    const nl: [1]u8 = .{'\n'};
    var nl_written: DWORD = 0;
    _ = WriteFile(write_h, &nl, 1, &nl_written, null);
    _ = CloseHandle(write_h);
    _ = CloseHandle(pi.hThread);
    _ = CloseHandle(pi.hProcess);

    return .{ .pid = pi.dwProcessId };
}

test "spawn_windows compiles" {
    // Type-level sanity: forces the externs above through the type
    // checker on cross-compiled Windows builds without invoking them.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const _spawn = &spawnDetachedForeground;
    _ = _spawn;
}
