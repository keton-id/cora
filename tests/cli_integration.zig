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

/// Like `runCr` but runs the child with an explicit, minimal environment
/// built from `extra_env` only. Used to exercise `secrets import --from-env`,
/// which reads values from the caller's environment — the import path touches
/// no other env var, so a one-entry environment is sufficient and keeps the
/// injection cross-platform (Environ.Map, not libc setenv).
fn runCrEnv(
    allocator: std.mem.Allocator,
    io: Io,
    cwd_dir: Io.Dir,
    args: []const []const u8,
    stdin_input: []const u8,
    extra_env: []const [2][]const u8,
) !RunResult {
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    try argv_list.append(allocator, opts.cr_bin_path);
    try argv_list.appendSlice(allocator, args);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    for (extra_env) |kv| try env.put(kv[0], kv[1]);

    var child = try std.process.spawn(io, .{
        .argv = argv_list.items,
        .cwd = .{ .dir = cwd_dir },
        .environ_map = &env,
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

    // `cr policy show` data is pipe-friendly: it goes to stdout. Errors,
    // prompts, and the Windows banner stay on stderr.
    try std.testing.expect(std.mem.indexOf(u8, show.stdout, "allowed_callers (1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, show.stdout, "/bin/echo") != null);
    try std.testing.expect(std.mem.indexOf(u8, show.stdout, "tasks (1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, show.stdout, "demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, show.stdout, "API_KEY") != null);
}

test "cr secrets import --from-env stores set vars and skips unset" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initFixture(allocator, io, tmp.dir);

    // CORA_IMPORT_A is provided in the child environment; CORA_IMPORT_MISSING
    // is deliberately absent.
    {
        var r = try runCrEnv(
            allocator,
            io,
            tmp.dir,
            &.{ "secrets", "import", "--from-env", "CORA_IMPORT_A", "CORA_IMPORT_MISSING" },
            pass_line,
            &.{.{ "CORA_IMPORT_A", "value-from-env" }},
        );
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
        try std.testing.expect(std.mem.indexOf(u8, r.stdout, "imported CORA_IMPORT_A") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.stdout, "skip (not set): CORA_IMPORT_MISSING") != null);
        // The value must never appear on stdout/stderr.
        try std.testing.expect(std.mem.indexOf(u8, r.stdout, "value-from-env") == null);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "value-from-env") == null);
    }

    // The imported name is now in the vault; the unset one is not.
    var list = try runCr(allocator, io, tmp.dir, &.{ "secrets", "list" }, pass_line);
    defer list.deinit(allocator);
    try std.testing.expect(list.exitOk());
    try std.testing.expect(std.mem.indexOf(u8, list.stdout, "CORA_IMPORT_A") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.stdout, "CORA_IMPORT_MISSING") == null);
}

// --- Cross-platform parity contracts --------------------------------------
// Tier 2 (Named Pipes + GetNamedPipeClientProcessId + CreateProcessW
// daemonize) brings Windows in line with macOS and Linux. The tests
// below assert *absence* of every preview marker on every OS — banner,
// status mode line, version tag. They used to be POSIX-only; now they
// must hold cross-platform, and any reintroduction will fail CI.

test "cr version never carries the windows-preview tag" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{"version"}, "");
    defer res.deinit(allocator);
    try std.testing.expect(res.exitOk());
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "[windows-preview]") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.stderr, "[windows-preview]") == null);
}

test "cr status never emits the windows-preview mode line" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{"status"}, "");
    defer res.deinit(allocator);
    try std.testing.expect(res.exitOk());
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "mode: windows-preview") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.stderr, "mode: windows-preview") == null);
}

test "cr policy show never emits a windows-preview banner" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initFixture(allocator, io, tmp.dir);

    var show = try policyShow(allocator, io, tmp.dir);
    defer show.deinit(allocator);
    try std.testing.expect(show.exitOk());
    try std.testing.expect(std.mem.indexOf(u8, show.stdout, "warning: running in windows-preview") == null);
    try std.testing.expect(std.mem.indexOf(u8, show.stderr, "warning: running in windows-preview") == null);
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

// --- Channel discipline ---------------------------------------------------
// Data output for every command lands on stdout so `cr <sub> | grep / jq`
// works. Errors, warnings, and prompts continue to use stderr. These tests
// pin the contract per command.

test "cr init writes confirmation to stdout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{ "init", "cora.zon" }, init_stdin);
    defer res.deinit(allocator);
    try std.testing.expect(res.exitOk());
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "wrote encrypted cora.zon") != null);
}

