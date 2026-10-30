const std = @import("std");
const path = @import("path.zig");
const options = @import("loop_options.zig");

pub const LoopStatus = enum { active, verifying, complete, paused, blocked, budget_limited };

pub const LoopState = struct {
    schema_version: u32 = 1,
    id: []const u8,
    status: LoopStatus = .active,
    backend: options.BackendKind,
    verifier_backend: ?options.BackendKind = null,
    verify_enabled: bool = true,
    model: ?[]const u8 = null,
    yolo: bool = false,
    cwd: []const u8,
    objective: []const u8,
    worker_session_id: ?[]const u8 = null,
    turns_completed: u32 = 0,
    tokens_used: u64 = 0,
    max_turns: ?u32 = null,
    token_budget: ?u64 = null,
    timeout_seconds: ?u64 = null,
    started_at_ms: u64,
    updated_at_ms: u64,
    blocked_strikes: u8 = 0,
    last_blocker_summary: ?[]const u8 = null,
    last_verifier_feedback: ?[]const u8 = null,
    completion_summary: ?[]const u8 = null,
    extra_args: []const []const u8 = &.{},
};

pub const TurnRole = enum { worker, verifier };
pub const TurnOutcome = enum { continued, complete, blocked, verifier_pass, verifier_fail, @"error" };

