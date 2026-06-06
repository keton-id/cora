const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // CI passes `-Dversion=<X.Y.Z>` so the binary reports the actual
    // tagged release version rather than whatever build.zig.zon happens
    // to hold. Local `zig build` (no -Dversion) falls back to scraping
    // build.zig.zon, so `cr version` still works for from-source builds.
    const version = b.option([]const u8, "version", "release version override (defaults to build.zig.zon)") orelse parseVersion(b);
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

fn parseVersion(b: *std.Build) []const u8 {
    const zon = @embedFile("build.zig.zon");
    const key = ".version = \"";
    const start = std.mem.indexOf(u8, zon, key) orelse return "unknown";
    const after = zon[start + key.len ..];
    const end = std.mem.indexOfScalar(u8, after, '"') orelse return "unknown";
    return b.dupe(after[0..end]);
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
