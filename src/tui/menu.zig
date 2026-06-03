const std = @import("std");
const Io = std.Io;
const cora = @import("cora");
const vaxis = @import("vaxis");

const View = enum(u8) {
    dashboard,
    audit,
    secrets,
    lock,
};

const Modal = union(enum) {
    none,
    confirm_lock,
    passphrase,
};

const StatusSnapshot = struct {
    running: bool = false,
    service_reachable: bool = false,
    secrets_count: u32 = 0,
    idle_remaining_ms: u64 = 0,
};

const theme = struct {
    const ink = vaxis.Color.rgbFromUint(0xE5E7EB);
    const muted = vaxis.Color.rgbFromUint(0x94A3B8);
    const accent = vaxis.Color.rgbFromUint(0x22C55E);
    const accent_soft = vaxis.Color.rgbFromUint(0x123524);
    const warn = vaxis.Color.rgbFromUint(0xF59E0B);
    const danger = vaxis.Color.rgbFromUint(0xF87171);
    const panel = vaxis.Color.rgbFromUint(0x0F172A);
    const panel_alt = vaxis.Color.rgbFromUint(0x111827);
    const chrome = vaxis.Color.rgbFromUint(0x1E293B);
    const overlay = vaxis.Color.rgbFromUint(0x020617);
};

