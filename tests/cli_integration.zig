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
const builtin = @import("builtin");
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

// --- Platform-guarded contracts -------------------------------------------
// The tests below pin behavior that is intentionally different per OS, so a
// silent drift on one platform cannot pass as success on the others. Each
// test runs on exactly one OS family and skips on the rest.

test "cr version advertises windows-preview tag (Windows-only)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{"version"}, "");
    defer res.deinit(allocator);
    try std.testing.expect(res.exitOk());
    const out = if (res.stdout.len > 0) res.stdout else res.stderr;
    try std.testing.expect(std.mem.indexOf(u8, out, "[windows-preview]") != null);
}

test "cr version omits windows-preview tag (POSIX-only)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{"version"}, "");
    defer res.deinit(allocator);
    try std.testing.expect(res.exitOk());
    const out = if (res.stdout.len > 0) res.stdout else res.stderr;
    try std.testing.expect(std.mem.indexOf(u8, out, "[windows-preview]") == null);
}

test "cr status surfaces windows-preview mode line (Windows-only)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Service is not running in this fresh tmp dir, so we hit the
    // "not running" branch — the mode line is appended unconditionally on
    // Windows so operators still see the trust-model disclaimer.
    var res = try runCr(allocator, io, tmp.dir, &.{"status"}, "");
    defer res.deinit(allocator);
    try std.testing.expect(res.exitOk());
    const out = if (res.stderr.len > 0) res.stderr else res.stdout;
    try std.testing.expect(std.mem.indexOf(u8, out, "mode: windows-preview") != null);
}

test "cr status omits windows-preview mode line (POSIX-only)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{"status"}, "");
    defer res.deinit(allocator);
    try std.testing.expect(res.exitOk());
    const out = if (res.stderr.len > 0) res.stderr else res.stdout;
    try std.testing.expect(std.mem.indexOf(u8, out, "mode: windows-preview") == null);
}

test "cr policy show emits windows-preview banner (Windows-only)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initFixture(allocator, io, tmp.dir);

    var show = try policyShow(allocator, io, tmp.dir);
    defer show.deinit(allocator);
    try std.testing.expect(show.exitOk());

    const out = if (show.stderr.len > 0) show.stderr else show.stdout;
    try std.testing.expect(std.mem.indexOf(u8, out, "warning: running in windows-preview") != null);
}

test "cr policy show omits windows-preview banner (POSIX-only)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initFixture(allocator, io, tmp.dir);

    var show = try policyShow(allocator, io, tmp.dir);
    defer show.deinit(allocator);
    try std.testing.expect(show.exitOk());

    const out = if (show.stderr.len > 0) show.stderr else show.stdout;
    try std.testing.expect(std.mem.indexOf(u8, out, "warning: running in windows-preview") == null);
}

test "cr version never emits sensitive-sub banner (cross-platform)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{"version"}, "");
    defer res.deinit(allocator);
    try std.testing.expect(res.exitOk());
    const out = if (res.stderr.len > 0) res.stderr else res.stdout;
    // Banner is only printed for sensitive subs; `version` is not one of
    // them on any platform.
    try std.testing.expect(std.mem.indexOf(u8, out, "warning: running in windows-preview") == null);
}

// --- Help / version conventions -------------------------------------------
// `cr help`, `cr --help`, `cr -h`, `cr --version`, `cr -V`, and per-sub
// `--help` must all be recognized and route their output to stdout (not
// stderr) so that `cr --help | grep foo` stays pipe-friendly. Errors from
// unknown subcommands / actions must continue to land on stderr with a
// non-zero exit status.

fn assertExitOk(res: RunResult) !void {
    try std.testing.expect(res.exitOk());
}

fn assertExitCode(res: RunResult, expected: u8) !void {
    switch (res.term) {
        .exited => |c| try std.testing.expectEqual(expected, c),
        else => return error.UnexpectedTermination,
    }
}

test "cr (no args) prints top usage to stdout, exit 0" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{}, "");
    defer res.deinit(allocator);
    try assertExitOk(res);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "cr — Cora secret runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "Subcommands:") != null);
}

