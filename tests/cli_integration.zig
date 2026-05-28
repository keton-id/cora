//! End-to-end CLI integration tests.
//!
//! These tests spawn the installed `cr` binary as a subprocess and exercise
//! operator-facing flows (init, policy mutations, secret mutations). They
//! complement the unit tests by locking the contract at the CLI boundary,
//! where prior regressions silently passed unit tests.
//!
//! The binary path is injected at build time via `integration_options`.
//! `zig build test` depends on the install step, so the binary is always
//! present before these tests run.

const std = @import("std");
const Io = std.Io;
const opts = @import("integration_options");

const RunResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }

    fn exitOk(self: RunResult) bool {
        return switch (self.term) {
            .exited => |c| c == 0,
            else => false,
        };
    }
};

/// Spawn the installed `cr` binary with `args`, cwd at `cwd_dir`. If
/// `stdin_input` is non-empty, it is written to the child's stdin and the
/// pipe is closed before draining stdout/stderr. Caller owns
/// `result.stdout` and `result.stderr`.
fn runCr(
    allocator: std.mem.Allocator,
    io: Io,
    cwd_dir: Io.Dir,
    args: []const []const u8,
    stdin_input: []const u8,
) !RunResult {
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    try argv_list.append(allocator, opts.cr_bin_path);
    try argv_list.appendSlice(allocator, args);

    var child = try std.process.spawn(io, .{
        .argv = argv_list.items,
        .cwd = .{ .dir = cwd_dir },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer child.kill(io);

    if (stdin_input.len > 0) {
        try child.stdin.?.writeStreamingAll(io, stdin_input);
    }
    child.stdin.?.close(io);
    child.stdin = null;

    var mr_buf: Io.File.MultiReader.Buffer(2) = undefined;
    var mr: Io.File.MultiReader = undefined;
    mr.init(allocator, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();

    while (mr.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try mr.checkAnyError();

    const term = try child.wait(io);
    const stdout_slice = try mr.toOwnedSlice(0);
    errdefer allocator.free(stdout_slice);
    const stderr_slice = try mr.toOwnedSlice(1);
    return .{ .term = term, .stdout = stdout_slice, .stderr = stderr_slice };
}

test "cr binary is installed at expected path" {
    var dir = try Io.Dir.cwd().openDir(std.testing.io, std.fs.path.dirname(opts.cr_bin_path).?, .{});
    defer dir.close(std.testing.io);
    const basename = std.fs.path.basename(opts.cr_bin_path);
    try dir.access(std.testing.io, basename, .{});
}

const passphrase = "correct horse battery staple";
const pass_line = passphrase ++ "\n";
const init_stdin = passphrase ++ "\n" ++ passphrase ++ "\n";

test "cr init writes encrypted cora.zon to cwd" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{ "init", "cora.zon" }, init_stdin);
    defer res.deinit(allocator);

    try std.testing.expect(res.exitOk());

    // File must exist and start with the magic header "CORA".
    const blob = try tmp.dir.readFileAlloc(io, "cora.zon", allocator, .limited(64 * 1024));
    defer allocator.free(blob);
    try std.testing.expect(blob.len > 4);
    try std.testing.expectEqualStrings("CORA", blob[0..4]);
}

fn initFixture(allocator: std.mem.Allocator, io: Io, dir: Io.Dir) !void {
    var res = try runCr(allocator, io, dir, &.{ "init", "cora.zon" }, init_stdin);
    defer res.deinit(allocator);
    try std.testing.expect(res.exitOk());
}

fn policyShow(allocator: std.mem.Allocator, io: Io, dir: Io.Dir) !RunResult {
    return runCr(allocator, io, dir, &.{ "policy", "show" }, pass_line);
}

test "secrets set preserves policy (regression: finding 1)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try initFixture(allocator, io, tmp.dir);

    {
        var r = try runCr(allocator, io, tmp.dir, &.{ "policy", "allow", "/bin/echo" }, pass_line);
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
    }
    {
        var r = try runCr(allocator, io, tmp.dir, &.{ "policy", "task", "add", "demo", "API_KEY" }, pass_line);
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
    }
    {
        // `cr secrets set` prompts for passphrase then value.
        var r = try runCr(allocator, io, tmp.dir, &.{ "secrets", "set", "API_KEY" }, pass_line ++ "sk-aaa\n");
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
    }

    var show = try policyShow(allocator, io, tmp.dir);
    defer show.deinit(allocator);
    try std.testing.expect(show.exitOk());

    // cmdPolicy.show prints to stderr via std.debug.print.
    try std.testing.expect(std.mem.indexOf(u8, show.stderr, "allowed_callers (1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, show.stderr, "/bin/echo") != null);
    try std.testing.expect(std.mem.indexOf(u8, show.stderr, "tasks (1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, show.stderr, "demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, show.stderr, "API_KEY") != null);
}

test "policy allow preserves tasks (regression: finding 2)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try initFixture(allocator, io, tmp.dir);

    {
        var r = try runCr(allocator, io, tmp.dir, &.{ "policy", "task", "add", "demo", "API_KEY" }, pass_line);
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
    }
    {
        var r = try runCr(allocator, io, tmp.dir, &.{ "policy", "allow", "/bin/echo" }, pass_line);
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
    }

    var show = try policyShow(allocator, io, tmp.dir);
    defer show.deinit(allocator);
    try std.testing.expect(show.exitOk());

    try std.testing.expect(std.mem.indexOf(u8, show.stderr, "tasks (1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, show.stderr, "demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, show.stderr, "allowed_callers (1)") != null);
}