pub fn run(_: std.mem.Allocator, io: Io) !void {
    var state_alloc = std.heap.DebugAllocator(.{}){};
    defer _ = state_alloc.deinit();
    const allocator = state_alloc.allocator();

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var tty_buf: [32]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();

    var vx = try vaxis.init(io, allocator, &env_map, .{});
    defer vx.deinit(allocator, tty.writer());

    var loop: vaxis.Loop(vaxis.Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    var app = try App.init(allocator, io);
    defer app.deinit();
    try app.refreshAll();

    try draw(&app, &vx);
    try vx.render(tty.writer());

    while (!app.should_quit) {
        const event = try loop.nextEvent();
        switch (event) {
            .winsize => |winsize| {
                try vx.resize(allocator, tty.writer(), winsize);
                app.clampScrolls();
                try draw(&app, &vx);
                try vx.render(tty.writer());
            },
            .key_press => |key| {
                try app.handleKey(key);
                if (app.should_quit) break;
                try draw(&app, &vx);
                try vx.render(tty.writer());
            },
            else => {},
        }
    }
}

const App = struct {
    allocator: std.mem.Allocator,
    io: Io,
    active_view: View = .dashboard,
    modal: Modal = .none,
    should_quit: bool = false,

    status: StatusSnapshot = .{},
    socket_path: [128]u8 = undefined,
    socket_path_len: usize = 0,
    has_config: bool = false,

    audit_lines: std.ArrayList([]u8) = .empty,
    audit_scroll: usize = 0,

    secret_names: std.ArrayList([]u8) = .empty,
    secrets_loaded: bool = false,
    secrets_scroll: usize = 0,

    passphrase_buf: [256]u8 = [_]u8{0} ** 256,
    passphrase_len: usize = 0,

    message_buf: [256]u8 = [_]u8{0} ** 256,
    message_len: usize = 0,

    fn init(allocator: std.mem.Allocator, io: Io) !App {
        var app: App = .{
            .allocator = allocator,
            .io = io,
        };
        try app.refreshSocketPath();
        app.setMessage("TUI ready. Use arrows or j/k to navigate.");
        return app;
    }

    fn deinit(self: *App) void {
        self.freeLines(&self.audit_lines);
        self.freeLines(&self.secret_names);
        self.secureClearPassphrase();
    }

    fn handleKey(self: *App, key: vaxis.Key) !void {
        switch (self.modal) {
            .confirm_lock => return self.handleConfirmLockKey(key),
            .passphrase => return self.handlePassphraseKey(key),
            .none => {},
        }

        if (key.matches('q', .{}) or key.matches(vaxis.Key.escape, .{})) {
            self.should_quit = true;
            return;
        }
        if (key.matches('r', .{})) {
            try self.refreshActiveView();
            return;
        }
        if (key.matches('l', .{})) {
            if (!self.serviceRunning()) {
                self.setMessage("Service already locked.");
                return;
            }
            self.modal = .confirm_lock;
            self.setMessage("Press Enter to confirm lock.");
            return;
        }
        if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            self.selectPrevView();
            return;
        }
        if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            self.selectNextView();
            return;
        }
        if (key.matches(vaxis.Key.page_up, .{}) or key.matches('u', .{ .ctrl = true })) {
            self.scrollActiveView(-8);
            return;
        }
        if (key.matches(vaxis.Key.page_down, .{}) or key.matches('d', .{ .ctrl = true })) {
            self.scrollActiveView(8);
            return;
        }
        if (key.matches('g', .{})) {
            self.scrollToTop();
            return;
        }
        if (key.matches('G', .{ .shift = true })) {
            self.scrollToBottom();
            return;
        }
        if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.kp_enter, .{})) {
            try self.activateCurrentView();
        }
    }

    fn handleConfirmLockKey(self: *App, key: vaxis.Key) !void {
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
            self.modal = .none;
            self.setMessage("Lock canceled.");
            return;
        }
        if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.kp_enter, .{})) {
            try self.lockService();
            self.modal = .none;
        }
    }

    fn handlePassphraseKey(self: *App, key: vaxis.Key) !void {
        if (key.matches(vaxis.Key.escape, .{})) {
            self.modal = .none;
            self.secureClearPassphrase();
            self.setMessage("Secrets load canceled.");
            return;
        }
        if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.kp_enter, .{})) {
            try self.loadSecrets();
            self.modal = .none;
            self.secureClearPassphrase();
            return;
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.passphrase_len > 0) {
                self.passphrase_len -= 1;
                self.passphrase_buf[self.passphrase_len] = 0;
            }
            return;
        }
        if (key.mods.ctrl or key.mods.alt or key.mods.super or key.mods.meta) return;
        const text = key.text orelse return;
        for (text) |byte| {
            if (byte < 0x20 or byte == 0x7f) continue;
            if (self.passphrase_len >= self.passphrase_buf.len) break;
            self.passphrase_buf[self.passphrase_len] = byte;
            self.passphrase_len += 1;
        }
    }

    fn refreshAll(self: *App) !void {
        try self.refreshSocketPath();
        try self.refreshStatus();
        try self.refreshAudit();
        try self.refreshConfigPresence();
    }

    fn refreshActiveView(self: *App) !void {
        switch (self.active_view) {
            .dashboard => {
                try self.refreshStatus();
                try self.refreshConfigPresence();
                self.setMessage("Dashboard refreshed.");
            },
            .audit => {
                try self.refreshAudit();
                self.setMessage("Audit log refreshed.");
            },
            .secrets => {
                try self.refreshConfigPresence();
                if (self.secrets_loaded) {
                    try self.loadSecrets();
                } else {
                    self.setMessage("Secrets panel refreshed.");
                }
            },
            .lock => self.setMessage("Lock pane ready."),
        }
    }

    fn refreshSocketPath(self: *App) !void {
        const path = try cora.service.defaultSocketPath(&self.socket_path);
        self.socket_path_len = path.len;
    }

    fn refreshStatus(self: *App) !void {
        const sock_path = self.socket_path[0..self.socket_path_len];
        if (!cora.client.isRunning(self.io, sock_path)) {
            self.status = .{};
            return;
        }

        const service_status = cora.client.status(self.allocator, self.io, sock_path) catch {
            self.status = .{};
            return;
        };
        self.status = .{
            .running = service_status.running != 0,
            .service_reachable = true,
            .secrets_count = service_status.secrets_count,
            .idle_remaining_ms = service_status.idle_remaining_ms,
        };
    }

    fn refreshAudit(self: *App) !void {
        self.freeLines(&self.audit_lines);

        const path = cora.audit.defaultPathAlloc(self.allocator) catch {
            self.setMessage("Unable to resolve audit path.");
            return;
        };
        defer self.allocator.free(path);

        const cwd = Io.Dir.cwd();
        const contents = cwd.readFileAlloc(self.io, path, self.allocator, .limited(16 * 1024 * 1024)) catch {
            self.setMessageFmt("No audit log at {s}", .{path});
            return;
        };
        defer self.allocator.free(contents);

        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            try self.audit_lines.append(self.allocator, try self.allocator.dupe(u8, line));
        }
        self.audit_scroll = 0;
    }

    fn refreshConfigPresence(self: *App) !void {
        const cwd = Io.Dir.cwd();
        cwd.access(self.io, "cora.zon", .{}) catch {
            self.has_config = false;
            return;
        };
        self.has_config = true;
    }

    fn loadSecrets(self: *App) !void {
        try self.refreshConfigPresence();
        if (!self.has_config) {
            self.secrets_loaded = false;
            self.setMessage("No cora.zon found in current directory.");
            return;
        }

        self.freeLines(&self.secret_names);

        var store = cora.MemStore.init(self.allocator);
        defer store.deinit();

        const cwd = Io.Dir.cwd();
        const passphrase = self.passphrase_buf[0..self.passphrase_len];
        cora.store.loadSecrets(self.allocator, self.io, cwd, "cora.zon", passphrase, &store) catch |err| {
            self.secrets_loaded = false;
            self.setMessageFmt("Secrets load failed: {s}", .{@errorName(err)});
            return;
        };

        var it = store.map.keyIterator();
        while (it.next()) |key| {
            try self.secret_names.append(self.allocator, try self.allocator.dupe(u8, key.*));
        }

        self.secrets_loaded = true;
        self.secrets_scroll = 0;
        self.setMessageFmt("Loaded {d} secret names.", .{self.secret_names.items.len});
    }

    fn lockService(self: *App) !void {
        const sock_path = self.socket_path[0..self.socket_path_len];
        if (!cora.client.isRunning(self.io, sock_path)) {
            self.setMessage("Service is not running.");
            return;
        }
        cora.client.lock(self.allocator, self.io, sock_path) catch |err| {
            self.setMessageFmt("Lock failed: {s}", .{@errorName(err)});
            return;
        };
        try self.refreshStatus();
        self.setMessage("Service locked.");
    }

    fn activateCurrentView(self: *App) !void {
        switch (self.active_view) {
            .dashboard => try self.refreshStatus(),
            .audit => try self.refreshAudit(),
            .secrets => {
                self.modal = .passphrase;
                self.secureClearPassphrase();
                self.setMessage("Enter passphrase to load secret names.");
            },
            .lock => {
                if (!self.serviceRunning()) {
                    self.setMessage("Service already locked.");
                    return;
                }
                self.modal = .confirm_lock;
                self.setMessage("Press Enter to confirm lock.");
            },
        }
    }

    fn selectPrevView(self: *App) void {
        const idx = @intFromEnum(self.active_view);
        self.active_view = @enumFromInt(if (idx == 0) 3 else idx - 1);
    }

    fn selectNextView(self: *App) void {
        const idx = @intFromEnum(self.active_view);
        self.active_view = @enumFromInt(if (idx == 3) 0 else idx + 1);
    }

    fn scrollActiveView(self: *App, delta: isize) void {
        switch (self.active_view) {
            .audit => self.audit_scroll = adjustScroll(self.audit_scroll, self.audit_lines.items.len, delta),
            .secrets => self.secrets_scroll = adjustScroll(self.secrets_scroll, self.secret_names.items.len, delta),
            else => {},
        }
    }

    fn scrollToTop(self: *App) void {
        switch (self.active_view) {
            .audit => self.audit_scroll = 0,
            .secrets => self.secrets_scroll = 0,
            else => {},
        }
    }

    fn scrollToBottom(self: *App) void {
        switch (self.active_view) {
            .audit => self.audit_scroll = if (self.audit_lines.items.len == 0) 0 else self.audit_lines.items.len - 1,
            .secrets => self.secrets_scroll = if (self.secret_names.items.len == 0) 0 else self.secret_names.items.len - 1,
            else => {},
        }
    }

    fn clampScrolls(self: *App) void {
        if (self.audit_scroll > self.audit_lines.items.len) self.audit_scroll = self.audit_lines.items.len;
        if (self.secrets_scroll > self.secret_names.items.len) self.secrets_scroll = self.secret_names.items.len;
    }

    fn freeLines(self: *App, lines: *std.ArrayList([]u8)) void {
        for (lines.items) |line| self.allocator.free(line);
        lines.deinit(self.allocator);
        lines.* = .empty;
    }

    fn setMessage(self: *App, text: []const u8) void {
        const len = @min(text.len, self.message_buf.len);
        @memcpy(self.message_buf[0..len], text[0..len]);
        self.message_len = len;
    }

    fn setMessageFmt(self: *App, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&self.message_buf, fmt, args) catch {
            self.message_len = 0;
            return;
        };
        self.message_len = msg.len;
    }

    fn message(self: *const App) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    fn serviceRunning(self: *App) bool {
        const sock_path = self.socket_path[0..self.socket_path_len];
        return cora.client.isRunning(self.io, sock_path);
    }

    fn secureClearPassphrase(self: *App) void {
        std.crypto.secureZero(u8, &self.passphrase_buf);
        self.passphrase_len = 0;
    }
};