test "cr status writes state to stdout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{"status"}, "");
    defer res.deinit(allocator);
    try std.testing.expect(res.exitOk());
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "status: not running") != null);
    try std.testing.expectEqualStrings("", res.stderr);
}

test "cr secrets list emits names on stdout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initFixture(allocator, io, tmp.dir);

    {
        var r = try runCr(allocator, io, tmp.dir, &.{ "secrets", "set", "MY_TOKEN" }, pass_line ++ "v\n");
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
    }

    var list = try runCr(allocator, io, tmp.dir, &.{ "secrets", "list" }, pass_line);
    defer list.deinit(allocator);
    try std.testing.expect(list.exitOk());
    try std.testing.expect(std.mem.indexOf(u8, list.stdout, "MY_TOKEN") != null);
}

test "cr secrets list emits (no secrets) on stdout when empty" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initFixture(allocator, io, tmp.dir);

    var list = try runCr(allocator, io, tmp.dir, &.{ "secrets", "list" }, pass_line);
    defer list.deinit(allocator);
    try std.testing.expect(list.exitOk());
    try std.testing.expect(std.mem.indexOf(u8, list.stdout, "(no secrets)") != null);
}

test "cr secrets set emits confirmation on stdout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initFixture(allocator, io, tmp.dir);

    var r = try runCr(allocator, io, tmp.dir, &.{ "secrets", "set", "K" }, pass_line ++ "v\n");
    defer r.deinit(allocator);
    try std.testing.expect(r.exitOk());
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "set K") != null);
}

test "cr policy allow confirmation lands on stdout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initFixture(allocator, io, tmp.dir);

    var r = try runCr(allocator, io, tmp.dir, &.{ "policy", "allow", "/bin/echo" }, pass_line);
    defer r.deinit(allocator);
    try std.testing.expect(r.exitOk());
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "policy updated") != null);
}

test "cr bogus does not write anything to stdout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var res = try runCr(allocator, io, tmp.dir, &.{"bogus"}, "");
    defer res.deinit(allocator);
    try assertExitCode(res, 1);
    // Pipe-safety: errors must not contaminate stdout.
    try std.testing.expectEqualStrings("", res.stdout);
    try std.testing.expect(std.mem.indexOf(u8, res.stderr, "unknown subcommand: bogus") != null);
}

// --- cr exec stdio passing (POSIX) ----------------------------------------
// Cora's daemon (cr unlock) detaches stdio to /dev/null on the fork+setsid
// path. Before SCM_RIGHTS fd passing was added, every cr exec child inherited
// that /dev/null stdio and any stdout/stderr it produced was silently
// dropped — the operator saw `child pid N exit 0` with no other evidence.
// This test locks the contract that cr exec attaches the caller's stdio so
// the child's output is captured.

