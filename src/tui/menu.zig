const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const cora = @import("cora");
const vaxis = @import("vaxis");

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

const esc_clear = "\x1b[2J\x1b[H";
const esc_bold = "\x1b[1m";
const esc_dim = "\x1b[2m";
const esc_reset = "\x1b[0m";
const esc_cyan = "\x1b[36m";
const esc_yellow = "\x1b[33m";
const esc_green = "\x1b[32m";
const esc_red = "\x1b[31m";

const Action = enum {
    status,
    audit,
    secrets_list,
    lock,
    quit,
};

pub fn run(allocator: std.mem.Allocator, io: Io) !void {
    while (true) {
        try draw(allocator, io);
        const choice = readChoice() orelse continue;
        switch (choice) {
            .status => try showStatus(allocator, io),
            .audit => try showAudit(allocator, io),
            .secrets_list => try showSecretsList(allocator, io),
            .lock => try doLock(allocator, io),
            .quit => return,
        }
        try pause();
    }
}

fn draw(allocator: std.mem.Allocator, io: Io) !void {
    std.debug.print("{s}", .{esc_clear});
    std.debug.print("{s}{s}Cora TUI{s} {s}— v0.0.0{s}\n", .{ esc_bold, esc_cyan, esc_reset, esc_dim, esc_reset });
    std.debug.print("{s}┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄{s}\n", .{ esc_dim, esc_reset });

    var sock_buf: [128]u8 = undefined;
    const sock_path = try cora.service.defaultSocketPath(&sock_buf);
    if (cora.client.isRunning(io, sock_path)) {
        const s = cora.client.status(allocator, io, sock_path) catch {
            std.debug.print("{s}service: ?{s}\n", .{ esc_yellow, esc_reset });
            renderMenu();
            return;
        };
        std.debug.print("{s}● running{s}  secrets: {d}  idle: {d} ms\n", .{ esc_green, esc_reset, s.secrets_count, s.idle_remaining_ms });
    } else {
        std.debug.print("{s}○ not running{s}  (run `cr unlock` outside TUI)\n", .{ esc_red, esc_reset });
    }
    std.debug.print("\n", .{});
    renderMenu();
}

fn renderMenu() void {
    std.debug.print("  [1] Status detail\n", .{});
    std.debug.print("  [2] Audit log (tail 20)\n", .{});
    std.debug.print("  [3] Secrets list\n", .{});
    std.debug.print("  [4] Lock service\n", .{});
    std.debug.print("  [q] Quit\n\n", .{});
    std.debug.print("> ", .{});
}

fn readChoice() ?Action {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        var one: [1]u8 = undefined;
        const n = stdinReadByte(&one) catch return null;
        if (n == 0) return .quit;
        if (one[0] == '\n') break;
        if (one[0] == '\r') continue;
        buf[len] = one[0];
        len += 1;
    }
    const line = buf[0..len];
    if (line.len == 0) return null;
    return switch (line[0]) {
        '1' => .status,
        '2' => .audit,
        '3' => .secrets_list,
        '4' => .lock,
        'q', 'Q' => .quit,
        else => null,
    };
}

fn showStatus(allocator: std.mem.Allocator, io: Io) !void {
    std.debug.print("\n", .{});
    var sock_buf: [128]u8 = undefined;
    const sock_path = try cora.service.defaultSocketPath(&sock_buf);
    if (!cora.client.isRunning(io, sock_path)) {
        std.debug.print("{s}service not running{s}\n", .{ esc_red, esc_reset });
        return;
    }
    const s = try cora.client.status(allocator, io, sock_path);
    std.debug.print("running:       {d}\n", .{s.running});
    std.debug.print("secrets count: {d}\n", .{s.secrets_count});
    std.debug.print("idle remain:   {d} ms\n", .{s.idle_remaining_ms});
}

fn showAudit(allocator: std.mem.Allocator, io: Io) !void {
    std.debug.print("\n", .{});
    const path = try cora.audit.defaultPathAlloc(allocator);
    defer allocator.free(path);
    const cwd = Io.Dir.cwd();
    const contents = cwd.readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch {
        std.debug.print("{s}no audit log at {s}{s}\n", .{ esc_yellow, path, esc_reset });
        return;
    };
    defer allocator.free(contents);

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| if (line.len > 0) try lines.append(allocator, line);

    const start = if (lines.items.len > 20) lines.items.len - 20 else 0;
    for (lines.items[start..]) |line| std.debug.print("{s}\n", .{line});
}

fn showSecretsList(allocator: std.mem.Allocator, io: Io) !void {
    std.debug.print("\n", .{});
    const cwd = Io.Dir.cwd();
    cwd.access(io, "cora.zon", .{}) catch {
        std.debug.print("{s}no cora.zon in cwd{s}\n", .{ esc_red, esc_reset });
        return;
    };

    var pass_buf: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &pass_buf);
    std.debug.print("Passphrase: ", .{});
    var pass_len: usize = 0;
    while (pass_len < pass_buf.len) {
        var one: [1]u8 = undefined;
        const n = stdinReadByte(&one) catch break;
        if (n == 0 or one[0] == '\n') break;
        if (one[0] == '\r') continue;
        pass_buf[pass_len] = one[0];
        pass_len += 1;
    }
    const passphrase = pass_buf[0..pass_len];

    var store = cora.MemStore.init(allocator);
    defer store.deinit();
    cora.store.loadSecrets(allocator, io, cwd, "cora.zon", passphrase, &store) catch |err| {
        std.debug.print("{s}{s}{s}\n", .{ esc_red, @errorName(err), esc_reset });
        return;
    };

    if (store.count() == 0) {
        std.debug.print("(no secrets)\n", .{});
        return;
    }
    var it = store.map.keyIterator();
    while (it.next()) |k| std.debug.print("  • {s}\n", .{k.*});
}

fn doLock(allocator: std.mem.Allocator, io: Io) !void {
    std.debug.print("\n", .{});
    var sock_buf: [128]u8 = undefined;
    const sock_path = try cora.service.defaultSocketPath(&sock_buf);
    if (!cora.client.isRunning(io, sock_path)) {
        std.debug.print("{s}service not running{s}\n", .{ esc_red, esc_reset });
        return;
    }
    try cora.client.lock(allocator, io, sock_path);
    std.debug.print("{s}locked{s}\n", .{ esc_green, esc_reset });
}

fn pause() !void {
    std.debug.print("\n{s}[enter to continue]{s} ", .{ esc_dim, esc_reset });
    var one: [1]u8 = undefined;
    while (true) {
        const n = stdinReadByte(&one) catch return;
        if (n == 0 or one[0] == '\n') return;
    }
}

// libvaxis kept as a future-use dep for full screen drawing (onboard widget,
// scrollable audit viewer, secret manager). Reference it so the build wires
// it in; current TUI is line-based ANSI to keep first ship simple.
comptime {
    _ = vaxis.logo;
}