fn draw(app: *App, vx: *vaxis.Vaxis) !void {
    var root = vx.window();
    root.clear();
    root.hideCursor();

    if (root.width < 72 or root.height < 24) {
        drawCompact(root);
        return;
    }

    const bg_cell: vaxis.Cell = .{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .bg = theme.overlay },
    };
    root.fill(bg_cell);

    const header = root.child(.{
        .x_off = 1,
        .y_off = 0,
        .width = root.width - 2,
        .height = 3,
        .border = panelBorder(theme.chrome),
    });
    const body = root.child(.{
        .x_off = 1,
        .y_off = 3,
        .width = root.width - 2,
        .height = root.height - 7,
    });
    const footer = root.child(.{
        .x_off = 1,
        .y_off = root.height - 4,
        .width = root.width - 2,
        .height = 4,
        .border = panelBorder(theme.chrome),
    });

    const sidebar_width: u16 = @min(24, body.width / 3);
    const sidebar = body.child(.{
        .width = sidebar_width,
        .height = body.height,
        .border = panelBorder(theme.chrome),
    });
    const content = body.child(.{
        .x_off = @intCast(sidebar_width + 1),
        .width = body.width -| (sidebar_width + 1),
        .height = body.height,
        .border = panelBorder(theme.chrome),
    });

    drawHeader(app, header);
    drawSidebar(app, sidebar);
    drawContent(app, content);
    drawFooter(app, footer);

    switch (app.modal) {
        .confirm_lock => drawConfirmModal(root),
        .passphrase => drawPassphraseModal(app, root),
        .none => {},
    }
}