pub const TurnRecord = struct {
    turn: u32,
    role: TurnRole,
    backend: options.BackendKind,
    session_id: ?[]const u8 = null,
    tokens_delta: u64 = 0,
    duration_ms: u64 = 0,
    outcome: TurnOutcome,
    summary: []const u8 = "",
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, root_override: ?[]const u8) !Store {
        const root = if (root_override) |value|
            try allocator.dupe(u8, value)
        else
            try path.expandHomePath(allocator, "~/.matcha/loops");
        return .{ .allocator = allocator, .io = io, .root = root };
    }

    pub fn deinit(self: *Store) void {
        self.allocator.free(self.root);
    }

    fn ensureRoot(self: *const Store) !std.Io.Dir {
        try std.Io.Dir.cwd().createDirPath(self.io, self.root);
        if (std.Io.Dir.path.isAbsolute(self.root))
            return std.Io.Dir.openDirAbsolute(self.io, self.root, .{ .iterate = true });
        return std.Io.Dir.cwd().openDir(self.io, self.root, .{ .iterate = true });
    }

    pub fn createLoop(self: *const Store, initial: LoopState) !void {
        if (!validLoopId(initial.id)) return error.InvalidLoopId;
        var root_dir = try self.ensureRoot();
        defer root_dir.close(self.io);
        try root_dir.createDir(self.io, initial.id, .default_dir);
        try self.saveState(initial);
    }

    pub fn generateLoopId(self: *const Store) ![]const u8 {
        const timestamp = std.Io.Clock.real.now(self.io).toMilliseconds();
        var random_bytes: [2]u8 = undefined;
        self.io.random(&random_bytes);
        const random_value = std.mem.readInt(u16, &random_bytes, .big);
        return std.fmt.allocPrint(self.allocator, "{x}-{x:0>4}", .{ @as(u64, @intCast(@max(0, timestamp))), random_value });
    }

    pub fn saveState(self: *const Store, state: LoopState) !void {
        if (!validLoopId(state.id)) return error.InvalidLoopId;
        var root_dir = try self.ensureRoot();
        defer root_dir.close(self.io);
        var loop_dir = try root_dir.openDir(self.io, state.id, .{});
        defer loop_dir.close(self.io);

        const encoded = try std.json.Stringify.valueAlloc(self.allocator, state, .{});
        defer self.allocator.free(encoded);
        const tmp = try loop_dir.createFile(self.io, "state.json.tmp", .{ .truncate = true });
        var tmp_open = true;
        defer if (tmp_open) tmp.close(self.io);
        try tmp.writeStreamingAll(self.io, encoded);
        try tmp.sync(self.io);
        tmp.close(self.io);
        tmp_open = false;
        try std.Io.Dir.rename(loop_dir, "state.json.tmp", loop_dir, "state.json", self.io);
    }

    pub fn loadState(self: *const Store, id: []const u8) !std.json.Parsed(LoopState) {
        if (!validLoopId(id)) return error.InvalidLoopId;
        var root_dir = try self.ensureRoot();
        defer root_dir.close(self.io);
        const file_path = try std.fmt.allocPrint(self.allocator, "{s}/state.json", .{id});
        defer self.allocator.free(file_path);
        const bytes = try root_dir.readFileAlloc(self.io, file_path, self.allocator, .limited(16 * 1024 * 1024));
        defer self.allocator.free(bytes);
        return std.json.parseFromSlice(LoopState, self.allocator, bytes, .{ .allocate = .alloc_always });
    }

    pub fn appendTurnLog(self: *const Store, id: []const u8, record: TurnRecord) !void {
        if (!validLoopId(id)) return error.InvalidLoopId;
        var root_dir = try self.ensureRoot();
        defer root_dir.close(self.io);
        var loop_dir = try root_dir.openDir(self.io, id, .{});
        defer loop_dir.close(self.io);

        const json = try std.json.Stringify.valueAlloc(self.allocator, record, .{});
        defer self.allocator.free(json);
        const line = try std.mem.concat(self.allocator, u8, &.{ json, "\n" });
        defer self.allocator.free(line);

        const file = try loop_dir.createFile(self.io, "turns.jsonl", .{ .truncate = false });
        defer file.close(self.io);
        const stat = try loop_dir.statFile(self.io, "turns.jsonl", .{});
        try file.writePositionalAll(self.io, line, stat.size);
    }

    pub fn resolveLatestLoopId(self: *const Store) !?[]const u8 {
        var root_dir = try self.ensureRoot();
        defer root_dir.close(self.io);
        var iterator = root_dir.iterate();
        var latest: ?[]const u8 = null;
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .directory or !validLoopId(entry.name)) continue;
            if (latest == null or std.mem.order(u8, entry.name, latest.?) == .gt) {
                if (latest) |old| self.allocator.free(old);
                latest = try self.allocator.dupe(u8, entry.name);
            }
        }
        return latest;
    }

    pub fn listLoopIds(self: *const Store) ![][]const u8 {
        var root_dir = try self.ensureRoot();
        defer root_dir.close(self.io);
        var ids: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (ids.items) |id| self.allocator.free(id);
            ids.deinit(self.allocator);
        }
        var iterator = root_dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .directory or !validLoopId(entry.name)) continue;
            try ids.append(self.allocator, try self.allocator.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, ids.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        return ids.toOwnedSlice(self.allocator);
    }

    pub fn readRecentTurnLog(self: *const Store, id: []const u8, max_lines: usize) ![]const u8 {
        if (!validLoopId(id)) return error.InvalidLoopId;
        if (max_lines == 0) return self.allocator.dupe(u8, "");
        var root_dir = try self.ensureRoot();
        defer root_dir.close(self.io);
        var loop_dir = try root_dir.openDir(self.io, id, .{});
        defer loop_dir.close(self.io);
        const file = try loop_dir.openFile(self.io, "turns.jsonl", .{});
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        const read_limit: u64 = 128 * 1024;
        const start = if (stat.size > read_limit) stat.size - read_limit else 0;
        const length: usize = @intCast(stat.size - start);
        const bytes = try self.allocator.alloc(u8, length);
        defer self.allocator.free(bytes);
        const read = try file.readPositionalAll(self.io, bytes, start);
        const content = bytes[0..read];
        var line_start: usize = 0;
        if (start != 0) {
            if (std.mem.indexOfScalar(u8, content, '\n')) |newline| line_start = newline + 1 else return self.allocator.dupe(u8, "");
        }
        var boundaries: usize = 0;
        var index = content.len;
        var selected = line_start;
        while (index > line_start) {
            index -= 1;
            if (content[index] == '\n' and index + 1 < content.len) {
                boundaries += 1;
                if (boundaries == max_lines) {
                    selected = index + 1;
                    break;
                }
            }
        }
        return self.allocator.dupe(u8, content[selected..]);
    }
};

fn validLoopId(id: []const u8) bool {
    if (id.len < 3 or id.len > 32) return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    return true;
}

