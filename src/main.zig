const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const cora = @import("cora");
const tui_menu = @import("tui/menu.zig");
const usage = @import("cli/usage.zig");
const build_options = @import("build_options");

const default_path = "cora.zon";

/// Single source of truth for the Windows preview brand. Appears in the
/// `cr version` tag, the sensitive-subcommand warning banner, and the
/// `cr status` mode line. Keeping it here prevents the three surfaces from
/// drifting from each other if the label is ever renamed.
const windows_preview_label = "windows-preview";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        usage.printTop(io, .stdout);
        return;
    }

    const sub = args[1];

    // Top-level help and version flags are pure-output and must not trigger
    // the sensitive-sub warning banner or touch any service state.
    if (usage.isHelpFlag(sub)) {
        try cmdHelp(io, args[2..]);
        return;
    }
    if (usage.isVersionFlag(sub) or std.mem.eql(u8, sub, "version")) {
        printVersion(io);
        return;
    }

    // Suppress the Windows preview banner when the caller is asking for help
    // anywhere in the argv. `cr secrets --help` shouldn't warn about a trust
    // model it isn't going to use.
    if (isSensitiveSub(sub) and !argvHasHelpFlag(args[2..])) printWindowsPreviewBanner();

    if (std.mem.eql(u8, sub, "init")) {
        if (args.len >= 3 and usage.isHelpFlag(args[2])) {
            usage.printInit(io, .stdout);
            return;
        }
        const path = if (args.len >= 3) args[2] else default_path;
        try cmdInit(arena, io, path);
        return;
    }
    if (std.mem.eql(u8, sub, "unlock")) {
        if (argvHasHelpFlag(args[2..])) {
            usage.printUnlock(io, .stdout);
            return;
        }
        try cmdUnlock(arena, io, default_path, args);
        return;
    }
    if (std.mem.eql(u8, sub, "lock")) {
        if (argvHasHelpFlag(args[2..])) {
            usage.printLock(io, .stdout);
            return;
        }
        try cmdLock(arena, io);
        return;
    }
    if (std.mem.eql(u8, sub, "status")) {
        if (argvHasHelpFlag(args[2..])) {
            usage.printStatus(io, .stdout);
            return;
        }
        try cmdStatus(arena, io);
        return;
    }
    if (std.mem.eql(u8, sub, "exec")) {
        if (args.len >= 3 and usage.isHelpFlag(args[2])) {
            usage.printExec(io, .stdout);
            return;
        }
        try cmdExec(arena, io, args);
        return;
    }
    if (std.mem.eql(u8, sub, "audit")) {
        try cmdAudit(arena, io, args);
        return;
    }
    if (std.mem.eql(u8, sub, "tui")) {
        if (argvHasHelpFlag(args[2..])) {
            usage.printTui(io, .stdout);
            return;
        }
        try tui_menu.run(arena, io);
        return;
    }
    if (std.mem.eql(u8, sub, "verify")) {
        if (argvHasHelpFlag(args[2..])) {
            usage.printVerify(io, .stdout);
            return;
        }
        try cmdVerify(args);
        return;
    }
    if (std.mem.eql(u8, sub, "policy")) {
        try cmdPolicy(arena, io, default_path, args);
        return;
    }
    if (std.mem.eql(u8, sub, "secrets")) {
        try cmdSecrets(arena, io, default_path, args);
        return;
    }

    std.debug.print("unknown subcommand: {s}\n", .{sub});
    usage.printTop(io, .stderr);
    std.process.exit(1);
}

/// Scan a tail of argv (everything after the subcommand) for any help flag.
/// Used to suppress side-effecting prologue when the user is asking for help.
fn argvHasHelpFlag(rest: []const []const u8) bool {
    for (rest) |a| {
        if (usage.isHelpFlag(a)) return true;
    }
    return false;
}

fn printVersion(io: Io) void {
    const tag = if (builtin.os.tag == .windows) " [" ++ windows_preview_label ++ "]" else "";
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "cr {s} (commit {s}, built {s}){s}\n", .{
        build_options.version,
        build_options.commit,
        build_options.build_date,
        tag,
    }) catch return;
    Io.File.stdout().writeStreamingAll(io, text) catch {};
}