fn pollStatus(allocator: std.mem.Allocator, io: Io, dir: Io.Dir, want_running: bool) !void {
    // The daemon fork returns to the parent before Service.start has bound
    // the socket, so a quick `cr status` right after `cr unlock` can race
    // and miss the running state. Retry until it agrees with the expected
    // state.
    //
    // Generous attempt budget because: (a) each iteration spawns a fresh
    // `cr status` subprocess which is ~200ms on Windows CI runners, and
    // (b) the daemon's Argon2id key derivation (t=3 m=65536KB p=4) plus
    // service startup can easily take 5-10s on a slow GitHub Actions
    // windows-latest runner before the named pipe is bound and `cr
    // status` can connect.
    const max_attempts: usize = 200;
    var attempts: usize = 0;
    while (attempts < max_attempts) : (attempts += 1) {
        var res = try runCr(allocator, io, dir, &.{"status"}, "");
        defer res.deinit(allocator);
        const says_running = std.mem.indexOf(u8, res.stdout, "status: running") != null;
        if (says_running == want_running) return;
        io.sleep(.{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
    }
    return error.StatusPollTimedOut;
}

test "cr exec attaches caller stdio so child output is captured (POSIX-only)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try initFixture(allocator, io, tmp.dir);

    {
        var r = try runCr(allocator, io, tmp.dir, &.{ "policy", "allow", opts.cr_bin_path }, pass_line);
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
    }
    {
        var r = try runCr(allocator, io, tmp.dir, &.{ "policy", "task", "add", "demo", "MY_VAR" }, pass_line);
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
    }
    {
        var r = try runCr(allocator, io, tmp.dir, &.{ "secrets", "set", "MY_VAR" }, pass_line ++ "expected-value\n");
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
    }

    // Background-spawn the daemon, then poll status until ready.
    {
        var r = try runCr(allocator, io, tmp.dir, &.{"unlock"}, pass_line);
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
    }
    try pollStatus(allocator, io, tmp.dir, true);

    // Ensure we always lock, even if the assertions below fail, so other
    // tests aren't left fighting a stale daemon over /tmp/cora-<uid>.sock.
    var lock_done = false;
    defer if (!lock_done) {
        if (runCr(allocator, io, tmp.dir, &.{"lock"}, "")) |r| {
            var owned = r;
            owned.deinit(allocator);
        } else |_| {}
    };

    {
        var r = try runCr(
            allocator,
            io,
            tmp.dir,
            &.{ "exec", "demo", "--", "/usr/bin/env", "sh", "-c", "printf 'MY_VAR=%s' \"$MY_VAR\"" },
            "",
        );
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
        // The CRITICAL assertion: child stdout must reach the cr exec
        // caller's stdout. Pre-fix this was always empty.
        try std.testing.expect(std.mem.indexOf(u8, r.stdout, "MY_VAR=expected-value") != null);
    }

    {
        var r = try runCr(allocator, io, tmp.dir, &.{"lock"}, "");
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
        lock_done = true;
    }
    try pollStatus(allocator, io, tmp.dir, false);
}

test "cr exec rejects spawn target outside task allowed_targets (POSIX-only)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try initFixture(allocator, io, tmp.dir);

    {
        var r = try runCr(allocator, io, tmp.dir, &.{ "policy", "allow", opts.cr_bin_path }, pass_line);
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
    }
    {
        // Allow only /usr/bin/env as the spawn target. /bin/echo and the
        // rest of the canonical "leak" tools (cat, printenv) must be
        // rejected even though the caller (cr itself) is whitelisted.
        var r = try runCr(allocator, io, tmp.dir, &.{ "policy", "task", "add", "guarded", "--target", "/usr/bin/env", "MY_VAR" }, pass_line);
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
    }
    {
        var r = try runCr(allocator, io, tmp.dir, &.{ "secrets", "set", "MY_VAR" }, pass_line ++ "expected-value\n");
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
    }
    {
        var r = try runCr(allocator, io, tmp.dir, &.{"unlock"}, pass_line);
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
    }
    try pollStatus(allocator, io, tmp.dir, true);

    var lock_done = false;
    defer if (!lock_done) {
        if (runCr(allocator, io, tmp.dir, &.{"lock"}, "")) |r| {
            var owned = r;
            owned.deinit(allocator);
        } else |_| {}
    };

    // Positive: /usr/bin/env is whitelisted → secret reaches child env.
    {
        var r = try runCr(
            allocator,
            io,
            tmp.dir,
            &.{ "exec", "guarded", "--", "/usr/bin/env", "sh", "-c", "printf 'MY_VAR=%s' \"$MY_VAR\"" },
            "",
        );
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
        try std.testing.expect(std.mem.indexOf(u8, r.stdout, "MY_VAR=expected-value") != null);
    }

    // Negative: /bin/echo is NOT in allowed_targets. Service must reject
    // the spawn before injecting MY_VAR, so the secret never reaches the
    // child env and never lands on the caller's stdout.
    {
        var r = try runCr(
            allocator,
            io,
            tmp.dir,
            &.{ "exec", "guarded", "--", "/bin/echo", "leaked=$MY_VAR" },
            "",
        );
        defer r.deinit(allocator);
        try std.testing.expect(!r.exitOk());
        // Whatever the precise error name the client prints, it must NOT
        // be the literal expected-value (i.e. nothing got injected and
        // printed).
        try std.testing.expect(std.mem.indexOf(u8, r.stdout, "expected-value") == null);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "exec failed") != null);
    }

    {
        var r = try runCr(allocator, io, tmp.dir, &.{"lock"}, "");
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
        lock_done = true;
    }
    try pollStatus(allocator, io, tmp.dir, false);
}

