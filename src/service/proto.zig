const std = @import("std");
const CoraError = @import("../error.zig").CoraError;

pub const protocol_version: u8 = 1;
pub const max_payload_len: u32 = 1 << 20;

pub const Op = enum(u8) {
    ping = 0x01,
    status = 0x02,
    lock = 0x03,
    task_declare = 0x04,
    spawn = 0x05,
    secrets_list = 0x06,
    policy_show = 0x07,
    err = 0x7f,
    _,
};

pub const StatusResp = struct {
    running: u8,
    secrets_count: u32,
    idle_remaining_ms: u64,

    pub const wire_len: usize = 1 + 4 + 8;

    pub fn encode(self: StatusResp, out: *[wire_len]u8) void {
        out[0] = self.running;
        std.mem.writeInt(u32, out[1..5], self.secrets_count, .little);
        std.mem.writeInt(u64, out[5..13], self.idle_remaining_ms, .little);
    }

    pub fn decode(bytes: []const u8) !StatusResp {
        if (bytes.len < wire_len) return CoraError.Io;
        return .{
            .running = bytes[0],
            .secrets_count = std.mem.readInt(u32, bytes[1..5], .little),
            .idle_remaining_ms = std.mem.readInt(u64, bytes[5..13], .little),
        };
    }
};

pub const SpawnResp = struct {
    child_pid: i32,
    exit_code: i32,

    pub const wire_len: usize = 8;

    pub fn encode(self: SpawnResp, out: *[wire_len]u8) void {
        std.mem.writeInt(i32, out[0..4], self.child_pid, .little);
        std.mem.writeInt(i32, out[4..8], self.exit_code, .little);
    }

    pub fn decode(bytes: []const u8) !SpawnResp {
        if (bytes.len < wire_len) return CoraError.Io;
        return .{
            .child_pid = std.mem.readInt(i32, bytes[0..4], .little),
            .exit_code = std.mem.readInt(i32, bytes[4..8], .little),
        };
    }
};

pub fn writeFrame(stream_writer: anytype, op: Op, payload: []const u8) !void {
    if (payload.len > max_payload_len) return CoraError.Io;
    var hdr: [6]u8 = undefined;
    hdr[0] = protocol_version;
    hdr[1] = @intFromEnum(op);
    std.mem.writeInt(u32, hdr[2..6], @intCast(payload.len), .little);
    try stream_writer.writeAll(&hdr);
    if (payload.len > 0) try stream_writer.writeAll(payload);
}

pub const Frame = struct {
    op: u8,
    payload: []u8,

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
    }
};

pub fn readFrame(stream_reader: anytype, allocator: std.mem.Allocator) !Frame {
    var hdr: [6]u8 = undefined;
    try stream_reader.readSliceAll(&hdr);
    if (hdr[0] != protocol_version) return CoraError.UnsupportedVersion;
    const len = std.mem.readInt(u32, hdr[2..6], .little);
    if (len > max_payload_len) return CoraError.Io;
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    if (len > 0) try stream_reader.readSliceAll(buf);
    return .{ .op = hdr[1], .payload = buf };
}

/// Encode SPAWN payload:
///   u16 task_name_len + task_name
///   u16 argv_count + repeated (u16 arg_len + arg_bytes)
pub fn encodeSpawnPayload(
    allocator: std.mem.Allocator,
    task_name: []const u8,
    argv: []const []const u8,
) ![]u8 {
    var total: usize = 2 + task_name.len + 2;
    for (argv) |a| total += 2 + a.len;

    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);

    var i: usize = 0;
    std.mem.writeInt(u16, out[i..][0..2], @intCast(task_name.len), .little);
    i += 2;
    @memcpy(out[i..][0..task_name.len], task_name);
    i += task_name.len;
    std.mem.writeInt(u16, out[i..][0..2], @intCast(argv.len), .little);
    i += 2;
    for (argv) |a| {
        std.mem.writeInt(u16, out[i..][0..2], @intCast(a.len), .little);
        i += 2;
        @memcpy(out[i..][0..a.len], a);
        i += a.len;
    }
    return out;
}

pub const ParsedSpawn = struct {
    task_name: []const u8,
    argv: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ParsedSpawn) void {
        self.allocator.free(self.argv);
    }
};