/// Dispatch `cr help [SUB [ACTION [INNER]]]` to the right per-page usage.
/// `parts` is argv after the literal "help" / "--help" / "-h" token.
fn cmdHelp(io: Io, parts: []const []const u8) !void {
    if (parts.len == 0) {
        usage.printTop(io, .stdout);
        return;
    }
    const sub = parts[0];
    if (std.mem.eql(u8, sub, "init")) return usage.printInit(io, .stdout);
    if (std.mem.eql(u8, sub, "unlock")) return usage.printUnlock(io, .stdout);
    if (std.mem.eql(u8, sub, "lock")) return usage.printLock(io, .stdout);
    if (std.mem.eql(u8, sub, "status")) return usage.printStatus(io, .stdout);
    if (std.mem.eql(u8, sub, "exec")) return usage.printExec(io, .stdout);
    if (std.mem.eql(u8, sub, "tui")) return usage.printTui(io, .stdout);
    if (std.mem.eql(u8, sub, "verify")) return usage.printVerify(io, .stdout);
    if (std.mem.eql(u8, sub, "version")) return printVersion(io);
    if (usage.isHelpFlag(sub)) return usage.printTop(io, .stdout);

    if (std.mem.eql(u8, sub, "audit")) {
        if (parts.len < 2) return usage.printAudit(io, .stdout);
        const a = parts[1];
        if (std.mem.eql(u8, a, "tail")) return usage.printAuditTail(io, .stdout);
        if (std.mem.eql(u8, a, "show")) return usage.printAuditShow(io, .stdout);
        std.debug.print("no help topic: audit {s}\n", .{a});
        usage.printAudit(io, .stderr);
        std.process.exit(1);
    }

    if (std.mem.eql(u8, sub, "secrets")) {
        if (parts.len < 2) return usage.printSecrets(io, .stdout);
        const a = parts[1];
        if (std.mem.eql(u8, a, "set")) return usage.printSecretsSet(io, .stdout);
        if (std.mem.eql(u8, a, "list")) return usage.printSecretsList(io, .stdout);
        if (std.mem.eql(u8, a, "delete")) return usage.printSecretsDelete(io, .stdout);
        std.debug.print("no help topic: secrets {s}\n", .{a});
        usage.printSecrets(io, .stderr);
        std.process.exit(1);
    }

    if (std.mem.eql(u8, sub, "policy")) {
        if (parts.len < 2) return usage.printPolicy(io, .stdout);
        const a = parts[1];
        if (std.mem.eql(u8, a, "show")) return usage.printPolicyShow(io, .stdout);
        if (std.mem.eql(u8, a, "allow")) return usage.printPolicyAllow(io, .stdout);
        if (std.mem.eql(u8, a, "deny")) return usage.printPolicyDeny(io, .stdout);
        if (std.mem.eql(u8, a, "task")) {
            if (parts.len < 3) return usage.printPolicyTask(io, .stdout);
            const inner = parts[2];
            if (std.mem.eql(u8, inner, "add")) return usage.printPolicyTaskAdd(io, .stdout);
            if (std.mem.eql(u8, inner, "remove")) return usage.printPolicyTaskRemove(io, .stdout);
            std.debug.print("no help topic: policy task {s}\n", .{inner});
            usage.printPolicyTask(io, .stderr);
            std.process.exit(1);
        }
        std.debug.print("no help topic: policy {s}\n", .{a});
        usage.printPolicy(io, .stderr);
        std.process.exit(1);
    }

    std.debug.print("no help topic: {s}\n", .{sub});
    usage.printTop(io, .stderr);
    std.process.exit(1);
}

/// Dispatch `cr secrets <action> ...` with help-flag and action-validity
/// handling. Moved out of `main` to keep the top-level dispatch readable
/// and to centralize the secrets-specific routing logic.
fn cmdSecrets(arena: std.mem.Allocator, io: Io, path: []const u8, args: []const []const u8) !void {
    if (args.len < 3) {
        usage.printSecrets(io, .stderr);
        std.process.exit(1);
    }
    if (usage.isHelpFlag(args[2])) {
        usage.printSecrets(io, .stdout);
        return;
    }
    const action = args[2];

    if (std.mem.eql(u8, action, "set")) {
        if (args.len >= 4 and usage.isHelpFlag(args[3])) {
            usage.printSecretsSet(io, .stdout);
            return;
        }
        if (args.len < 4) {
            usage.printSecretsSet(io, .stderr);
            std.process.exit(1);
        }
        try cmdSecretsSet(arena, io, path, args[3]);
        return;
    }
    if (std.mem.eql(u8, action, "list")) {
        if (args.len >= 4 and usage.isHelpFlag(args[3])) {
            usage.printSecretsList(io, .stdout);
            return;
        }
        try cmdSecretsList(arena, io, path);
        return;
    }
    if (std.mem.eql(u8, action, "delete")) {
        if (args.len >= 4 and usage.isHelpFlag(args[3])) {
            usage.printSecretsDelete(io, .stdout);
            return;
        }
        if (args.len < 4) {
            usage.printSecretsDelete(io, .stderr);
            std.process.exit(1);
        }
        try cmdSecretsDelete(arena, io, path, args[3]);
        return;
    }

    std.debug.print("unknown secrets action: {s}\n", .{action});
    usage.printSecrets(io, .stderr);
    std.process.exit(1);
}

