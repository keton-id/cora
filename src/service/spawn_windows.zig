//! Windows `CreateProcessW` helpers used by two distinct code paths:
//!
//! 1. `spawnDetachedForeground` — daemonize the Cora service on
//!    Windows by re-execing `cr unlock --foreground` as a detached
//!    child, piping the passphrase across stdin once. POSIX uses
//!    fork() + setsid() + stdio redirection (`src/main.zig`
//!    cmdUnlock); Windows has no fork, so we go through CreateProcessW
//!    with `DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP`.
//!
//! 2. `spawnInheritingStdio` + `waitForExit` — used by the service to
//!    spawn `cr exec`'s target binary while inheriting the caller's
//!    stdin/stdout/stderr handles (already duplicated into the daemon
//!    process by `pipe_windows.duplicateClientStdio`). This is the
//!    Windows counterpart to POSIX `SCM_RIGHTS` fd passing — the child
//!    writes directly to the caller's terminal/pipes instead of the
//!    daemon's `NUL` stdio.

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

extern "kernel32" fn WaitForSingleObject(
    hHandle: HANDLE,
    dwMilliseconds: DWORD,
) callconv(.winapi) DWORD;

extern "kernel32" fn GetExitCodeProcess(
    hProcess: HANDLE,
    lpExitCode: *DWORD,
) callconv(.winapi) BOOL;

pub const INFINITE: DWORD = 0xFFFFFFFF;

pub const Spawned = struct {
    pid: u32,
};