fn drawCompact(root: vaxis.Window) void {
    const warning = "Terminal too small for pane layout. Resize to at least 72x24.";
    _ = root.printSegment(.{
        .text = warning,
        .style = .{ .fg = theme.warn, .bold = true },
    }, .{
        .row_offset = root.height / 2,
        .col_offset = 2,
        .wrap = .word,
    });
}

fn drawHeader(app: *const App, win: vaxis.Window) void {
    const title = "Cora Control Center";
    const subtitle = "Pane-based TUI for status, audit, secrets, and service actions";
    printText(win, 0, 0, title, .{ .fg = theme.ink, .bold = true });
    printText(win, 0, 1, subtitle, .{ .fg = theme.muted });

    const status_style: vaxis.Style = if (app.status.service_reachable)
        .{ .fg = if (app.status.running) theme.accent else theme.warn, .bold = true }
    else
        .{ .fg = theme.danger, .bold = true };
    const status_text = if (app.status.service_reachable)
        (if (app.status.running) "Service online" else "Service reachable")
    else
        "Service offline";
    const offset = win.width -| 18;
    printText(win, offset, 0, status_text, status_style);
}

fn drawSidebar(app: *const App, win: vaxis.Window) void {
    const items = [_]struct { view: View, label: []const u8, hint: []const u8 }{
        .{ .view = .dashboard, .label = "Dashboard", .hint = "overview" },
        .{ .view = .audit, .label = "Audit Log", .hint = "scrollable" },
        .{ .view = .secrets, .label = "Secrets", .hint = "secure names" },
        .{ .view = .lock, .label = "Lock Service", .hint = "confirm action" },
    };

    printText(win, 0, 0, "Navigation", .{ .fg = theme.muted, .bold = true });
    for (items, 0..) |item, idx| {
        const row: u16 = @intCast(2 + idx * 3);
        if (row + 2 > win.height) break;
        const selected = item.view == app.active_view;
        const item_win = win.child(.{
            .y_off = @intCast(row),
            .width = win.width,
            .height = 2,
        });
        if (selected) {
            item_win.fill(.{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = .{ .bg = theme.accent_soft },
            });
        }
        printText(item_win, 0, 0, item.label, if (selected)
            .{ .fg = theme.accent, .bold = true }
        else
            .{ .fg = theme.ink });
        printText(item_win, 0, 1, item.hint, .{ .fg = theme.muted });
    }
}

fn drawContent(app: *const App, win: vaxis.Window) void {
    switch (app.active_view) {
        .dashboard => drawDashboard(app, win),
        .audit => drawAudit(app, win),
        .secrets => drawSecrets(app, win),
        .lock => drawLock(app, win),
    }
}

