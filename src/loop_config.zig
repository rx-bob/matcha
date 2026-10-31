const std = @import("std");
const options = @import("loop_options.zig");
const path = @import("path.zig");

pub const Config = struct {
    schema_version: u32 = 1,
    backend: options.BackendKind = .codex,
    model: ?[]const u8 = null,
    max_turns: ?u32 = null,
};

pub fn configPathAlloc(allocator: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |value| {
        const root = std.mem.span(value);
        if (root.len > 0) return std.fmt.allocPrint(allocator, "{s}/matcha/loop.json", .{root});
    }
    return path.expandHomePath(allocator, "~/.config/matcha/loop.json");
}

pub fn load(allocator: std.mem.Allocator, io: std.Io) !std.json.Parsed(Config) {
    const config_path = try configPathAlloc(allocator);
    defer allocator.free(config_path);
    return loadAtPath(allocator, io, config_path);
}

fn loadAtPath(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) !std.json.Parsed(Config) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(64 * 1024));
    defer allocator.free(bytes);
    return std.json.parseFromSlice(Config, allocator, bytes, .{ .allocate = .alloc_always });
}

pub fn save(allocator: std.mem.Allocator, io: std.Io, config: Config) ![]const u8 {
    const config_path = try configPathAlloc(allocator);
    return saveAtPath(allocator, io, config_path, config);
}

fn saveAtPath(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8, config: Config) ![]const u8 {
    errdefer allocator.free(config_path);
    const parent = path.parentDirectory(config_path) orelse return error.InvalidConfigPath;
    try std.Io.Dir.cwd().createDirPath(io, parent);

    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{config_path});
    defer allocator.free(temp_path);
    const encoded = try std.json.Stringify.valueAlloc(allocator, config, .{});
    defer allocator.free(encoded);
    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, encoded);
        try file.sync(io);
    }
    try std.Io.Dir.rename(std.Io.Dir.cwd(), temp_path, std.Io.Dir.cwd(), config_path, io);
    return config_path;
}

test "config load releases allocations at every OOM point" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const config_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/loop.json", .{tmp.sub_path});
    defer allocator.free(config_path);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "loop.json",
        .data = "{\"schema_version\":1,\"backend\":\"codex\",\"model\":\"audit-model\",\"max_turns\":4}",
    });

    var saw_success = false;
    for (0..64) |fail_index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        if (loadAtPath(failing.allocator(), std.testing.io, config_path)) |parsed| {
            var owned = parsed;
            owned.deinit();
            saw_success = true;
        } else |_| {}
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (saw_success and !failing.has_induced_failure) break;
    }
    try std.testing.expect(saw_success);
}

test "config save releases allocations at every OOM point" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var saw_success = false;
    for (0..64) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const config_path = std.fmt.allocPrint(failing.allocator(), ".zig-cache/tmp/{s}/matcha/loop.json", .{tmp.sub_path}) catch {
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            continue;
        };
        if (saveAtPath(failing.allocator(), std.testing.io, config_path, .{ .model = "audit-model", .max_turns = 4 })) |saved_path| {
            failing.allocator().free(saved_path);
            saw_success = true;
        } else |_| {}
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (saw_success and !failing.has_induced_failure) break;
    }
    try std.testing.expect(saw_success);
}
