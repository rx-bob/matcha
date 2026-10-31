const std = @import("std");

pub const Pair = struct {
    allocator: std.mem.Allocator,
    readable: std.Io.File,
    events: std.Io.File,
    invocation_id: []const u8,
    sequence: u64 = 0,
    mutex: std.atomic.Value(bool) = .init(false),
    failure: ?Failure = null,
    fault: ?Fault = null,

    pub const Failure = struct { path: []const u8, operation: []const u8, cause: anyerror };
    pub const FaultPhase = enum { first_open, second_open, stdout_write, stderr_write, record_write, turn_sync, final_sync };
    pub const Fault = struct {
        context: *anyopaque,
        check: *const fn (*anyopaque, FaultPhase) anyerror!void,
    };

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

    pub fn sync(self: *Pair, io: std.Io, phase: FaultPhase) !void {
        self.lock();
        defer self.unlock();
        self.check(phase) catch |err| return self.fail(".jsonl", "sync", err);
        self.events.sync(io) catch |err| return self.fail(".jsonl", "sync", err);
        self.readable.sync(io) catch |err| return self.fail(".log", "sync", err);
    }

    fn check(self: *Pair, phase: FaultPhase) !void {
        if (self.fault) |fault| try fault.check(fault.context, phase);
    }

    fn fail(self: *Pair, path: []const u8, operation: []const u8, err: anyerror) error{AuditLogFailure} {
        if (self.failure == null) self.failure = .{ .path = path, .operation = operation, .cause = err };
        return error.AuditLogFailure;
    }

    pub fn record(self: *Pair, io: std.Io, loop_id: []const u8, kind: []const u8, payload: []const u8) !void {
        return self.recordContext(io, loop_id, .{}, kind, payload);
    }

    pub fn recordContext(self: *Pair, io: std.Io, loop_id: []const u8, context: Context, kind: []const u8, payload: []const u8) !void {
        self.lock();
        defer self.unlock();
        self.sequence += 1;
        const stamp = std.Io.Clock.real.now(io).toMilliseconds();
        const event_line = std.fmt.allocPrint(self.allocator, "{{\"schema_version\":1,\"timestamp_ms\":{d},\"sequence\":{d},\"loop_id\":{f},\"invocation_id\":{f},\"turn\":{f},\"role\":{f},\"backend\":{f},\"attempt\":{f},\"kind\":{f},\"payload\":{f}}}\n", .{ stamp, self.sequence, std.json.fmt(loop_id, .{}), std.json.fmt(self.invocation_id, .{}), std.json.fmt(context.turn, .{}), std.json.fmt(context.role, .{}), std.json.fmt(context.backend, .{}), std.json.fmt(context.attempt, .{}), std.json.fmt(kind, .{}), std.json.fmt(payload, .{}) }) catch |err| return self.fail(".jsonl", "format", err);
        defer self.allocator.free(event_line);
        self.check(.record_write) catch |err| return self.fail(".jsonl", "write", err);
        self.events.writeStreamingAll(io, event_line) catch |err| return self.fail(".jsonl", "write", err);
        const readable_line = std.fmt.allocPrint(self.allocator, "[{d}] {s}: {s}\n", .{ self.sequence, kind, payload }) catch |err| return self.fail(".log", "format", err);
        defer self.allocator.free(readable_line);
        self.readable.writeStreamingAll(io, readable_line) catch |err| return self.fail(".log", "write", err);
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
            const line = std.fmt.allocPrint(self.allocator, "{{\"schema_version\":1,\"timestamp_ms\":{d},\"sequence\":{d},\"loop_id\":{f},\"invocation_id\":{f},\"turn\":{f},\"role\":{f},\"backend\":{f},\"attempt\":{f},\"kind\":\"raw\",\"stream\":{f},\"encoding\":\"base64\",\"payload\":\"{s}\"}}\n", .{ stamp, self.sequence, std.json.fmt(loop_id, .{}), std.json.fmt(self.invocation_id, .{}), std.json.fmt(context.turn, .{}), std.json.fmt(context.role, .{}), std.json.fmt(context.backend, .{}), std.json.fmt(context.attempt, .{}), std.json.fmt(stream_name, .{}), text }) catch |err| return self.fail(".jsonl", "format", err);
            defer self.allocator.free(line);
            const phase: FaultPhase = if (std.mem.eql(u8, stream_name, "stderr")) .stderr_write else .stdout_write;
            self.check(phase) catch |err| return self.fail(".jsonl", "write", err);
            self.events.writeStreamingAll(io, line) catch |err| return self.fail(".jsonl", "write", err);
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
    return openWithFault(allocator, io, directory, loop_id, null);
}

pub fn openWithFault(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, loop_id: []const u8, fault: ?Pair.Fault) !Pair {
    return openWithReport(allocator, io, directory, loop_id, fault, null);
}

pub const OpenFailure = struct {
    path: []const u8,
    operation: []const u8,
    cause: anyerror,

    pub fn deinit(self: OpenFailure, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub fn openWithReport(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, loop_id: []const u8, fault: ?Pair.Fault, report: ?*?OpenFailure) !Pair {
    std.Io.Dir.cwd().createDirPath(io, directory) catch |err| {
        setOpenFailure(allocator, report, directory, "create directory", err);
        return err;
    };
    const timestamp = std.Io.Clock.real.now(io).toMilliseconds();
    var suffix: u32 = 0;
    while (suffix < 10000) : (suffix += 1) {
        const invocation = try std.fmt.allocPrint(allocator, "{d}-{s}-{d}", .{ timestamp, loop_id, suffix });
        var keep_invocation = false;
        defer if (!keep_invocation) allocator.free(invocation);
        const base = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, invocation });
        defer allocator.free(base);
        const log_path = try std.fmt.allocPrint(allocator, "{s}.log", .{base});
        defer allocator.free(log_path);
        const jsonl_path = try std.fmt.allocPrint(allocator, "{s}.jsonl", .{base});
        defer allocator.free(jsonl_path);
        if (fault) |hook| hook.check(hook.context, .first_open) catch |err| {
            setOpenFailure(allocator, report, log_path, "open", err);
            return err;
        };
        const readable = std.Io.Dir.cwd().createFile(io, log_path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => {
                setOpenFailure(allocator, report, log_path, "open", err);
                return err;
            },
        };
        const events = blk: {
            if (fault) |hook| hook.check(hook.context, .second_open) catch |err| {
                readable.close(io);
                setOpenFailure(allocator, report, jsonl_path, "open", err);
                return err;
            };
            break :blk std.Io.Dir.cwd().createFile(io, jsonl_path, .{ .exclusive = true }) catch |err| {
                readable.close(io);
                if (err == error.PathAlreadyExists) {
                    std.Io.Dir.cwd().deleteFile(io, log_path) catch {};
                    continue;
                }
                setOpenFailure(allocator, report, jsonl_path, "open", err);
                return err;
            };
        };
        keep_invocation = true;
        return .{ .allocator = allocator, .readable = readable, .events = events, .invocation_id = invocation, .fault = fault };
    }
    setOpenFailure(allocator, report, directory, "open log pair", error.InvocationCollisionExhausted);
    return error.InvocationCollisionExhausted;
}

fn setOpenFailure(allocator: std.mem.Allocator, report: ?*?OpenFailure, path: []const u8, operation: []const u8, cause: anyerror) void {
    if (report) |slot| {
        slot.* = .{ .path = allocator.dupe(u8, path) catch return, .operation = operation, .cause = cause };
    }
}

test "logger creates fresh paired files and sequenced JSONL lifecycle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/logs", .{tmp.sub_path});
    defer std.testing.allocator.free(dir);
    var pair = try open(std.testing.allocator, std.testing.io, dir, "loop-1");
    defer pair.deinit(std.testing.io);
    try pair.record(std.testing.io, "loop-1", "start", "initial");
    try pair.sync(std.testing.io, .final_sync);
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