fn drawDashboard(app: *const App, win: vaxis.Window) void {
    printPaneTitle(win, "Dashboard", "Live service state and config snapshot");
    drawStatCard(win, 0, 3, "Service", if (app.status.service_reachable)
        (if (app.status.running) "Running" else "Reachable")
    else
        "Offline", if (app.status.service_reachable) theme.accent else theme.danger);

    var count_buf: [32]u8 = undefined;
    const count_text = std.fmt.bufPrint(&count_buf, "{d}", .{app.status.secrets_count}) catch "0";
    drawStatCard(win, 22, 3, "Secrets", count_text, theme.ink);

    var idle_buf: [32]u8 = undefined;
    const idle_text = std.fmt.bufPrint(&idle_buf, "{d} ms", .{app.status.idle_remaining_ms}) catch "n/a";
    drawStatCard(win, 44, 3, "Idle TTL", idle_text, theme.ink);

    const config_text = if (app.has_config) "cora.zon detected" else "no cora.zon in cwd";
    drawStatCard(win, 0, 9, "Config", config_text, if (app.has_config) theme.accent else theme.warn);

    printText(win, 0, 15, "Socket Path", .{ .fg = theme.muted, .bold = true });
    printText(win, 0, 16, app.socket_path[0..app.socket_path_len], .{ .fg = theme.ink });

    printText(win, 0, 19, "Quick Actions", .{ .fg = theme.muted, .bold = true });
    printText(win, 0, 20, "r refresh dashboard, down opens audit, Enter on Lock Service opens confirm modal", .{ .fg = theme.ink });
}

fn drawAudit(app: *const App, win: vaxis.Window) void {
    printPaneTitle(win, "Audit Log", "PageUp/PageDown or Ctrl+u/Ctrl+d to scroll");

    if (app.audit_lines.items.len == 0) {
        printText(win, 0, 3, "No audit entries found.", .{ .fg = theme.warn });
        return;
    }

    const visible_rows = win.height -| 5;
    const start = clampWindowStart(app.audit_scroll, app.audit_lines.items.len, visible_rows);
    const end = @min(start + visible_rows, app.audit_lines.items.len);

    var row: u16 = 3;
    for (app.audit_lines.items[start..end]) |line| {
        printText(win, 0, row, line, .{ .fg = theme.ink });
        row += 1;
    }

    var footer_buf: [96]u8 = undefined;
    const footer = std.fmt.bufPrint(&footer_buf, "Showing {d}-{d} of {d}", .{
        start + 1,
        end,
        app.audit_lines.items.len,
    }) catch "";
    printText(win, 0, win.height - 1, footer, .{ .fg = theme.muted });
}

fn drawSecrets(app: *const App, win: vaxis.Window) void {
    printPaneTitle(win, "Secrets", "Enter loads names using passphrase modal");

    if (!app.has_config) {
        printText(win, 0, 3, "No cora.zon in current directory.", .{ .fg = theme.warn });
        return;
    }

    if (!app.secrets_loaded) {
        printText(win, 0, 3, "Secret names are not loaded yet.", .{ .fg = theme.ink });
        printText(win, 0, 5, "Press Enter to provide passphrase and decrypt names.", .{ .fg = theme.muted });
        return;
    }

    if (app.secret_names.items.len == 0) {
        printText(win, 0, 3, "No secrets stored.", .{ .fg = theme.warn });
        return;
    }

    const visible_rows = win.height -| 5;
    const start = clampWindowStart(app.secrets_scroll, app.secret_names.items.len, visible_rows);
    const end = @min(start + visible_rows, app.secret_names.items.len);

    var row: u16 = 3;
    for (app.secret_names.items[start..end], start..) |name, idx| {
        var line_buf: [192]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{d: >3}. {s}", .{ idx + 1, name }) catch name;
        printText(win, 0, row, line, .{ .fg = theme.ink });
        row += 1;
    }

    var footer_buf: [96]u8 = undefined;
    const footer = std.fmt.bufPrint(&footer_buf, "Showing {d}-{d} of {d}", .{
        start + 1,
        end,
        app.secret_names.items.len,
    }) catch "";
    printText(win, 0, win.height - 1, footer, .{ .fg = theme.muted });
}

fn drawLock(app: *const App, win: vaxis.Window) void {
    _ = app;
    printPaneTitle(win, "Lock Service", "Enter or l opens confirmation modal");
    printText(win, 0, 4, "This action clears the unlocked service state immediately.", .{ .fg = theme.ink });
    printText(win, 0, 6, "Use this before leaving the terminal or switching tasks.", .{ .fg = theme.muted });
    printText(win, 0, 9, "[Enter] Confirm lock", .{ .fg = theme.accent, .bold = true });
    printText(win, 0, 10, "[Esc] Cancel", .{ .fg = theme.muted });
}