/// Subcommands that mutate secret material, policy, or spawn a process with
/// secrets injected. These are the operator-facing surfaces where the Windows
/// preview trust model (socket-ACL caller verification only) is materially
/// different from POSIX, so the user must see a single-line in-band warning
/// before each invocation.
fn isSensitiveSub(sub: []const u8) bool {
    return std.mem.eql(u8, sub, "init") or
        std.mem.eql(u8, sub, "unlock") or
        std.mem.eql(u8, sub, "secrets") or
        std.mem.eql(u8, sub, "policy") or
        std.mem.eql(u8, sub, "exec");
}

/// One-line preview banner for the sensitive subcommands. No-op on POSIX so
/// the same call site is safe to leave unguarded.
fn printWindowsPreviewBanner() void {
    if (builtin.os.tag != .windows) return;
    std.debug.print(
        "warning: running in " ++ windows_preview_label ++
            ". caller identity verified by socket ACL only, not by OS peer credentials. see SECURITY.md.\n",
        .{},
    );
}

fn cmdInit(allocator: std.mem.Allocator, io: Io, path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    if (fileExists(io, cwd, path)) {
        std.debug.print("refusing to overwrite existing {s}\n", .{path});
        std.process.exit(1);
    }

    var pass_buf: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &pass_buf);
    const passphrase = try readSecret("Create passphrase: ", &pass_buf);

    var confirm_buf: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &confirm_buf);
    const confirm = try readSecret("Confirm passphrase: ", &confirm_buf);

    if (!std.mem.eql(u8, passphrase, confirm)) {
        std.debug.print("passphrases do not match\n", .{});
        std.process.exit(1);
    }

    var ef = cora.store.createEncrypted(allocator, io, .{
        .passphrase = passphrase,
        .config_bytes = "",
        .secrets_plaintext = "{}",
    }) catch |err| switch (err) {
        cora.CoraError.PassphraseTooShort => {
            std.debug.print("passphrase too short (min {d} chars)\n", .{cora.store.min_passphrase_len});
            std.process.exit(1);
        },
        else => return err,
    };
    defer ef.deinit();

    try cora.store.writeFile(io, cwd, path, ef.bytes);
    std.debug.print("wrote encrypted {s} ({d} bytes)\n", .{ path, ef.bytes.len });
}