test "cr help routes top usage to stdout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{"help"}, "");
    defer res.deinit(allocator);
    try assertExitOk(res);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "cr — Cora secret runtime") != null);
}

test "cr --help routes top usage to stdout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{"--help"}, "");
    defer res.deinit(allocator);
    try assertExitOk(res);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "cr — Cora secret runtime") != null);
}

test "cr -h routes top usage to stdout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{"-h"}, "");
    defer res.deinit(allocator);
    try assertExitOk(res);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "cr — Cora secret runtime") != null);
}

test "cr --version prints version to stdout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{"--version"}, "");
    defer res.deinit(allocator);
    try assertExitOk(res);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "cr ") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "(commit ") != null);
}

test "cr -V prints version to stdout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{"-V"}, "");
    defer res.deinit(allocator);
    try assertExitOk(res);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "cr ") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "(commit ") != null);
}

test "cr version (legacy) prints to stdout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{"version"}, "");
    defer res.deinit(allocator);
    try assertExitOk(res);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "cr ") != null);
}

test "cr secrets --help prints secrets usage to stdout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{ "secrets", "--help" }, "");
    defer res.deinit(allocator);
    try assertExitOk(res);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "cr secrets — Manage secrets") != null);
}

test "cr secrets set --help prints action usage to stdout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{ "secrets", "set", "--help" }, "");
    defer res.deinit(allocator);
    try assertExitOk(res);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "cr secrets set — Add or update a secret") != null);
}

test "cr policy --help prints policy usage with task subcommand" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{ "policy", "--help" }, "");
    defer res.deinit(allocator);
    try assertExitOk(res);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "cr policy — Manage the access policy") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "task <add|remove>") != null);
}

test "cr policy task --help prints task usage to stdout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{ "policy", "task", "--help" }, "");
    defer res.deinit(allocator);
    try assertExitOk(res);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "cr policy task — Manage task definitions") != null);
}

test "cr policy task add --help prints inner action usage to stdout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{ "policy", "task", "add", "--help" }, "");
    defer res.deinit(allocator);
    try assertExitOk(res);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "cr policy task add — Define a task") != null);
}

test "cr help secrets routes to secrets usage on stdout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{ "help", "secrets" }, "");
    defer res.deinit(allocator);
    try assertExitOk(res);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "cr secrets — Manage secrets") != null);
}

test "cr help policy task add routes to deepest topic on stdout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{ "help", "policy", "task", "add" }, "");
    defer res.deinit(allocator);
    try assertExitOk(res);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "cr policy task add — Define a task") != null);
}

test "cr bogus emits error to stderr, exit 1" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{"bogus"}, "");
    defer res.deinit(allocator);
    try assertExitCode(res, 1);
    try std.testing.expect(std.mem.indexOf(u8, res.stderr, "unknown subcommand: bogus") != null);
    try std.testing.expectEqualStrings("", res.stdout);
}

test "cr policy bogus emits unknown action to stderr without prompting, exit 1" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initFixture(allocator, io, tmp.dir);

    // Empty stdin: if action validation ran AFTER the passphrase prompt,
    // the subprocess would block on read. The fact that this test
    // terminates at all asserts that validation runs first.
    var res = try runCr(allocator, io, tmp.dir, &.{ "policy", "bogus" }, "");
    defer res.deinit(allocator);
    try assertExitCode(res, 1);
    try std.testing.expect(std.mem.indexOf(u8, res.stderr, "unknown policy action: bogus") != null);
}

test "cr policy task --help does not prompt for passphrase" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initFixture(allocator, io, tmp.dir);

    // No stdin and no passphrase. If help fell through to the prompt
    // path, the child would block. Terminating cleanly proves help
    // short-circuits before any prompt or file I/O.
    var res = try runCr(allocator, io, tmp.dir, &.{ "policy", "task", "--help" }, "");
    defer res.deinit(allocator);
    try assertExitOk(res);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "cr policy task — Manage task definitions") != null);
}

test "cr secrets bogus emits unknown action to stderr, exit 1" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{ "secrets", "bogus" }, "");
    defer res.deinit(allocator);
    try assertExitCode(res, 1);
    try std.testing.expect(std.mem.indexOf(u8, res.stderr, "unknown secrets action: bogus") != null);
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