fn drawFooter(app: *const App, win: vaxis.Window) void {
    printText(win, 0, 0, "Hotkeys", .{ .fg = theme.muted, .bold = true });
    printText(win, 0, 1, "j/k or arrows navigate  Enter open  PgUp/PgDn scroll  r refresh  l lock  q quit", .{ .fg = theme.ink });
    printText(win, 0, 2, app.message(), .{ .fg = theme.muted });
}

fn drawConfirmModal(root: vaxis.Window) void {
    const width: u16 = @min(52, root.width -| 6);
    const height: u16 = 8;
    const x: i17 = @intCast((root.width - width) / 2);
    const y: i17 = @intCast((root.height - height) / 2);
    const modal = root.child(.{
        .x_off = x,
        .y_off = y,
        .width = width,
        .height = height,
        .border = panelBorder(theme.warn),
    });
    modal.fill(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .bg = theme.panel_alt },
    });
    printText(modal, 0, 0, "Confirm Lock", .{ .fg = theme.warn, .bold = true });
    printText(modal, 0, 2, "Lock the running service and clear its active state?", .{ .fg = theme.ink });
    printText(modal, 0, 4, "Enter confirm  Esc cancel", .{ .fg = theme.muted });
}

fn drawPassphraseModal(app: *const App, root: vaxis.Window) void {
    const width: u16 = @min(60, root.width -| 6);
    const height: u16 = 9;
    const x: i17 = @intCast((root.width - width) / 2);
    const y: i17 = @intCast((root.height - height) / 2);
    const modal = root.child(.{
        .x_off = x,
        .y_off = y,
        .width = width,
        .height = height,
        .border = panelBorder(theme.accent),
    });
    modal.fill(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .bg = theme.panel_alt },
    });
    printText(modal, 0, 0, "Unlock Secret Names", .{ .fg = theme.accent, .bold = true });
    printText(modal, 0, 2, "Passphrase", .{ .fg = theme.muted });

    const input = modal.child(.{
        .y_off = 3,
        .width = modal.width,
        .height = 3,
        .border = panelBorder(theme.chrome),
    });
    input.fill(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .bg = theme.panel },
    });

    var mask_buf: [256]u8 = undefined;
    @memset(&mask_buf, '*');
    const masked = mask_buf[0..app.passphrase_len];
    printText(input, 0, 0, masked, .{ .fg = theme.ink });
    input.showCursor(@intCast(app.passphrase_len), 0);
    input.setCursorShape(.beam);

    printText(modal, 0, 6, "Enter load  Esc cancel", .{ .fg = theme.muted });
}

fn drawStatCard(win: vaxis.Window, x: u16, y: u16, label: []const u8, value: []const u8, value_color: vaxis.Color) void {
    const width: u16 = @min(20, win.width -| x);
    if (width < 10) return;
    const card = win.child(.{
        .x_off = @intCast(x),
        .y_off = @intCast(y),
        .width = width,
        .height = 4,
        .border = panelBorder(theme.chrome),
    });
    card.fill(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .bg = theme.panel },
    });
    printText(card, 0, 0, label, .{ .fg = theme.muted });
    printText(card, 0, 1, value, .{ .fg = value_color, .bold = true });
}

fn printPaneTitle(win: vaxis.Window, title: []const u8, subtitle: []const u8) void {
    printText(win, 0, 0, title, .{ .fg = theme.ink, .bold = true });
    printText(win, 0, 1, subtitle, .{ .fg = theme.muted });
}

fn printText(win: vaxis.Window, col: u16, row: u16, text: []const u8, style: vaxis.Style) void {
    _ = win.printSegment(.{ .text = text, .style = style }, .{
        .row_offset = row,
        .col_offset = col,
        .wrap = .word,
    });
}

fn panelBorder(color: vaxis.Color) vaxis.Window.BorderOptions {
    return .{
        .where = .all,
        .style = .{ .fg = color },
        .glyphs = .single_square,
    };
}

fn adjustScroll(current: usize, total: usize, delta: isize) usize {
    if (delta == 0 or total == 0) return 0;
    if (delta > 0) {
        const amount: usize = @intCast(delta);
        return @min(current + amount, total - 1);
    }
    const amount: usize = @intCast(-delta);
    return current -| amount;
}

fn clampWindowStart(scroll: usize, total: usize, visible_rows: u16) usize {
    if (total == 0) return 0;
    const visible: usize = @max(@as(usize, visible_rows), 1);
    if (total <= visible) return 0;
    return @min(scroll, total - visible);
}