test "store creates and round-trips every state field with atomic overwrite" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    var store = try Store.init(std.testing.allocator, std.testing.io, root);
    defer store.deinit();
    const state: LoopState = .{
        .id = "6722c1a0-9f3b",
        .backend = .codex,
        .verifier_backend = .agy,
        .model = "model \"quoted\"",
        .yolo = true,
        .cwd = "/work/tree",
        .objective = "line one\nline \"two\" \\ end",
        .worker_session_id = "sess-1",
        .turns_completed = 3,
        .tokens_used = 456,
        .max_turns = 12,
        .token_budget = 900,
        .timeout_seconds = 300,
        .started_at_ms = 100,
        .updated_at_ms = 200,
        .blocked_strikes = 2,
        .last_blocker_summary = "block\nsummary",
        .last_verifier_feedback = "missing \"edge\"",
        .completion_summary = "done",
        .extra_args = &.{ "--flag", "value with spaces" },
    };
    try store.createLoop(state);
    var loaded = try store.loadState(state.id);
    defer loaded.deinit();
    try std.testing.expectEqual(state.schema_version, loaded.value.schema_version);
    try std.testing.expectEqual(state.status, loaded.value.status);
    try std.testing.expectEqual(state.backend, loaded.value.backend);
    try std.testing.expectEqual(state.verifier_backend, loaded.value.verifier_backend);
    try std.testing.expectEqual(state.verify_enabled, loaded.value.verify_enabled);
    try std.testing.expectEqualStrings(state.model.?, loaded.value.model.?);
    try std.testing.expectEqual(state.yolo, loaded.value.yolo);
    try std.testing.expectEqualStrings(state.cwd, loaded.value.cwd);
    try std.testing.expectEqualStrings(state.objective, loaded.value.objective);
    try std.testing.expectEqualStrings(state.worker_session_id.?, loaded.value.worker_session_id.?);
    try std.testing.expectEqual(state.turns_completed, loaded.value.turns_completed);
    try std.testing.expectEqual(state.tokens_used, loaded.value.tokens_used);
    try std.testing.expectEqual(state.max_turns, loaded.value.max_turns);
    try std.testing.expectEqual(state.token_budget, loaded.value.token_budget);
    try std.testing.expectEqual(state.timeout_seconds, loaded.value.timeout_seconds);
    try std.testing.expectEqual(state.started_at_ms, loaded.value.started_at_ms);
    try std.testing.expectEqual(state.updated_at_ms, loaded.value.updated_at_ms);
    try std.testing.expectEqual(state.blocked_strikes, loaded.value.blocked_strikes);
    try std.testing.expectEqualStrings(state.last_blocker_summary.?, loaded.value.last_blocker_summary.?);
    try std.testing.expectEqualStrings(state.last_verifier_feedback.?, loaded.value.last_verifier_feedback.?);
    try std.testing.expectEqualStrings(state.completion_summary.?, loaded.value.completion_summary.?);
    try std.testing.expectEqual(@as(usize, state.extra_args.len), loaded.value.extra_args.len);
    for (state.extra_args, loaded.value.extra_args) |expected, actual| try std.testing.expectEqualStrings(expected, actual);

    var updated = state;
    updated.status = .verifying;
    updated.updated_at_ms = 300;
    try store.saveState(updated);
    var reloaded = try store.loadState(state.id);
    defer reloaded.deinit();
    try std.testing.expectEqual(LoopStatus.verifying, reloaded.value.status);
    try std.testing.expectEqual(@as(u64, 300), reloaded.value.updated_at_ms);

    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "6722c1a0-9f3b/state.json.tmp", .{}));
}

test "turn log appends worker and verifier records and latest id sorts lexically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    var store = try Store.init(std.testing.allocator, std.testing.io, root);
    defer store.deinit();
    const first_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/6722c1a0-0001", .{root});
    defer std.testing.allocator.free(first_dir);
    const second_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/6722c1a0-0002", .{root});
    defer std.testing.allocator.free(second_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, first_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, second_dir);
    try store.appendTurnLog("6722c1a0-0001", .{ .turn = 1, .role = .worker, .backend = .codex, .session_id = "s1", .tokens_delta = 40, .duration_ms = 80, .outcome = .continued, .summary = "worker" });
    try store.appendTurnLog("6722c1a0-0001", .{ .turn = 1, .role = .verifier, .backend = .agy, .session_id = "v1", .outcome = .verifier_pass, .summary = "passed" });
    const contents = try tmp.dir.readFileAlloc(std.testing.io, "6722c1a0-0001/turns.jsonl", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, contents, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"role\":\"verifier\"") != null);
    const tail = try store.readRecentTurnLog("6722c1a0-0001", 1);
    defer std.testing.allocator.free(tail);
    try std.testing.expect(std.mem.indexOf(u8, tail, "passed") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "worker") == null);
    const ids = try store.listLoopIds();
    defer {
        for (ids) |id| std.testing.allocator.free(id);
        std.testing.allocator.free(ids);
    }
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqualStrings("6722c1a0-0001", ids[0]);
    const latest = (try store.resolveLatestLoopId()).?;
    defer std.testing.allocator.free(latest);
    try std.testing.expectEqualStrings("6722c1a0-0002", latest);
}

test "loop IDs use sortable timestamp and random suffix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    var store = try Store.init(std.testing.allocator, std.testing.io, root);
    defer store.deinit();
    const first = try store.generateLoopId();
    defer std.testing.allocator.free(first);
    const second = try store.generateLoopId();
    defer std.testing.allocator.free(second);
    try std.testing.expect(std.mem.indexOfScalar(u8, first, '-') != null);
    try std.testing.expect(validLoopId(first));
    try std.testing.expect(validLoopId(second));
}
