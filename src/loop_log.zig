const std = @import("std");

pub const Pair = struct {
    allocator: std.mem.Allocator,
    readable: std.Io.File,
    events: std.Io.File,
    invocation_id: []const u8,
    sequence: u64 = 0,
    mutex: std.atomic.Value(bool) = .init(false),

    pub const Context = struct {
        turn: ?u32 = null,
        role: ?[]const u8 = null,
        backend: ?[]const u8 = null,
        attempt: ?u32 = null,
    };

    pub fn deinit(self: *Pair, io: std.Io) void {
        self.readable.close(io);
        self.events.close(io);
        self.allocator.free(self.invocation_id);
    }

    pub fn record(self: *Pair, io: std.Io, loop_id: []const u8, kind: []const u8, payload: []const u8) !void {
        return self.recordContext(io, loop_id, .{}, kind, payload);
    }

    pub fn recordContext(self: *Pair, io: std.Io, loop_id: []const u8, context: Context, kind: []const u8, payload: []const u8) !void {
        self.lock();
        defer self.unlock();
        self.sequence += 1;
        const stamp = std.Io.Clock.real.now(io).toMilliseconds();
        const event_line = try std.fmt.allocPrint(self.allocator, "{{\"schema_version\":1,\"timestamp_ms\":{d},\"sequence\":{d},\"loop_id\":{f},\"invocation_id\":{f},\"turn\":{f},\"role\":{f},\"backend\":{f},\"attempt\":{f},\"kind\":{f},\"payload\":{f}}}\n", .{ stamp, self.sequence, std.json.fmt(loop_id, .{}), std.json.fmt(self.invocation_id, .{}), std.json.fmt(context.turn, .{}), std.json.fmt(context.role, .{}), std.json.fmt(context.backend, .{}), std.json.fmt(context.attempt, .{}), std.json.fmt(kind, .{}), std.json.fmt(payload, .{}) });
        defer self.allocator.free(event_line);
        try self.events.writeStreamingAll(io, event_line);
        const readable_line = try std.fmt.allocPrint(self.allocator, "[{d}] {s}: {s}\n", .{ self.sequence, kind, payload });
        defer self.allocator.free(readable_line);
        try self.readable.writeStreamingAll(io, readable_line);
    }

    pub fn raw(self: *Pair, io: std.Io, loop_id: []const u8, stream_name: []const u8, bytes: []const u8) !void {
        return self.rawContext(io, loop_id, .{}, stream_name, bytes);
    }

    pub fn rawContext(self: *Pair, io: std.Io, loop_id: []const u8, context: Context, stream_name: []const u8, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const chunk = bytes[offset..@min(offset + 3072, bytes.len)];
            var encoded: [4096]u8 = undefined;
            const text = std.base64.standard.Encoder.encode(&encoded, chunk);
            self.lock();
            defer self.unlock();
            self.sequence += 1;
            const stamp = std.Io.Clock.real.now(io).toMilliseconds();
            const line = try std.fmt.allocPrint(self.allocator, "{{\"schema_version\":1,\"timestamp_ms\":{d},\"sequence\":{d},\"loop_id\":{f},\"invocation_id\":{f},\"turn\":{f},\"role\":{f},\"backend\":{f},\"attempt\":{f},\"kind\":\"raw\",\"stream\":{f},\"encoding\":\"base64\",\"payload\":\"{s}\"}}\n", .{ stamp, self.sequence, std.json.fmt(loop_id, .{}), std.json.fmt(self.invocation_id, .{}), std.json.fmt(context.turn, .{}), std.json.fmt(context.role, .{}), std.json.fmt(context.backend, .{}), std.json.fmt(context.attempt, .{}), std.json.fmt(stream_name, .{}), text });
            defer self.allocator.free(line);
            try self.events.writeStreamingAll(io, line);
            offset += chunk.len;
        }
    }

    pub fn stderr(self: *Pair, io: std.Io, loop_id: []const u8, context: Context, bytes: []const u8) !void {
        var offset: usize = 0;
        const hex = "0123456789abcdef";
        while (offset < bytes.len) {
            var rendered: [4096]u8 = undefined;
            var len: usize = 0;
            while (offset < bytes.len and len <= rendered.len - 4) : (offset += 1) {
                const byte = bytes[offset];
                if (byte == '\n' or byte == '\t' or (byte >= 32 and byte < 127)) {
                    rendered[len] = byte;
                    len += 1;
                } else {
                    rendered[len] = '\\';
                    rendered[len + 1] = 'x';
                    rendered[len + 2] = hex[byte >> 4];
                    rendered[len + 3] = hex[byte & 15];
                    len += 4;
                }
            }
            try self.recordContext(io, loop_id, context, "stderr", rendered[0..len]);
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
            if (err == error.PathAlreadyExists) continue;
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
    const first_id = try std.testing.allocator.dupe(u8, pair.invocation_id);
    defer std.testing.allocator.free(first_id);
    const jsonl_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}.jsonl", .{ dir, first_id });
    defer std.testing.allocator.free(jsonl_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, jsonl_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, std.mem.trimEnd(u8, bytes, "\n"), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("loop-1", parsed.value.object.get("loop_id").?.string);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("sequence").?.integer);
    var second = try open(std.testing.allocator, std.testing.io, dir, "loop-1");
    defer second.deinit(std.testing.io);
    try std.testing.expect(!std.mem.eql(u8, first_id, second.invocation_id));
}
