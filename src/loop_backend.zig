const std = @import("std");
const options = @import("loop_options.zig");

pub const BackendKind = options.BackendKind;

/// Owns all strings in `items`; callers own the returned value and must deinit it.
pub const Argv = struct {
    allocator: std.mem.Allocator,
    items: [][]const u8,

    pub fn deinit(self: *Argv) void {
        for (self.items) |item| self.allocator.free(item);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

/// Owns a cloned environment map. Deinitializing it leaves the parent map intact.
pub const ChildEnvironment = struct {
    map: std.process.Environ.Map,

    pub fn deinit(self: *ChildEnvironment) void {
        self.map.deinit();
        self.* = undefined;
    }
};

pub const BackendOptions = struct {
    backend: BackendKind,
    model: ?[]const u8 = null,
    yolo: bool = false,
    extra_args: []const []const u8 = &.{},
};

/// Build argv for one backend invocation. A null session ID starts a fresh session.
/// `prompt_file` is used by Droid; Codex and Agy consume the prompt through stdin.
pub fn buildArgv(
    allocator: std.mem.Allocator,
    config: BackendOptions,
    loop_dir: []const u8,
    session_id: ?[]const u8,
    prompt_file: []const u8,
) !Argv {
    var builder = ArgvBuilder.init(allocator);
    errdefer builder.deinit();

    switch (config.backend) {
        .codex => try buildCodex(&builder, config, loop_dir, session_id),
        .droid => try buildDroid(&builder, config, session_id, prompt_file),
        .agy => try buildAgy(&builder, config, loop_dir, session_id),
    }
    return builder.finish();
}

fn buildCodex(builder: *ArgvBuilder, config: BackendOptions, loop_dir: []const u8, session_id: ?[]const u8) !void {
    try builder.add("codex");
    try builder.add("exec");
    if (config.yolo) {
        try builder.add("--dangerously-bypass-approvals-and-sandbox");
    } else {
        try builder.add("-s");
        try builder.add("workspace-write");
        try builder.add("--add-dir");
        try builder.add(loop_dir);
    }
    if (config.model) |model| {
        try builder.add("--model");
        try builder.add(model);
    }
    try builder.addMany(config.extra_args);
    if (session_id) |id| {
        try builder.add("resume");
        try builder.add("--json");
        try builder.add(id);
        try builder.add("-");
    } else {
        try builder.add("--json");
        try builder.add("-");
    }
}

fn buildDroid(builder: *ArgvBuilder, config: BackendOptions, session_id: ?[]const u8, prompt_file: []const u8) !void {
    try builder.add("droid");
    try builder.add("exec");
    try builder.add(if (config.yolo) "--skip-permissions-unsafe" else "--auto");
    if (!config.yolo) try builder.add("high");
    if (session_id) |id| {
        try builder.add("-s");
        try builder.add(id);
    }
    if (config.model) |model| {
        try builder.add("-m");
        try builder.add(model);
    }
    try builder.addMany(config.extra_args);
    try builder.add("-o");
    try builder.add("stream-json");
    try builder.add("-f");
    try builder.add(prompt_file);
}

fn buildAgy(builder: *ArgvBuilder, config: BackendOptions, loop_dir: []const u8, session_id: ?[]const u8) !void {
    try builder.add("agy");
    try builder.add("-p");
    if (config.yolo) {
        try builder.add("--dangerously-skip-permissions");
    } else {
        try builder.add("--mode");
        try builder.add("auto");
    }
    try builder.add("--add-dir");
    try builder.add(loop_dir);
    if (session_id) |id| {
        try builder.add("--conversation");
        try builder.add(id);
    }
    if (config.model) |model| {
        try builder.add("--model");
        try builder.add(model);
    }
    try builder.addMany(config.extra_args);
    try builder.add("--output-format");
    try builder.add("stream-json");
}

/// Clone the parent environment and inject the loop ID and current binary directory in PATH.
pub fn buildChildEnvironment(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: *const std.process.Environ.Map,
    loop_id: []const u8,
) !ChildEnvironment {
    const executable_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(executable_dir);
    return buildChildEnvironmentWithBinaryDir(allocator, parent, loop_id, executable_dir);
}

fn buildChildEnvironmentWithBinaryDir(
    allocator: std.mem.Allocator,
    parent: *const std.process.Environ.Map,
    loop_id: []const u8,
    binary_dir: []const u8,
) !ChildEnvironment {
    var map = try parent.clone(allocator);
    errdefer map.deinit();
    try map.put("MATCHA_LOOP_ID", loop_id);

    const old_path = map.get("PATH") orelse "";
    const separator: u8 = if (@import("builtin").os.tag == .windows) ';' else ':';
    const path = if (old_path.len == 0)
        try allocator.dupe(u8, binary_dir)
    else
        try std.mem.concat(allocator, u8, &.{ binary_dir, &.{separator}, old_path });
    defer allocator.free(path);
    try map.put("PATH", path);
    return .{ .map = map };
}

/// Human-readable attach command for a native interactive backend session.
pub fn formatNativeResumeCommand(allocator: std.mem.Allocator, backend: BackendKind, session_id: []const u8) ![]u8 {
    return switch (backend) {
        .codex => std.fmt.allocPrint(allocator, "codex resume {s}", .{session_id}),
        .droid => std.fmt.allocPrint(allocator, "droid -r {s}", .{session_id}),
        .agy => std.fmt.allocPrint(allocator, "agy --conversation {s}", .{session_id}),
    };
}

const ArgvBuilder = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]const u8) = .empty,

    fn init(allocator: std.mem.Allocator) ArgvBuilder {
        return .{ .allocator = allocator };
    }

    fn add(self: *ArgvBuilder, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned);
        try self.items.append(self.allocator, owned);
    }

    fn addMany(self: *ArgvBuilder, values: []const []const u8) !void {
        for (values) |value| try self.add(value);
    }

    fn finish(self: *ArgvBuilder) !Argv {
        return .{ .allocator = self.allocator, .items = try self.items.toOwnedSlice(self.allocator) };
    }

    fn deinit(self: *ArgvBuilder) void {
        for (self.items.items) |item| self.allocator.free(item);
        self.items.deinit(self.allocator);
    }
};

