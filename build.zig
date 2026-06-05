const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = parseVersion(b, target);
    const commit = gitCommit(b);
    const build_date = buildDate(b);

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    build_options.addOption([]const u8, "commit", commit);
    build_options.addOption([]const u8, "build_date", build_date);

    const core_mod = b.addModule("cora", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });

    const vaxis_dep = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const vaxis_mod = vaxis_dep.module("vaxis");

    const exe = b.addExecutable(.{
        .name = "cr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "cora", .module = core_mod },
                .{ .name = "vaxis", .module = vaxis_mod },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run cr");
    run_step.dependOn(&run_cmd.step);

    const core_tests = b.addTest(.{ .root_module = core_mod });
    const run_core_tests = b.addRunArtifact(core_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const integration_opts = b.addOptions();
    // On Windows the installed artifact is `cr.exe`; `getInstallPath` does not
    // auto-append the platform executable suffix, so callers must spell it
    // out. Without this, `dir.access(io, "cr", .{})` fails with FileNotFound
    // even though `cr.exe` is present alongside.
    const cr_basename = if (target.result.os.tag == .windows) "cr.exe" else "cr";
    integration_opts.addOption([]const u8, "cr_bin_path", b.getInstallPath(.bin, cr_basename));

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("tests/cli_integration.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "integration_options", .module = integration_opts.createModule() },
        },
    });
    const integration_tests = b.addTest(.{ .root_module = integration_mod });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    run_integration_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    const fmt_step = b.step("fmt", "Check formatting");
    const fmt = b.addFmt(.{ .paths = &.{ "src", "build.zig" }, .check = true });
    fmt_step.dependOn(&fmt.step);
}

fn parseVersion(b: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
    // `.versions.json` holds the per-OS versions managed by release-please.
    // Build picks the field matching the target OS so `cr --version` reports
    // the version of the component that produced this binary.
    const json = @embedFile(".versions.json");
    const os_key: []const u8 = switch (target.result.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => return "unknown",
    };

    // Naive JSON field lookup. The file shape is fixed at three string
    // fields, so a full parser is overkill — release-please updates the
    // values in-place via jsonpath, never the shape.
    const needle = b.fmt("\"{s}\":", .{os_key});
    const key_pos = std.mem.indexOf(u8, json, needle) orelse return "unknown";
    const after_key = json[key_pos + needle.len ..];
    const value_start = std.mem.indexOfScalar(u8, after_key, '"') orelse return "unknown";
    const after_quote = after_key[value_start + 1 ..];
    const value_end = std.mem.indexOfScalar(u8, after_quote, '"') orelse return "unknown";
    return b.dupe(after_quote[0..value_end]);
}

fn gitCommit(b: *std.Build) []const u8 {
    var code: u8 = 0;
    const out = b.runAllowFail(
        &.{ "git", "rev-parse", "--short=12", "HEAD" },
        &code,
        .ignore,
    ) catch return "unknown";
    return std.mem.trim(u8, out, " \n\r\t");
}

fn buildDate(b: *std.Build) []const u8 {
    var code: u8 = 0;
    const out = b.runAllowFail(
        &.{ "date", "-u", "+%Y-%m-%dT%H:%M:%SZ" },
        &code,
        .ignore,
    ) catch return "unknown";
    return std.mem.trim(u8, out, " \n\r\t");
}
