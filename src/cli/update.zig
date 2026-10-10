const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const InstallSource = enum {
    manual,
    development,
    homebrew,
    scoop,
    npm_global,
    npm_local,
    npx_cache,
};

pub fn run(allocator: std.mem.Allocator, io: Io) !void {
    const executable_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(executable_path);

    const source = detectInstallSource(executable_path, builtin.os.tag);
    if (source == .npx_cache) {
        std.debug.print("cr update: this copy was launched by npx; rerun `npx --yes @keton-id/cora@latest`.\n", .{});
        return;
    }
    if (source == .development) {
        std.debug.print("cr update: local build detected; install a release build before updating.\n", .{});
        return;
    }

    if (builtin.os.tag == .windows) {
        try queueWindowsUpdate(allocator, io, executable_path, source);
        return;
    }
    try updatePosix(io, executable_path, source);
}

fn detectInstallSource(path: []const u8, os: std.Target.Os.Tag) InstallSource {
    if (containsPath(path, "/zig-out/", os == .windows) or
        containsPath(path, "/.zig-cache/", os == .windows))
    {
        return .development;
    }
    if ((os == .macos or os == .linux) and containsPath(path, "/Cellar/cora/", false)) return .homebrew;
    if (os == .windows and containsPath(path, "\\scoop\\apps\\cora\\", true)) return .scoop;
    if (containsPath(path, "/_npx/", os == .windows)) return .npx_cache;

    if (containsPath(path, "/node_modules/@keton-id/cora-", os == .windows)) {
        if (containsPath(path, "/lib/node_modules/@keton-id/", os == .windows) or
            containsPath(path, "/npm/node_modules/@keton-id/", os == .windows))
        {
            return .npm_global;
        }
        return .npm_local;
    }
    return .manual;
}

fn containsPath(path: []const u8, needle: []const u8, windows: bool) bool {
    if (needle.len > path.len) return false;
    for (0..path.len - needle.len + 1) |start| {
        var matches = true;
        for (path[start .. start + needle.len], needle) |actual, expected| {
            const same = if (windows and (actual == '/' or actual == '\\') and (expected == '/' or expected == '\\'))
                true
            else if (windows)
                std.ascii.toLower(actual) == std.ascii.toLower(expected)
            else
                actual == expected;
            if (!same) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

fn updatePosix(
    io: Io,
    executable_path: []const u8,
    source: InstallSource,
) !void {
    switch (source) {
        .homebrew => {
            std.debug.print("cr update: updating the Homebrew installation.\n", .{});
            try runAndWait(io, &.{ "brew", "upgrade", "cora" }, null);
        },
        .npm_global => {
            std.debug.print("cr update: updating the global npm installation.\n", .{});
            try runAndWait(io, &.{ "npm", "install", "--global", "@keton-id/cora@latest" }, null);
        },
        .npm_local => {
            const project_root = npmProjectRoot(executable_path, false) orelse return error.InvalidInstallPath;
            std.debug.print("cr update: updating the npm project installation.\n", .{});
            try runAndWait(io, &.{ "npm", "install", "--prefix", project_root, "@keton-id/cora@latest" }, null);
        },
        .manual => {
            const install_dir = std.fs.path.dirname(executable_path) orelse return error.InvalidInstallPath;
            const command = "set -eu; tmp=$(mktemp); trap 'rm -f \"$tmp\"' EXIT INT TERM; curl -fsSL https://raw.githubusercontent.com/keton-id/cora/main/install.sh -o \"$tmp\"; sh \"$tmp\" --bindir \"$1\"";
            std.debug.print("cr update: installing the latest stable release to {s}.\n", .{install_dir});
            try runAndWait(io, &.{ "sh", "-c", command, "cr update", install_dir }, null);
        },
        .scoop, .npx_cache, .development => unreachable,
    }
    std.debug.print("cr update: update command completed.\n", .{});
}

fn queueWindowsUpdate(
    allocator: std.mem.Allocator,
    io: Io,
    executable_path: []const u8,
    source: InstallSource,
) !void {
    if (source == .npx_cache) unreachable;
    const install_dir = switch (source) {
        .development => unreachable,
        .npm_local => npmProjectRoot(executable_path, true) orelse return error.InvalidInstallPath,
        else => std.fs.path.dirname(executable_path) orelse return error.InvalidInstallPath,
    };
    const command = switch (source) {
        .scoop => "scoop update cora",
        .npm_global => "npm install --global '@keton-id/cora@latest'",
        .npm_local, .manual => null,
        .homebrew => unreachable,
        .development => unreachable,
        .npx_cache => unreachable,
    };
    const quoted_dir = try quotePowerShell(allocator, install_dir);
    defer allocator.free(quoted_dir);
    const action = if (command) |value|
        try allocator.dupe(u8, value)
    else if (source == .npm_local)
        try std.fmt.allocPrint(allocator, "npm install --prefix {s} '@keton-id/cora@latest'", .{quoted_dir})
    else
        try std.fmt.allocPrint(
            allocator,
            "$source = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/keton-id/cora/main/install.ps1'; & ([scriptblock]::Create($source)) -BinDir {s}",
            .{quoted_dir},
        );
    defer allocator.free(action);

    const pid = std.os.windows.GetCurrentProcessId();
    const log_name = try std.fmt.allocPrint(allocator, "cora-update-{d}.log", .{pid});
    defer allocator.free(log_name);
    const quoted_log = try quotePowerShell(allocator, log_name);
    defer allocator.free(quoted_log);
    const script = try std.fmt.allocPrint(
        allocator,
        "$parent = {d}; $log = Join-Path $env:TEMP {s}; try {{ Wait-Process -Id $parent -ErrorAction Stop }} catch {{}}; try {{ {s} *>&1 | Out-File -FilePath $log -Append -Encoding utf8 }} catch {{ $_ | Out-File -FilePath $log -Append -Encoding utf8 }}",
        .{ pid, quoted_log, action },
    );
    defer allocator.free(script);

    const args = [_][]const u8{
        "powershell.exe",
        "-NoProfile",
        "-NonInteractive",
        "-WindowStyle",
        "Hidden",
        "-Command",
        script,
    };
    _ = try std.process.spawn(io, .{
        .argv = &args,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    });
    std.debug.print("cr update: update queued for after this process exits; see %TEMP%\\{s} for the result.\n", .{log_name});
}

fn quotePowerShell(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try output.appendSlice(allocator, "''");
        } else {
            try output.append(allocator, byte);
        }
    }
    try output.append(allocator, '\'');
    return output.toOwnedSlice(allocator);
}

fn npmProjectRoot(path: []const u8, windows: bool) ?[]const u8 {
    const marker = "node_modules";
    if (path.len <= marker.len) return null;
    for (0..path.len - marker.len) |start| {
        if (!containsPath(path[start .. start + marker.len], marker, windows)) continue;
        if (start == 0) continue;
        const before = path[start - 1];
        if ((windows and before != '/' and before != '\\') or (!windows and before != '/')) continue;
        var end = start - 1;
        while (end > 0 and (path[end - 1] == '/' or path[end - 1] == '\\')) : (end -= 1) {}
        if (end == 0) return null;
        return path[0..end];
    }
    return null;
}

fn runAndWait(io: Io, argv: []const []const u8, cwd: ?[]const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.UpdateFailed,
        else => return error.UpdateFailed,
    }
}