fn cmdUnlock(allocator: std.mem.Allocator, io: Io, path: []const u8, args: []const []const u8) !void {
    var foreground = false;
    for (args[2..]) |a| {
        if (std.mem.eql(u8, a, "--foreground")) foreground = true;
    }

    var sock_buf: [128]u8 = undefined;
    const sock_path = try cora.service.defaultSocketPath(&sock_buf);

    if (cora.client.isRunning(io, sock_path)) {
        std.debug.print("service already running at {s}\n", .{sock_path});
        std.process.exit(1);
    }

    const cwd = Io.Dir.cwd();
    if (!fileExists(io, cwd, path)) {
        std.debug.print("no {s} — run `cr init` first\n", .{path});
        std.process.exit(1);
    }

    var pass_buf: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &pass_buf);
    const passphrase = try readSecret("Passphrase: ", &pass_buf);

    var secrets = cora.MemStore.init(allocator);
    defer secrets.deinit();

    const encoded = try cora.store.readFile(allocator, io, cwd, path);
    defer allocator.free(encoded);
    var dec = cora.store.decrypt(allocator, io, passphrase, encoded) catch |err| switch (err) {
        cora.CoraError.AuthFailed => {
            std.debug.print("authentication failed\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer dec.deinit();
    try cora.secrets_codec.decode(allocator, dec.secrets_plaintext, &secrets);
    var pol = try cora.policy.parse(allocator, dec.config_bytes);
    defer cora.policy.free(allocator, &pol);

    if (!foreground) {
        if (builtin.os.tag == .windows) {
            // TODO(windows): daemonize via CreateProcessW with DETACHED_PROCESS.
            // For Tier 1 preview, run foreground and warn.
            std.debug.print("warning: background mode not yet supported on windows, running foreground\n", .{});
        } else {
            const pid = std.c.fork();
            if (pid < 0) {
                std.debug.print("fork failed\n", .{});
                std.process.exit(1);
            }
            if (pid != 0) {
                std.debug.print("service started (pid {d}) at {s}\n", .{ pid, sock_path });
                std.process.exit(0);
            }
            _ = std.c.setsid();
            // Detach inherited std fds so parent pipes/terminals can close.
            const o: std.c.O = .{ .ACCMODE = .RDWR };
            const devnull_fd = std.c.open("/dev/null", o);
            if (devnull_fd >= 0) {
                _ = std.c.dup2(devnull_fd, std.posix.STDIN_FILENO);
                _ = std.c.dup2(devnull_fd, std.posix.STDOUT_FILENO);
                _ = std.c.dup2(devnull_fd, std.posix.STDERR_FILENO);
                if (devnull_fd > std.posix.STDERR_FILENO) _ = std.c.close(devnull_fd);
            }
        }
    }

    const audit_path = try cora.audit.defaultPathAlloc(allocator);
    var audit_logger = try cora.audit.Logger.init(allocator, io, audit_path, true);
    defer audit_logger.deinit();

    var svc = try cora.service.Service.start(allocator, io, .{
        .socket_path = sock_path,
        .idle_timeout_ms = pol.idle_timeout_ms,
        .policy = pol,
        .audit_logger = &audit_logger,
    }, &secrets);
    defer svc.deinit();
    if (foreground) std.debug.print("listening at {s} (foreground)\n", .{sock_path});
    try svc.run();
    std.debug.print("service exited\n", .{});
}

fn cmdAudit(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    if (args.len < 3) {
        usage.printAudit(io, .stderr);
        std.process.exit(1);
    }
    if (usage.isHelpFlag(args[2])) {
        usage.printAudit(io, .stdout);
        return;
    }
    const action = args[2];
    const is_tail = std.mem.eql(u8, action, "tail");
    const is_show = std.mem.eql(u8, action, "show");
    if (!is_tail and !is_show) {
        std.debug.print("unknown audit action: {s}\n", .{action});
        usage.printAudit(io, .stderr);
        std.process.exit(1);
    }
    if (args.len >= 4 and usage.isHelpFlag(args[3])) {
        if (is_tail) usage.printAuditTail(io, .stdout) else usage.printAuditShow(io, .stdout);
        return;
    }

    const path = try cora.audit.defaultPathAlloc(allocator);
    const cwd = Io.Dir.cwd();
    const contents = cwd.readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("no audit log at {s}\n", .{path});
            std.process.exit(1);
        },
        else => return err,
    };
    defer allocator.free(contents);

    var n: usize = 20;
    var task_filter: ?[]const u8 = null;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-n") and i + 1 < args.len) {
            n = std.fmt.parseInt(usize, args[i + 1], 10) catch n;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--task") and i + 1 < args.len) {
            task_filter = args[i + 1];
            i += 1;
        }
    }

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (task_filter) |t| {
            var needle_buf: [256]u8 = undefined;
            const needle = try std.fmt.bufPrint(&needle_buf, "\"task\":\"{s}\"", .{t});
            if (std.mem.indexOf(u8, line, needle) == null) continue;
        }
        try lines.append(allocator, line);
    }

    if (is_tail) {
        const start = if (lines.items.len > n) lines.items.len - n else 0;
        for (lines.items[start..]) |line| std.debug.print("{s}\n", .{line});
    } else {
        for (lines.items) |line| std.debug.print("{s}\n", .{line});
    }
}

fn cmdLock(allocator: std.mem.Allocator, io: Io) !void {
    var sock_buf: [128]u8 = undefined;
    const sock_path = try cora.service.defaultSocketPath(&sock_buf);
    if (!cora.client.isRunning(io, sock_path)) {
        std.debug.print("service not running\n", .{});
        std.process.exit(1);
    }
    try cora.client.lock(allocator, io, sock_path);
    std.debug.print("locked\n", .{});
}