pub fn decodeSpawnPayload(allocator: std.mem.Allocator, payload: []const u8) !ParsedSpawn {
    if (payload.len < 4) return CoraError.Io;
    var i: usize = 0;
    const task_len = std.mem.readInt(u16, payload[i..][0..2], .little);
    i += 2;
    if (payload.len < i + task_len + 2) return CoraError.Io;
    const task_name = payload[i..][0..task_len];
    i += task_len;
    const argv_count = std.mem.readInt(u16, payload[i..][0..2], .little);
    i += 2;
    const argv = try allocator.alloc([]const u8, argv_count);
    errdefer allocator.free(argv);
    var k: usize = 0;
    while (k < argv_count) : (k += 1) {
        if (payload.len < i + 2) return CoraError.Io;
        const al = std.mem.readInt(u16, payload[i..][0..2], .little);
        i += 2;
        if (payload.len < i + al) return CoraError.Io;
        argv[k] = payload[i..][0..al];
        i += al;
    }
    return .{ .task_name = task_name, .argv = argv, .allocator = allocator };
}

/// Encode a flat list of names (secret keys, policy entries, etc.) as:
///   u16 count + repeated (u16 name_len + name_bytes)
/// Reused by `secrets_list` responses. Caller owns the returned slice.
pub fn encodeNameList(allocator: std.mem.Allocator, names: []const []const u8) ![]u8 {
    var total: usize = 2;
    for (names) |n| total += 2 + n.len;
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);

    var i: usize = 0;
    std.mem.writeInt(u16, out[i..][0..2], @intCast(names.len), .little);
    i += 2;
    for (names) |n| {
        std.mem.writeInt(u16, out[i..][0..2], @intCast(n.len), .little);
        i += 2;
        @memcpy(out[i..][0..n.len], n);
        i += n.len;
    }
    return out;
}

/// Iterator over a payload produced by `encodeNameList`. Returned name
/// slices alias the payload buffer — copy them if outliving the frame.
pub const NameListIter = struct {
    payload: []const u8,
    cursor: usize,
    remaining: u16,

    pub fn next(self: *NameListIter) ?[]const u8 {
        if (self.remaining == 0) return null;
        if (self.payload.len < self.cursor + 2) return null;
        const name_len = std.mem.readInt(u16, self.payload[self.cursor..][0..2], .little);
        self.cursor += 2;
        if (self.payload.len < self.cursor + name_len) return null;
        const name = self.payload[self.cursor..][0..name_len];
        self.cursor += name_len;
        self.remaining -= 1;
        return name;
    }
};

pub fn decodeNameList(payload: []const u8) !NameListIter {
    if (payload.len < 2) return CoraError.Io;
    const count = std.mem.readInt(u16, payload[0..2], .little);
    return .{ .payload = payload, .cursor = 2, .remaining = count };
}

test "writeFrame/readFrame roundtrip" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try writeFrame(&buf.writer, .status, "hello");

    const bytes = buf.written();
    var fbs: std.Io.Reader = .fixed(bytes);
    var f = try readFrame(&fbs, std.testing.allocator);
    defer f.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0x02), f.op);
    try std.testing.expectEqualStrings("hello", f.payload);
}

test "encodeSpawnPayload/decodeSpawnPayload roundtrip" {
    const args: []const []const u8 = &.{ "gh", "repo", "list" };
    const payload = try encodeSpawnPayload(std.testing.allocator, "github-sync", args);
    defer std.testing.allocator.free(payload);

    var parsed = try decodeSpawnPayload(std.testing.allocator, payload);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("github-sync", parsed.task_name);
    try std.testing.expectEqual(@as(usize, 3), parsed.argv.len);
    try std.testing.expectEqualStrings("gh", parsed.argv[0]);
    try std.testing.expectEqualStrings("repo", parsed.argv[1]);
    try std.testing.expectEqualStrings("list", parsed.argv[2]);
}

test "encodeNameList/decodeNameList roundtrip" {
    const names: []const []const u8 = &.{ "GH_TOKEN", "AWS_SECRET", "OPENAI_API_KEY" };
    const payload = try encodeNameList(std.testing.allocator, names);
    defer std.testing.allocator.free(payload);

    var iter = try decodeNameList(payload);
    try std.testing.expectEqualStrings("GH_TOKEN", iter.next().?);
    try std.testing.expectEqualStrings("AWS_SECRET", iter.next().?);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", iter.next().?);
    try std.testing.expect(iter.next() == null);
}

test "encodeNameList/decodeNameList handles empty list" {
    const empty: []const []const u8 = &.{};
    const payload = try encodeNameList(std.testing.allocator, empty);
    defer std.testing.allocator.free(payload);

    var iter = try decodeNameList(payload);
    try std.testing.expect(iter.next() == null);
}

test "StatusResp encode/decode roundtrip" {
    const original = StatusResp{ .running = 1, .secrets_count = 42, .idle_remaining_ms = 12345 };
    var buf: [StatusResp.wire_len]u8 = undefined;
    original.encode(&buf);
    const back = try StatusResp.decode(&buf);
    try std.testing.expectEqual(original.running, back.running);
    try std.testing.expectEqual(original.secrets_count, back.secrets_count);
    try std.testing.expectEqual(original.idle_remaining_ms, back.idle_remaining_ms);
}