pub const ChildProcess = struct {
    /// Process handle for `WaitForSingleObject` + `GetExitCodeProcess`.
    /// Caller owns the handle and must close it (or use `waitForExit`,
    /// which closes it as part of waiting).
    process: HANDLE,
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

/// Quote a single argv entry per the Windows command-line rules
/// (MSDN "Parsing C++ Command-Line Arguments"). Backslashes and the
/// quote character itself are doubled only when they precede a quote;
/// otherwise they are passed through. Always wraps the result in
/// double quotes so embedded whitespace stays a single token.
fn appendQuotedArg(out: *std.ArrayList(u8), allocator: std.mem.Allocator, arg: []const u8) !void {
    try out.append(allocator, '"');
    var i: usize = 0;
    while (i < arg.len) {
        var n_back: usize = 0;
        while (i < arg.len and arg[i] == '\\') : (i += 1) n_back += 1;
        if (i == arg.len) {
            // Trailing backslashes — double each so the closing quote
            // is not consumed as an escape.
            for (0..n_back * 2) |_| try out.append(allocator, '\\');
        } else if (arg[i] == '"') {
            for (0..n_back * 2 + 1) |_| try out.append(allocator, '\\');
            try out.append(allocator, '"');
            i += 1;
        } else {
            for (0..n_back) |_| try out.append(allocator, '\\');
            try out.append(allocator, arg[i]);
            i += 1;
        }
    }
    try out.append(allocator, '"');
}

/// Build a NUL-terminated UTF-16 command line from a UTF-8 argv array,
/// applying the Windows quoting rules so the child's CommandLineToArgvW
/// sees the same argv tokenization. Caller owns the returned slice.
pub fn buildCommandLineWide(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) ![]u16 {
    var utf8 = std.ArrayList(u8).empty;
    defer utf8.deinit(allocator);
    for (argv, 0..) |a, i| {
        if (i != 0) try utf8.append(allocator, ' ');
        try appendQuotedArg(&utf8, allocator, a);
    }

    var wide = std.ArrayList(u16).empty;
    errdefer wide.deinit(allocator);
    try wide.ensureTotalCapacity(allocator, utf8.items.len + 1);
    // utf8ToUtf16Le writes exactly N u16 for N-byte ASCII input; allocate
    // generously to cover multi-byte sequences.
    try wide.resize(allocator, utf8.items.len * 2 + 1);
    const n = try std.unicode.utf8ToUtf16Le(wide.items, utf8.items);
    wide.items[n] = 0;
    wide.shrinkRetainingCapacity(n + 1);
    return wide.toOwnedSlice(allocator);
}

pub const EnvPair = struct { name: []const u8, value: []const u8 };

/// Build a Windows-style UTF-16 environment block (`KEY=VAL\0KEY=VAL\0\0`)
/// from a flat list of (name, value) pairs. Caller owns the returned
/// slice and is responsible for `secureZero`-ing it once the spawn is
/// done — the block carries secret values verbatim.
pub fn buildEnvBlockWide(
    allocator: std.mem.Allocator,
    pairs: []const EnvPair,
) ![]u16 {
    var utf8 = std.ArrayList(u8).empty;
    defer utf8.deinit(allocator);
    for (pairs) |p| {
        try utf8.appendSlice(allocator, p.name);
        try utf8.append(allocator, '=');
        try utf8.appendSlice(allocator, p.value);
        try utf8.append(allocator, 0);
    }
    try utf8.append(allocator, 0); // double NUL terminator

    var wide: []u16 = try allocator.alloc(u16, utf8.items.len);
    errdefer allocator.free(wide);
    const n = try std.unicode.utf8ToUtf16Le(wide, utf8.items);
    if (n != utf8.items.len) {
        // utf8ToUtf16Le returns the count of u16s; for our pure-ASCII
        // env vars this matches the input length. If a value contained
        // multi-byte UTF-8 we'd need to resize — env block expects the
        // exact count, no trailing slop.
        const resized = try allocator.realloc(wide, n);
        wide = resized;
    }
    return wide;
}

/// Spawn a child process inheriting three already-duplicated stdio
/// handles. The handles must live in the *current* process (the
/// service) — typically produced by `pipe_windows.duplicateClientStdio`
/// after `DuplicateHandle`-ing the caller's `GetStdHandle` values into
/// the daemon.
///
/// `cmdline_z` must be a null-terminated UTF-16 command line. The
/// `exe_wide` path is used as `lpApplicationName`; argv resolution is
/// the caller's responsibility (the policy layer resolves and rewrites
/// argv[0] before this point).
///
/// `env_block_wide`, when non-null, must be a Windows wide-character
/// environment block: a sequence of `KEY=VALUE\0` UTF-16 entries
/// terminated by an extra `\0`. Pass `null` to inherit the daemon's
/// environment unchanged.
///
/// On success the returned `ChildProcess.process` handle is **open and
/// owned by the caller** — pass it to `waitForExit` or close it
/// manually.
///
/// The three stdio handles are **not** closed by this function.
/// The caller is expected to close them after `CreateProcessW`
/// returns (regardless of success), because the kernel duplicates
/// them into the child as part of the spawn.
pub fn spawnInheritingStdio(
    exe_wide: LPCWSTR,
    cmdline_z: LPWSTR,
    env_block_wide: LPVOID,
    stdio: [3]HANDLE,
) !ChildProcess {
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
        .hStdInput = stdio[0],
        .hStdOutput = stdio[1],
        .hStdError = stdio[2],
    };

    var pi = std.mem.zeroes(PROCESS_INFORMATION);

    const flags: DWORD = if (env_block_wide != null) CREATE_UNICODE_ENVIRONMENT else 0;

    const ok = CreateProcessW(
        exe_wide,
        cmdline_z,
        null,
        null,
        1, // bInheritHandles — required for the stdio handles to cross
        flags,
        env_block_wide,
        null,
        &si,
        &pi,
    );

    if (ok == 0) return error.CreateProcessFailed;

    _ = CloseHandle(pi.hThread);
    return .{ .process = pi.hProcess, .pid = pi.dwProcessId };
}

/// Wait for a child spawned by `spawnInheritingStdio` to exit, return
/// its exit code, and close the process handle. Returns the exit code
/// even when it is non-zero; only infrastructure failures (the wait
/// itself, or reading the exit code) bubble as errors.
pub fn waitForExit(child: ChildProcess) !u32 {
    _ = WaitForSingleObject(child.process, INFINITE);
    var code: DWORD = 0;
    if (GetExitCodeProcess(child.process, &code) == 0) {
        _ = CloseHandle(child.process);
        return error.GetExitCodeFailed;
    }
    _ = CloseHandle(child.process);
    return code;
}

test "spawn_windows compiles" {
    // Type-level sanity: forces the externs above through the type
    // checker on cross-compiled Windows builds without invoking them.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const _spawn = &spawnDetachedForeground;
    _ = _spawn;
    const _inherit = &spawnInheritingStdio;
    _ = _inherit;
    const _wait = &waitForExit;
    _ = _wait;
}
