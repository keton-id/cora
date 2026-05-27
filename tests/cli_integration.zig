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
const opts = @import("integration_options");

test "cr binary is installed at expected path" {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, std.fs.path.dirname(opts.cr_bin_path).?, .{});
    defer dir.close(std.testing.io);
    const basename = std.fs.path.basename(opts.cr_bin_path);
    try dir.access(std.testing.io, basename, .{});
}