test "cr exec attaches caller stdio so child output is captured (Windows-only)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try initFixture(allocator, io, tmp.dir);

    {
        var r = try runCr(allocator, io, tmp.dir, &.{ "policy", "allow", opts.cr_bin_path }, pass_line);
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
    }
    {
        var r = try runCr(allocator, io, tmp.dir, &.{ "policy", "task", "add", "demo", "MY_VAR" }, pass_line);
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
    }
    {
        var r = try runCr(allocator, io, tmp.dir, &.{ "secrets", "set", "MY_VAR" }, pass_line ++ "expected-value\n");
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
    }

    {
        var r = try runCr(allocator, io, tmp.dir, &.{"unlock"}, pass_line);
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
    }
    try pollStatus(allocator, io, tmp.dir, true);

    var lock_done = false;
    defer if (!lock_done) {
        if (runCr(allocator, io, tmp.dir, &.{"lock"}, "")) |r| {
            var owned = r;
            owned.deinit(allocator);
        } else |_| {}
    };

    {
        var r = try runCr(
            allocator,
            io,
            tmp.dir,
            &.{ "exec", "demo", "--", "C:\\Windows\\System32\\cmd.exe", "/c", "echo MY_VAR=%MY_VAR%" },
            "",
        );
        defer r.deinit(allocator);
        if (!r.exitOk()) {
            std.debug.print("[WIN-DBG cr exec stdio] term={any}\nstdout=<<<{s}>>>\nstderr=<<<{s}>>>\n", .{ r.term, r.stdout, r.stderr });
        }
        try std.testing.expect(r.exitOk());
        // Critical assertion: child stdout reaches the cr exec caller's
        // stdout (DuplicateHandle path landed). Pre-Windows-parity this
        // was always empty because the daemon's NUL stdio was inherited.
        try std.testing.expect(std.mem.indexOf(u8, r.stdout, "MY_VAR=expected-value") != null);
    }

    {
        var r = try runCr(allocator, io, tmp.dir, &.{"lock"}, "");
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
        lock_done = true;
    }
    try pollStatus(allocator, io, tmp.dir, false);
}

test "cr exec rejects spawn target outside task allowed_targets (Windows-only)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try initFixture(allocator, io, tmp.dir);

    {
        var r = try runCr(allocator, io, tmp.dir, &.{ "policy", "allow", opts.cr_bin_path }, pass_line);
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
    }
    {
        // Allow only where.exe as the spawn target. cmd.exe (the
        // canonical Windows leak vector via `cmd /c echo %MY_VAR%`)
        // must be rejected even though the caller cr is whitelisted.
        var r = try runCr(allocator, io, tmp.dir, &.{ "policy", "task", "add", "guarded", "--target", "C:\\Windows\\System32\\where.exe", "MY_VAR" }, pass_line);
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
    }
    {
        var r = try runCr(allocator, io, tmp.dir, &.{ "secrets", "set", "MY_VAR" }, pass_line ++ "expected-value\n");
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
    }
    {
        var r = try runCr(allocator, io, tmp.dir, &.{"unlock"}, pass_line);
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
    }
    try pollStatus(allocator, io, tmp.dir, true);

    var lock_done = false;
    defer if (!lock_done) {
        if (runCr(allocator, io, tmp.dir, &.{"lock"}, "")) |r| {
            var owned = r;
            owned.deinit(allocator);
        } else |_| {}
    };

    // Positive: where.exe is whitelisted → spawn allowed.
    {
        var r = try runCr(
            allocator,
            io,
            tmp.dir,
            &.{ "exec", "guarded", "--", "C:\\Windows\\System32\\where.exe", "cmd" },
            "",
        );
        defer r.deinit(allocator);
        if (!r.exitOk()) {
            std.debug.print("[WIN-DBG cr exec target] term={any}\nstdout=<<<{s}>>>\nstderr=<<<{s}>>>\n", .{ r.term, r.stdout, r.stderr });
        }
        try std.testing.expect(r.exitOk());
    }

    // Negative: cmd.exe is NOT in allowed_targets. Service must reject
    // the spawn before injecting MY_VAR, so the secret never reaches the
    // child env and never lands on the caller's stdout.
    {
        var r = try runCr(
            allocator,
            io,
            tmp.dir,
            &.{ "exec", "guarded", "--", "C:\\Windows\\System32\\cmd.exe", "/c", "echo leaked=%MY_VAR%" },
            "",
        );
        defer r.deinit(allocator);
        try std.testing.expect(!r.exitOk());
        try std.testing.expect(std.mem.indexOf(u8, r.stdout, "expected-value") == null);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "exec failed") != null);
    }

    {
        var r = try runCr(allocator, io, tmp.dir, &.{"lock"}, "");
        defer r.deinit(allocator);
        try std.testing.expect(r.exitOk());
        lock_done = true;
    }
    try pollStatus(allocator, io, tmp.dir, false);
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

    try std.testing.expect(std.mem.indexOf(u8, show.stdout, "tasks (1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, show.stdout, "demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, show.stdout, "allowed_callers (1)") != null);
}
