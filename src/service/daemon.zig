//! Persistent-service unit generators. Cora does not ship an auto-starting
//! daemon by design — the operator holds the passphrase, so the service
//! cannot come up unattended. What these emit is a *template* the operator
//! installs and starts manually (systemd `--user` on Linux, launchd
//! LaunchAgent on macOS); the unit runs `cr unlock --foreground`, which still
//! prompts for the passphrase on start. This keeps "the human holds the key"
//! intact while giving a supervised, restart-on-crash service.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// systemd user unit. `Type=simple` + `--foreground` so systemd tracks the
/// process directly. No `Restart=always`: an unlocked service that silently
/// re-derives keys unattended would defeat the passphrase model, so a crash
/// is left for the operator to notice and restart.
pub fn renderSystemdUnit(w: *Io.Writer, exe: []const u8, workdir: []const u8) !void {
    try w.print(
        \\[Unit]
        \\Description=Cora secret injection runtime
        \\After=default.target
        \\
        \\[Service]
        \\Type=simple
        \\WorkingDirectory={s}
        \\ExecStart={s} unlock --foreground
        \\# Passphrase is prompted on start; run `systemctl --user start cora`
        \\# from an interactive session, or wire in systemd-ask-password.
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    , .{ workdir, exe });
}

/// launchd LaunchAgent plist (macOS). RunAtLoad is intentionally false for
/// the same reason systemd gets no Restart: the service must not come up
/// without an interactive passphrase entry.
pub fn renderLaunchdPlist(w: *Io.Writer, exe: []const u8, workdir: []const u8) !void {
    try w.print(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
        \\  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key>
        \\  <string>dev.cora.agent</string>
        \\  <key>ProgramArguments</key>
        \\  <array>
        \\    <string>{s}</string>
        \\    <string>unlock</string>
        \\    <string>--foreground</string>
        \\  </array>
        \\  <key>WorkingDirectory</key>
        \\  <string>{s}</string>
        \\  <key>RunAtLoad</key>
        \\  <false/>
        \\</dict>
        \\</plist>
        \\
    , .{ exe, workdir });
}

/// True when this OS has a unit template. Windows has no user-service
/// template here yet; callers should check this before `renderForHost`.
pub fn hostSupported() bool {
    return builtin.os.tag == .linux or builtin.os.tag == .macos;
}

/// Emit the unit template appropriate for the current OS. Caller must have
/// confirmed `hostSupported()` first; an unsupported OS is unreachable.
pub fn renderForHost(w: *Io.Writer, exe: []const u8, workdir: []const u8) !void {
    switch (builtin.os.tag) {
        .linux => try renderSystemdUnit(w, exe, workdir),
        .macos => try renderLaunchdPlist(w, exe, workdir),
        else => unreachable,
    }
}

test "systemd unit carries ExecStart with --foreground and workdir" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try renderSystemdUnit(&aw.writer, "/usr/local/bin/cr", "/home/x/proj");
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "ExecStart=/usr/local/bin/cr unlock --foreground") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "WorkingDirectory=/home/x/proj") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[Service]") != null);
    // No unattended restart — the passphrase model forbids it.
    try std.testing.expect(std.mem.indexOf(u8, out, "Restart=always") == null);
}

test "launchd plist carries program args and RunAtLoad false" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try renderLaunchdPlist(&aw.writer, "/opt/cr", "/tmp/proj");
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "<string>/opt/cr</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<string>--foreground</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<string>/tmp/proj</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<key>RunAtLoad</key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<false/>") != null);
}