fn cmdExec(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    if (args.len < 4) {
        std.debug.print("usage: cr exec TASK -- argv...\n", .{});
        std.process.exit(1);
    }
    const task_name = args[2];
    var sep: usize = 3;
    while (sep < args.len and !std.mem.eql(u8, args[sep], "--")) : (sep += 1) {}
    if (sep + 1 >= args.len) {
        std.debug.print("missing -- argv\n", .{});
        std.process.exit(1);
    }
    const argv = args[sep + 1 ..];

    var sock_buf: [128]u8 = undefined;
    const sock_path = try cora.service.defaultSocketPath(&sock_buf);
    if (!cora.client.isRunning(io, sock_path)) {
        std.debug.print("service not running — run `cr unlock` first\n", .{});
        std.process.exit(1);
    }
    const resp = cora.client.exec(allocator, io, sock_path, task_name, argv) catch |err| {
        std.debug.print("exec failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.debug.print("child pid {d} exit {d}\n", .{ resp.child_pid, resp.exit_code });
    if (resp.exit_code != 0) std.process.exit(@intCast(@as(u32, @bitCast(resp.exit_code & 0xff))));
}

fn cmdVerify(args: []const []const u8) !void {
    var pid: i32 = 0;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--pid") and i + 1 < args.len) {
            pid = std.fmt.parseInt(i32, args[i + 1], 10) catch {
                std.debug.print("invalid pid\n", .{});
                std.process.exit(1);
            };
            i += 1;
        }
    }
    if (pid == 0) {
        std.debug.print("usage: cr verify --pid <pid>\n", .{});
        std.process.exit(1);
    }
    const ident = cora.identity.lookupByPid(pid) catch {
        std.debug.print("could not look up pid {d}\n", .{pid});
        std.process.exit(1);
    };
    std.debug.print("pid {d} uid {d} bin {s}\n", .{ ident.pid, ident.uid, ident.path() });
}