test "audit fault hook covers both opens, both streams, turn and final sync" {
    const TestFault = struct {
        phase: Pair.FaultPhase,
        fn check(context: *anyopaque, phase: Pair.FaultPhase) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.phase == phase) return error.InjectedAuditFailure;
        }
        fn hook(self: *@This()) Pair.Fault {
            return .{ .context = self, .check = check };
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/logs", .{tmp.sub_path});
    defer std.testing.allocator.free(dir);
    for ([_]Pair.FaultPhase{ .first_open, .second_open }) |phase| {
        var fault = TestFault{ .phase = phase };
        try std.testing.expectError(error.InjectedAuditFailure, openWithFault(std.testing.allocator, std.testing.io, dir, "fault-open", fault.hook()));
    }
    for ([_]Pair.FaultPhase{ .stdout_write, .stderr_write, .record_write, .turn_sync, .final_sync }) |phase| {
        var fault = TestFault{ .phase = phase };
        var pair = try openWithFault(std.testing.allocator, std.testing.io, dir, "fault-write", fault.hook());
        defer pair.deinit(std.testing.io);
        const result = switch (phase) {
            .stdout_write => pair.raw(std.testing.io, "fault-write", "stdout", "out"),
            .stderr_write => pair.raw(std.testing.io, "fault-write", "stderr", "err"),
            .record_write => pair.record(std.testing.io, "fault-write", "status", "active"),
            .turn_sync, .final_sync => pair.sync(std.testing.io, phase),
            else => unreachable,
        };
        try std.testing.expectError(error.AuditLogFailure, result);
        try std.testing.expectEqual(error.InjectedAuditFailure, pair.failure.?.cause);
    }
}
