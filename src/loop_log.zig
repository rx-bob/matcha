const std = @import("std");

pub const Pair = struct {
    allocator: std.mem.Allocator,
    readable: std.Io.File,
    events: std.Io.File,
    invocation_id: []const u8,
    sequence: u64 = 0,
    mutex: std.atomic.Value(bool) = .init(false),

    pub fn deinit(self: *Pair, io: std.Io) void {
        self.readable.close(io);
        self.events.close(io);
        self.allocator.free(self.invocation_id);
    }

    pub fn record(self: *Pair, io: std.Io, loop_id: []const u8, kind: []const u8, payload: []const u8) !void {
        self.lock();
        defer self.unlock();
        self.sequence += 1;
        const stamp = std.Io.Clock.real.now(io).toMilliseconds();
        var event_buffer: [1024]u8 = undefined;
        var event_writer = self.events.writer(io, &event_buffer);
        try event_writer.interface.print("{{\"schema_version\":1,\"timestamp_ms\":{d},\"sequence\":{d},\"loop_id\":\"{f}\",\"invocation_id\":\"{s}\",\"kind\":\"{s}\",\"payload\":\"{f}\"}}\n", .{ stamp, self.sequence, std.json.fmt(loop_id, .{}), self.invocation_id, kind, std.json.fmt(payload, .{}) });
        try event_writer.interface.flush();
        var readable_buffer: [512]u8 = undefined;
        var readable_writer = self.readable.writer(io, &readable_buffer);
        try readable_writer.interface.print("[{d}] {s}: {s}\n", .{ self.sequence, kind, payload });
        try readable_writer.interface.flush();
    }

    pub fn raw(self: *Pair, io: std.Io, loop_id: []const u8, stream_name: []const u8, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const chunk = bytes[offset..@min(offset + 3072, bytes.len)];
            var encoded: [4096]u8 = undefined;
            const text = std.base64.standard.Encoder.encode(&encoded, chunk);
            self.lock();
            defer self.unlock();
            self.sequence += 1;
            const stamp = std.Io.Clock.real.now(io).toMilliseconds();
            var out_buffer: [5120]u8 = undefined;
            var writer = self.events.writer(io, &out_buffer);
            try writer.interface.print("{{\"schema_version\":1,\"timestamp_ms\":{d},\"sequence\":{d},\"loop_id\":\"{f}\",\"invocation_id\":\"{s}\",\"kind\":\"raw\",\"stream\":\"{s}\",\"encoding\":\"base64\",\"payload\":\"{s}\"}}\n", .{ stamp, self.sequence, std.json.fmt(loop_id, .{}), self.invocation_id, stream_name, text });
            try writer.interface.flush();
            offset += chunk.len;
        }
    }

    fn lock(self: *Pair) void {
        while (self.mutex.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Pair) void {
        self.mutex.store(false, .release);
    }
};

pub fn open(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, loop_id: []const u8) !Pair {
    try std.Io.Dir.cwd().createDirPath(io, directory);
    const timestamp = std.Io.Clock.real.now(io).toMilliseconds();
    var suffix: u32 = 0;
    while (suffix < 10000) : (suffix += 1) {
        const invocation = try std.fmt.allocPrint(allocator, "{d}-{s}-{d}", .{ timestamp, loop_id, suffix });
        errdefer allocator.free(invocation);
        const base = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, invocation });
        defer allocator.free(base);
        const log_path = try std.fmt.allocPrint(allocator, "{s}.log", .{base});
        defer allocator.free(log_path);
        const jsonl_path = try std.fmt.allocPrint(allocator, "{s}.jsonl", .{base});
        defer allocator.free(jsonl_path);
        const readable = std.Io.Dir.cwd().createFile(io, log_path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        const events = std.Io.Dir.cwd().createFile(io, jsonl_path, .{ .exclusive = true }) catch |err| {
            readable.close(io);
            std.Io.Dir.cwd().deleteFile(io, log_path) catch {};
            return err;
        };
        return .{ .allocator = allocator, .readable = readable, .events = events, .invocation_id = invocation };
    }
    return error.InvocationCollisionExhausted;
}

test "logger creates fresh paired files and sequenced JSONL lifecycle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/logs", .{tmp.sub_path});
    defer std.testing.allocator.free(dir);
    var pair = try open(std.testing.allocator, std.testing.io, dir, "loop-1");
    defer pair.deinit(std.testing.io);
    try pair.record(std.testing.io, "loop-1", "start", "initial");
    try std.testing.expectEqual(@as(u64, 1), pair.sequence);
}