test "Codex argv orders sandbox flags before resume and forwards options" {
    const allocator = std.testing.allocator;
    const extra = [_][]const u8{ "--experimental", "value" };
    var first = try buildArgv(allocator, .{ .backend = .codex, .model = "o3", .extra_args = &extra }, "/loops/id", null, "prompt.md");
    defer first.deinit();
    try expectArgv(&first, &.{ "codex", "exec", "-s", "workspace-write", "--add-dir", "/loops/id", "--model", "o3", "--experimental", "value", "--json", "-" });

    var resumed = try buildArgv(allocator, .{ .backend = .codex, .yolo = true, .extra_args = &extra }, "/loops/id", "sid", "prompt.md");
    defer resumed.deinit();
    try expectArgv(&resumed, &.{ "codex", "exec", "--dangerously-bypass-approvals-and-sandbox", "--experimental", "value", "resume", "--json", "sid", "-" });
}

test "Droid and Agy argv cover initial, resumed, and yolo modes" {
    const allocator = std.testing.allocator;
    const extra = [_][]const u8{"--extra"};
    var droid = try buildArgv(allocator, .{ .backend = .droid, .model = "sonnet", .extra_args = &extra }, "/loops/id", "sid", "/loops/id/current_prompt.md");
    defer droid.deinit();
    try expectArgv(&droid, &.{ "droid", "exec", "--auto", "high", "-s", "sid", "-m", "sonnet", "--extra", "-o", "stream-json", "-f", "/loops/id/current_prompt.md" });

    var droid_fresh = try buildArgv(allocator, .{ .backend = .droid }, "/loops/id", null, "/loops/id/current_prompt.md");
    defer droid_fresh.deinit();
    try expectArgv(&droid_fresh, &.{ "droid", "exec", "--auto", "high", "-o", "stream-json", "-f", "/loops/id/current_prompt.md" });

    var droid_yolo = try buildArgv(allocator, .{ .backend = .droid, .yolo = true }, "/loops/id", null, "/loops/id/current_prompt.md");
    defer droid_yolo.deinit();
    try expectArgv(&droid_yolo, &.{ "droid", "exec", "--skip-permissions-unsafe", "-o", "stream-json", "-f", "/loops/id/current_prompt.md" });

    var agy = try buildArgv(allocator, .{ .backend = .agy, .model = "gemini", .extra_args = &extra }, "/loops/id", "sid", "prompt.md");
    defer agy.deinit();
    try expectArgv(&agy, &.{ "agy", "-p", "--mode", "auto", "--add-dir", "/loops/id", "--conversation", "sid", "--model", "gemini", "--extra", "--output-format", "stream-json" });

    var agy_fresh = try buildArgv(allocator, .{ .backend = .agy }, "/loops/id", null, "prompt.md");
    defer agy_fresh.deinit();
    try expectArgv(&agy_fresh, &.{ "agy", "-p", "--mode", "auto", "--add-dir", "/loops/id", "--output-format", "stream-json" });

    var agy_yolo = try buildArgv(allocator, .{ .backend = .agy, .yolo = true }, "/loops/id", null, "prompt.md");
    defer agy_yolo.deinit();
    try expectArgv(&agy_yolo, &.{ "agy", "-p", "--dangerously-skip-permissions", "--add-dir", "/loops/id", "--output-format", "stream-json" });
}

test "environment builder clones parent and prepends binary directory" {
    const allocator = std.testing.allocator;
    var parent = std.process.Environ.Map.init(allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("KEEP_ME", "present");

    var child = try buildChildEnvironmentWithBinaryDir(allocator, &parent, "loop-123", "/opt/matcha/bin");
    defer child.deinit();
    const separator: u8 = if (@import("builtin").os.tag == .windows) ';' else ':';
    const expected_path = try std.mem.concat(allocator, u8, &.{ "/opt/matcha/bin", &.{separator}, "/usr/bin:/bin" });
    defer allocator.free(expected_path);
    try std.testing.expectEqualStrings("loop-123", child.map.get("MATCHA_LOOP_ID").?);
    try std.testing.expectEqualStrings(expected_path, child.map.get("PATH").?);
    try std.testing.expectEqualStrings("present", child.map.get("KEEP_ME").?);
    try std.testing.expect(parent.get("MATCHA_LOOP_ID") == null);
    try std.testing.expectEqualStrings("/usr/bin:/bin", parent.get("PATH").?);
}

test "native resume command uses backend attach syntax" {
    const allocator = std.testing.allocator;
    const expected = [_][]const u8{
        "codex resume s-1",
        "droid -r s-1",
        "agy --conversation s-1",
    };
    const backends = [_]BackendKind{ .codex, .droid, .agy };
    for (backends, 0..) |backend, i| {
        const command = try formatNativeResumeCommand(allocator, backend, "s-1");
        defer allocator.free(command);
        try std.testing.expectEqualStrings(expected[i], command);
    }
}

fn expectArgv(actual: *const Argv, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.items.len);
    for (expected, actual.items) |want, got| try std.testing.expectEqualStrings(want, got);
}
