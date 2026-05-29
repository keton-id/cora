const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const cora = @import("cora");
const tui_menu = @import("tui/menu.zig");
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
        printUsage();
        return;
    }

    const sub = args[1];
    if (isSensitiveSub(sub)) printWindowsPreviewBanner();
    if (std.mem.eql(u8, sub, "version")) {
        const tag = if (builtin.os.tag == .windows) " [" ++ windows_preview_label ++ "]" else "";
        std.debug.print("cr {s} (commit {s}, built {s}){s}\n", .{
            build_options.version,
            build_options.commit,
            build_options.build_date,
            tag,
        });
        return;
    }
    if (std.mem.eql(u8, sub, "init")) {
        const path = if (args.len >= 3) args[2] else default_path;
        try cmdInit(arena, io, path);
        return;
    }
    if (std.mem.eql(u8, sub, "unlock")) {
        try cmdUnlock(arena, io, default_path, args);
        return;
    }
    if (std.mem.eql(u8, sub, "lock")) {
        try cmdLock(arena, io);
        return;
    }
    if (std.mem.eql(u8, sub, "status")) {
        try cmdStatus(arena, io);
        return;
    }
    if (std.mem.eql(u8, sub, "exec")) {
        try cmdExec(arena, io, args);
        return;
    }
    if (std.mem.eql(u8, sub, "audit")) {
        try cmdAudit(arena, io, args);
        return;
    }
    if (std.mem.eql(u8, sub, "tui")) {
        try tui_menu.run(arena, io);
        return;
    }
    if (std.mem.eql(u8, sub, "verify")) {
        try cmdVerify(args);
        return;
    }
    if (std.mem.eql(u8, sub, "policy")) {
        try cmdPolicy(arena, io, default_path, args);
        return;
    }
    if (std.mem.eql(u8, sub, "secrets")) {
        if (args.len < 3) {
            std.debug.print("usage: cr secrets <set|list|delete> [KEY]\n", .{});
            std.process.exit(1);
        }
        const action = args[2];
        if (std.mem.eql(u8, action, "set")) {
            if (args.len < 4) {
                std.debug.print("usage: cr secrets set KEY\n", .{});
                std.process.exit(1);
            }
            try cmdSecretsSet(arena, io, default_path, args[3]);
            return;
        }
        if (std.mem.eql(u8, action, "list")) {
            try cmdSecretsList(arena, io, default_path);
            return;
        }
        if (std.mem.eql(u8, action, "delete")) {
            if (args.len < 4) {
                std.debug.print("usage: cr secrets delete KEY\n", .{});
                std.process.exit(1);
            }
            try cmdSecretsDelete(arena, io, default_path, args[3]);
            return;
        }
        std.debug.print("unknown secrets action: {s}\n", .{action});
        std.process.exit(1);
    }

    std.debug.print("unknown subcommand: {s}\n", .{sub});
    printUsage();
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
        std.debug.print("usage: cr audit <tail|show> [opts]\n", .{});
        std.process.exit(1);
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

    const action = args[2];
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

    if (std.mem.eql(u8, action, "tail")) {
        const start = if (lines.items.len > n) lines.items.len - n else 0;
        for (lines.items[start..]) |line| std.debug.print("{s}\n", .{line});
    } else if (std.mem.eql(u8, action, "show")) {
        for (lines.items) |line| std.debug.print("{s}\n", .{line});
    } else {
        std.debug.print("unknown audit action: {s}\n", .{action});
        std.process.exit(1);
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
        std.debug.print("usage: cr policy <show|allow|deny> [path]\n", .{});
        std.process.exit(1);
    }
    const action = args[2];
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

    if (std.mem.eql(u8, action, "show")) {
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

    if (std.mem.eql(u8, action, "task")) {
        try cmdPolicyTask(allocator, io, path, passphrase, &pol, dec.secrets_plaintext, args);
        return;
    }

    if (args.len < 4) {
        std.debug.print("usage: cr policy {s} <path>\n", .{action});
        std.process.exit(1);
    }
    const target = args[3];

    var next_list: std.ArrayList([]const u8) = .empty;
    defer next_list.deinit(allocator);

    if (std.mem.eql(u8, action, "allow")) {
        for (pol.allowed_callers) |c| try next_list.append(allocator, c);
        for (pol.allowed_callers) |c| {
            if (std.mem.eql(u8, c, target)) {
                std.debug.print("already allowed: {s}\n", .{target});
                return;
            }
        }
        try next_list.append(allocator, target);
    } else if (std.mem.eql(u8, action, "deny")) {
        for (pol.allowed_callers) |c| {
            if (!std.mem.eql(u8, c, target)) try next_list.append(allocator, c);
        }
    } else {
        std.debug.print("unknown action: {s}\n", .{action});
        std.process.exit(1);
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

fn cmdPolicyTask(
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
    passphrase: []const u8,
    pol: *cora.policy.Policy,
    secrets_plaintext: []const u8,
    args: []const []const u8,
) !void {
    if (args.len < 4) {
        std.debug.print("usage: cr policy task <add|remove> NAME [SECRETS...]\n", .{});
        std.process.exit(1);
    }
    const sub = args[3];

    var next: std.ArrayList(cora.policy.Task) = .empty;
    defer next.deinit(allocator);

    if (std.mem.eql(u8, sub, "add")) {
        if (args.len < 5) {
            std.debug.print("usage: cr policy task add NAME [SECRETS...]\n", .{});
            std.process.exit(1);
        }
        const name = args[4];
        const secrets = args[5..];
        for (pol.tasks) |t| {
            if (!std.mem.eql(u8, t.name, name)) try next.append(allocator, t);
        }
        try next.append(allocator, .{ .name = name, .allowed_secrets = secrets });
    } else if (std.mem.eql(u8, sub, "remove")) {
        if (args.len < 5) {
            std.debug.print("usage: cr policy task remove NAME\n", .{});
            std.process.exit(1);
        }
        const name = args[4];
        for (pol.tasks) |t| {
            if (!std.mem.eql(u8, t.name, name)) try next.append(allocator, t);
        }
    } else {
        std.debug.print("unknown task action: {s}\n", .{sub});
        std.process.exit(1);
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

fn printUsage() void {
    std.debug.print(
        \\cr — Cora secret runtime
        \\
        \\Usage:
        \\  cr version
        \\  cr init [path]               Create encrypted cora.zon
        \\  cr secrets set KEY           Add/update secret value (prompts)
        \\  cr secrets list              List secret names (no values)
        \\  cr secrets delete KEY        Remove secret
        \\  cr unlock [--foreground]     Start background service
        \\  cr lock                      Stop service, zero memory
        \\  cr status                    Show service state
        \\  cr verify --pid PID          Resolve binary path of a pid (debug)
        \\  cr policy show               Show current policy
        \\  cr policy allow PATH         Add binary to allowed_callers
        \\  cr policy deny PATH          Remove binary from allowed_callers
        \\  cr policy task add NAME SECRETS...   Define task with allowed secrets
        \\  cr policy task remove NAME           Remove task
        \\  cr exec TASK -- argv...      Spawn subprocess with task's secrets injected
        \\  cr audit tail [-n N]         Show last N audit entries
        \\  cr audit show [--task NAME]  Show full audit log (optionally filtered)
        \\  cr tui                       Launch interactive TUI menu
        \\
        \\Coming next:
        \\  audit  tui  agent invocation
        \\
    , .{});
}

test "main module imports cora" {
    try std.testing.expect(@hasDecl(cora, "SecretBuf"));
    try std.testing.expect(@hasDecl(cora, "MemStore"));
    try std.testing.expect(@hasDecl(cora, "store"));
    try std.testing.expect(@hasDecl(cora, "secrets_codec"));
}