fn cmdPolicy(allocator: std.mem.Allocator, io: Io, path: []const u8, args: []const []const u8) !void {
    if (args.len < 3) {
        usage.printPolicy(io, .stderr);
        std.process.exit(1);
    }
    if (usage.isHelpFlag(args[2])) {
        usage.printPolicy(io, .stdout);
        return;
    }
    const action = args[2];
    const is_show = std.mem.eql(u8, action, "show");
    const is_allow = std.mem.eql(u8, action, "allow");
    const is_deny = std.mem.eql(u8, action, "deny");
    const is_task = std.mem.eql(u8, action, "task");
    if (!is_show and !is_allow and !is_deny and !is_task) {
        std.debug.print("unknown policy action: {s}\n", .{action});
        usage.printPolicy(io, .stderr);
        std.process.exit(1);
    }

    // Per-action --help short-circuit. Must come before file I/O and the
    // passphrase prompt so that asking for help is never a destructive or
    // even interactive operation.
    if (args.len >= 4 and usage.isHelpFlag(args[3])) {
        if (is_show) usage.printPolicyShow(io, .stdout);
        if (is_allow) usage.printPolicyAllow(io, .stdout);
        if (is_deny) usage.printPolicyDeny(io, .stdout);
        if (is_task) usage.printPolicyTask(io, .stdout);
        return;
    }
    if (is_task and args.len >= 5 and usage.isHelpFlag(args[4])) {
        const inner = args[3];
        if (std.mem.eql(u8, inner, "add")) {
            usage.printPolicyTaskAdd(io, .stdout);
            return;
        }
        if (std.mem.eql(u8, inner, "remove")) {
            usage.printPolicyTaskRemove(io, .stdout);
            return;
        }
        // Unknown inner — fall through to the inner-action validity error
        // below so the user sees a clear "unknown task action" message.
    }

    // Required-argument validation. Done up front, before any prompting,
    // so a missing PATH or NAME never burns a passphrase entry.
    if ((is_allow or is_deny) and args.len < 4) {
        if (is_allow) usage.printPolicyAllow(io, .stderr) else usage.printPolicyDeny(io, .stderr);
        std.process.exit(1);
    }
    if (is_task) {
        if (args.len < 4) {
            usage.printPolicyTask(io, .stderr);
            std.process.exit(1);
        }
        const inner = args[3];
        const is_add = std.mem.eql(u8, inner, "add");
        const is_remove = std.mem.eql(u8, inner, "remove");
        if (!is_add and !is_remove) {
            std.debug.print("unknown task action: {s}\n", .{inner});
            usage.printPolicyTask(io, .stderr);
            std.process.exit(1);
        }
        if (args.len < 5) {
            if (is_add) usage.printPolicyTaskAdd(io, .stderr) else usage.printPolicyTaskRemove(io, .stderr);
            std.process.exit(1);
        }
    }

    const cwd = Io.Dir.cwd();
    if (!fileExists(io, cwd, path)) {
        std.debug.print("no {s} — run `cr init` first\n", .{path});
        std.process.exit(1);
    }

    var pass_buf: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &pass_buf);
    const passphrase = try readSecret("Passphrase: ", &pass_buf);

    const encoded = try cora.store.readFile(allocator, io, cwd, path);
    defer allocator.free(encoded);
    var dec = cora.store.decrypt(allocator, io, passphrase, encoded) catch |err| switch (err) {
        cora.CoraError.AuthFailed => {
            std.debug.print("authentication failed\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer dec.deinit();

    var pol = try cora.policy.parse(allocator, dec.config_bytes);
    defer cora.policy.free(allocator, &pol);

    if (is_show) {
        std.debug.print("idle_timeout_ms: {d}\n", .{pol.idle_timeout_ms});
        std.debug.print("allowed_callers ({d}):\n", .{pol.allowed_callers.len});
        for (pol.allowed_callers) |c| std.debug.print("  {s}\n", .{c});
        std.debug.print("tasks ({d}):\n", .{pol.tasks.len});
        for (pol.tasks) |t| {
            std.debug.print("  {s}: ", .{t.name});
            for (t.allowed_secrets) |s| std.debug.print("{s} ", .{s});
            std.debug.print("\n", .{});
        }
        return;
    }

    if (is_task) {
        try cmdPolicyTask(allocator, io, path, passphrase, &pol, dec.secrets_plaintext, args);
        return;
    }

    const target = args[3];

    var next_list: std.ArrayList([]const u8) = .empty;
    defer next_list.deinit(allocator);

    if (is_allow) {
        for (pol.allowed_callers) |c| try next_list.append(allocator, c);
        for (pol.allowed_callers) |c| {
            if (std.mem.eql(u8, c, target)) {
                std.debug.print("already allowed: {s}\n", .{target});
                return;
            }
        }
        try next_list.append(allocator, target);
    } else { // is_deny — validated above
        for (pol.allowed_callers) |c| {
            if (!std.mem.eql(u8, c, target)) try next_list.append(allocator, c);
        }
    }

    const new_pol = cora.policy.Policy{
        .allowed_callers = next_list.items,
        .idle_timeout_ms = pol.idle_timeout_ms,
        .tasks = pol.tasks,
    };
    const new_cfg = try cora.policy.serialize(allocator, new_pol);
    defer allocator.free(new_cfg);

    var secrets = cora.MemStore.init(allocator);
    defer secrets.deinit();
    try cora.secrets_codec.decode(allocator, dec.secrets_plaintext, &secrets);
    try cora.store.saveSecrets(allocator, io, cwd, path, passphrase, &secrets, new_cfg);
    std.debug.print("policy updated\n", .{});
}

/// Mutating half of `cr policy task <add|remove> NAME [SECRETS...]`.
/// Caller (`cmdPolicy`) has already validated that `args[3]` is one of
/// {"add","remove"} and that `args[4]` (NAME) is present, so this fn skips
/// re-checking and goes straight to the mutation.
fn cmdPolicyTask(
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
    passphrase: []const u8,
    pol: *cora.policy.Policy,
    secrets_plaintext: []const u8,
    args: []const []const u8,
) !void {
    const sub = args[3];
    const name = args[4];

    var next: std.ArrayList(cora.policy.Task) = .empty;
    defer next.deinit(allocator);

    if (std.mem.eql(u8, sub, "add")) {
        const secrets = args[5..];
        for (pol.tasks) |t| {
            if (!std.mem.eql(u8, t.name, name)) try next.append(allocator, t);
        }
        try next.append(allocator, .{ .name = name, .allowed_secrets = secrets });
    } else { // "remove" — validated by caller
        for (pol.tasks) |t| {
            if (!std.mem.eql(u8, t.name, name)) try next.append(allocator, t);
        }
    }

    const new_pol = cora.policy.Policy{
        .allowed_callers = pol.allowed_callers,
        .idle_timeout_ms = pol.idle_timeout_ms,
        .tasks = next.items,
    };
    const new_cfg = try cora.policy.serialize(allocator, new_pol);
    defer allocator.free(new_cfg);

    var secrets_store = cora.MemStore.init(allocator);
    defer secrets_store.deinit();
    try cora.secrets_codec.decode(allocator, secrets_plaintext, &secrets_store);
    const cwd = Io.Dir.cwd();
    try cora.store.saveSecrets(allocator, io, cwd, path, passphrase, &secrets_store, new_cfg);
    std.debug.print("policy updated\n", .{});
}

fn cmdStatus(allocator: std.mem.Allocator, io: Io) !void {
    var sock_buf: [128]u8 = undefined;
    const sock_path = try cora.service.defaultSocketPath(&sock_buf);
    if (!cora.client.isRunning(io, sock_path)) {
        std.debug.print("status: not running\n", .{});
        if (builtin.os.tag == .windows) {
            std.debug.print("  mode: " ++ windows_preview_label ++ " (degraded trust model — see SECURITY.md)\n", .{});
        }
        return;
    }
    const s = try cora.client.status(allocator, io, sock_path);
    std.debug.print("status: running\n  secrets: {d}\n  idle remaining: {d} ms\n", .{ s.secrets_count, s.idle_remaining_ms });
    if (builtin.os.tag == .windows) {
        std.debug.print("  mode: windows-preview (degraded trust model — see SECURITY.md)\n", .{});
    }
}

fn cmdSecretsSet(allocator: std.mem.Allocator, io: Io, path: []const u8, key: []const u8) !void {
    const cwd = Io.Dir.cwd();
    if (!fileExists(io, cwd, path)) {
        std.debug.print("no {s} — run `cr init` first\n", .{path});
        std.process.exit(1);
    }

    var pass_buf: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &pass_buf);
    const passphrase = try readSecret("Passphrase: ", &pass_buf);

    var val_buf: [cora.max_secret_len]u8 = undefined;
    defer std.crypto.secureZero(u8, &val_buf);
    const value = try readSecret("Value: ", &val_buf);

    const encoded = try cora.store.readFile(allocator, io, cwd, path);
    defer allocator.free(encoded);
    var dec = cora.store.decrypt(allocator, io, passphrase, encoded) catch |err| switch (err) {
        cora.CoraError.AuthFailed => {
            std.debug.print("authentication failed\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer dec.deinit();

    var store_ = cora.MemStore.init(allocator);
    defer store_.deinit();
    try cora.secrets_codec.decode(allocator, dec.secrets_plaintext, &store_);

    try store_.put(key, value);
    try cora.store.saveSecrets(allocator, io, cwd, path, passphrase, &store_, dec.config_bytes);
    std.debug.print("set {s}\n", .{key});
}

fn cmdSecretsList(allocator: std.mem.Allocator, io: Io, path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    if (!fileExists(io, cwd, path)) {
        std.debug.print("no {s} — run `cr init` first\n", .{path});
        std.process.exit(1);
    }

    var pass_buf: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &pass_buf);
    const passphrase = try readSecret("Passphrase: ", &pass_buf);

    var store_ = cora.MemStore.init(allocator);
    defer store_.deinit();

    cora.store.loadSecrets(allocator, io, cwd, path, passphrase, &store_) catch |err| switch (err) {
        cora.CoraError.AuthFailed => {
            std.debug.print("authentication failed\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };

    if (store_.count() == 0) {
        std.debug.print("(no secrets)\n", .{});
        return;
    }
    var it = store_.map.keyIterator();
    while (it.next()) |k| std.debug.print("{s}\n", .{k.*});
}

fn cmdSecretsDelete(allocator: std.mem.Allocator, io: Io, path: []const u8, key: []const u8) !void {
    const cwd = Io.Dir.cwd();
    if (!fileExists(io, cwd, path)) {
        std.debug.print("no {s} — run `cr init` first\n", .{path});
        std.process.exit(1);
    }

    var pass_buf: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &pass_buf);
    const passphrase = try readSecret("Passphrase: ", &pass_buf);

    const encoded = try cora.store.readFile(allocator, io, cwd, path);
    defer allocator.free(encoded);
    var dec = cora.store.decrypt(allocator, io, passphrase, encoded) catch |err| switch (err) {
        cora.CoraError.AuthFailed => {
            std.debug.print("authentication failed\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer dec.deinit();

    var store_ = cora.MemStore.init(allocator);
    defer store_.deinit();
    try cora.secrets_codec.decode(allocator, dec.secrets_plaintext, &store_);

    if (!store_.delete(key)) {
        std.debug.print("no such secret: {s}\n", .{key});
        std.process.exit(1);
    }
    try cora.store.saveSecrets(allocator, io, cwd, path, passphrase, &store_, dec.config_bytes);
    std.debug.print("deleted {s}\n", .{key});
}

fn fileExists(io: Io, dir: Io.Dir, path: []const u8) bool {
    dir.access(io, path, .{}) catch return false;
    return true;
}

/// Read one byte from stdin. Cross-platform: POSIX read on Unix,
/// ReadFile on Windows (std.posix.read errors with "unsupported OS"
/// when targeting windows even with a HANDLE).
extern "kernel32" fn ReadFile(hFile: *anyopaque, lpBuffer: *anyopaque, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: *u32, lpOverlapped: ?*anyopaque) callconv(.winapi) i32;

fn stdinReadByte(out: *[1]u8) !usize {
    if (builtin.os.tag == .windows) {
        const h = Io.File.stdin().handle;
        var got: u32 = 0;
        const ok = ReadFile(@ptrCast(h), out, 1, &got, null);
        if (ok == 0) return error.ReadFailed;
        return @intCast(got);
    } else {
        return std.posix.read(std.posix.STDIN_FILENO, out);
    }
}

// Windows console-mode bindings. Stripping ENABLE_ECHO_INPUT is the documented
// way to suppress terminal echo on Win32 consoles. ENABLE_LINE_INPUT is left
// alone so the kernel keeps buffering until newline.
extern "kernel32" fn GetConsoleMode(hConsoleHandle: *anyopaque, lpMode: *u32) callconv(.winapi) i32;
extern "kernel32" fn SetConsoleMode(hConsoleHandle: *anyopaque, dwMode: u32) callconv(.winapi) i32;
const ENABLE_ECHO_INPUT: u32 = 0x0004;

/// Read a secret line (passphrase or secret value) from stdin with terminal
/// echo suppressed. On non-TTY stdin (test pipes, redirected scripts) the
/// terminal manipulation is skipped silently — the pipe does not echo
/// anything anyway. On Windows, masking is enforced via SetConsoleMode; if
/// stdin is a real console but echo cannot be disabled, the call fails closed
/// rather than silently leaking the secret to the terminal.
fn readSecret(prompt: []const u8, buf: []u8) ![]const u8 {
    std.debug.print("{s}", .{prompt});

    if (builtin.os.tag == .windows) {
        const h: *anyopaque = @ptrCast(Io.File.stdin().handle);
        var saved_mode: u32 = 0;
        const is_console = GetConsoleMode(h, &saved_mode) != 0;
        if (is_console) {
            const masked_mode = saved_mode & ~ENABLE_ECHO_INPUT;
            if (SetConsoleMode(h, masked_mode) == 0) {
                // Fail closed: refuse to read rather than echo to the terminal.
                return error.ConsoleMaskingFailed;
            }
            defer {
                _ = SetConsoleMode(h, saved_mode);
                std.debug.print("\n", .{});
            }
            return readLineBytes(buf);
        }
        // stdin is a pipe or redirected file — nothing to mask.
        return readLineBytes(buf);
    }

    // POSIX: disable terminal echo around the read, restore on exit.
    // The block also brackets the byte loop so masking persists while
    // we collect input.
    var saved: ?std.posix.termios = null;
    defer {
        if (saved) |s| std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, s) catch {};
        if (saved != null) std.debug.print("\n", .{});
    }
    if (std.posix.tcgetattr(std.posix.STDIN_FILENO)) |orig| {
        saved = orig;
        var t = orig;
        t.lflag.ECHO = false;
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, t) catch {};
    } else |_| {
        // stdin is not a TTY (pipe or redirect); leave terminal alone.
    }
    return readLineBytes(buf);
}

fn readLineBytes(buf: []u8) ![]const u8 {
    var len: usize = 0;
    while (len < buf.len) {
        var one: [1]u8 = undefined;
        const n = try stdinReadByte(&one);
        if (n == 0) break;
        if (one[0] == '\n') break;
        if (one[0] == '\r') continue;
        buf[len] = one[0];
        len += 1;
    }
    return buf[0..len];
}

test "main module imports cora" {
    try std.testing.expect(@hasDecl(cora, "SecretBuf"));
    try std.testing.expect(@hasDecl(cora, "MemStore"));
    try std.testing.expect(@hasDecl(cora, "store"));
    try std.testing.expect(@hasDecl(cora, "secrets_codec"));
}

// Pull the CLI submodules into the exe test bucket so their `test {}`
// blocks run under `zig build test`. Without this reference, Zig's test
// runner skips them because the modules are only used at runtime, not
// from any test in this file.
test {
    _ = @import("cli/usage.zig");
}