test "detects Cora package manager installations without matching ordinary paths" {
    try std.testing.expectEqual(InstallSource.homebrew, detectInstallSource("/opt/homebrew/Cellar/cora/0.11.0/bin/cr", .macos));
    try std.testing.expectEqual(InstallSource.homebrew, detectInstallSource("/home/linuxbrew/.linuxbrew/Cellar/cora/0.11.0/bin/cr", .linux));
    try std.testing.expectEqual(InstallSource.scoop, detectInstallSource("C:\\Users\\test\\scoop\\apps\\cora\\current\\cr.exe", .windows));
    try std.testing.expectEqual(InstallSource.npm_global, detectInstallSource("/usr/local/lib/node_modules/@keton-id/cora-linux-x64/bin/cr", .linux));
    try std.testing.expectEqual(InstallSource.npm_local, detectInstallSource("/work/project/node_modules/@keton-id/cora-linux-x64/bin/cr", .linux));
    try std.testing.expectEqual(InstallSource.npm_global, detectInstallSource("C:\\Users\\test\\AppData\\Roaming\\npm\\node_modules\\@keton-id\\cora-win32-x64\\bin\\cr.exe", .windows));
    try std.testing.expectEqual(InstallSource.npx_cache, detectInstallSource("/home/test/.npm/_npx/hash/node_modules/@keton-id/cora-linux-x64/bin/cr", .linux));
    try std.testing.expectEqual(InstallSource.manual, detectInstallSource("/home/test/.local/bin/cr", .linux));
    try std.testing.expectEqual(InstallSource.development, detectInstallSource("/work/cora/zig-out/bin/cr", .linux));
    try std.testing.expectEqualStrings("/work/project", npmProjectRoot("/work/project/node_modules/@keton-id/cora-linux-x64/bin/cr", false).?);
    try std.testing.expectEqualStrings("C:\\work\\project", npmProjectRoot("C:\\work\\project\\node_modules\\@keton-id\\cora-win32-x64\\bin\\cr.exe", true).?);
}
