const std = @import("std");
const options = @import("loop_options.zig");
const path = @import("path.zig");

pub const Config = struct {
    schema_version: u32 = 1,
    backend: options.BackendKind = .codex,
    model: ?[]const u8 = null,
    max_turns: ?u32 = null,
    prompt_file: ?[]const u8 = null,
    verifier: ?options.BackendKind = null,
    verify_enabled: bool = true,
    yolo: bool = false,
    token_budget: ?u64 = null,
    timeout_seconds: ?u64 = null,
    output_mode: options.OutputMode = .live,
    extra_backend_args: []const []const u8 = &.{},
};

/// Owned resolution; all merged strings and arrays live until deinit.
pub const Resolved = struct {
    arena: *std.heap.ArenaAllocator,
    run: options.RunOptions,
    pub fn deinit(self: *Resolved) void {
        const parent = self.arena.child_allocator;
        self.arena.deinit();
        parent.destroy(self.arena);
    }
};

pub fn resolve(allocator: std.mem.Allocator, io: std.Io, cli: options.RunOptions, user_path: ?[]const u8, project_path: []const u8, diagnostic: *std.Io.Writer) !Resolved {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    var result: Resolved = .{ .arena = arena, .run = cli };
    errdefer result.deinit();
    const a = arena.allocator();
    var settings: Config = .{};
    var verifier_present = false;
    if (user_path) |source| try applyLayer(a, io, &settings, source, false, false, diagnostic, &verifier_present);
    try applyLayer(a, io, &settings, project_path, true, cli.config_path != null, diagnostic, &verifier_present);
    result.run.backend = if (cli.backend_explicit) cli.backend else settings.backend;
    result.run.model = cli.model orelse settings.model;
    result.run.max_turns = if (cli.turn_limit_explicit) cli.max_turns else settings.max_turns;
    result.run.verifier_explicit = cli.verifier_explicit or verifier_present;
    result.run.verifier = cli.verifier orelse settings.verifier;
    result.run.verify_enabled = if (!cli.verify_enabled) false else if (cli.verifier != null) true else settings.verify_enabled;
    result.run.yolo = cli.yolo or settings.yolo;
    result.run.token_budget = cli.token_budget orelse settings.token_budget;
    result.run.timeout_seconds = cli.timeout_seconds orelse settings.timeout_seconds;
    result.run.output_mode = if (cli.output_mode != .live) cli.output_mode else settings.output_mode;
    result.run.extra_backend_args = if (cli.extra_args_explicit) cli.extra_backend_args else settings.extra_backend_args;
    result.run.prompt_file = cli.prompt_file orelse settings.prompt_file;
    result.run.prompt = try a.dupe(u8, result.run.prompt);
    if (result.run.model) |v| result.run.model = try a.dupe(u8, v);
    if (result.run.prompt_file) |v| result.run.prompt_file = try a.dupe(u8, v);
    if (result.run.config_path) |v| result.run.config_path = try a.dupe(u8, v);
    const args = try a.alloc([]const u8, result.run.extra_backend_args.len);
    for (result.run.extra_backend_args, 0..) |v, i| args[i] = try a.dupe(u8, v);
    result.run.extra_backend_args = args;
    return result;
}

fn applyLayer(a: std.mem.Allocator, io: std.Io, settings: *Config, source: []const u8, project: bool, required: bool, diagnostic: *std.Io.Writer, verifier_present: *bool) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, source, a, .limited(64 * 1024)) catch |err| {
        if (err == error.FileNotFound and !required) return;
        try diagnostic.print("Cannot read config {s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .allocate = .alloc_always }) catch |err| {
        try diagnostic.print("Invalid config {s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    applyObject(a, settings, root, source, project, diagnostic, verifier_present) catch |err| {
        try diagnostic.print("Invalid config {s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

fn applyObject(a: std.mem.Allocator, settings: *Config, root: std.json.Value, source: []const u8, project: bool, diagnostic: *std.Io.Writer, verifier_present: *bool) !void {
    if (root != .object) return error.InvalidConfigObject;
    if (root.object.get("schema_version")) |version| {
        if (version != .integer or version.integer != 1) return error.UnsupportedSchemaVersion;
    } else if (project) return error.MissingSchemaVersion;
    const value = if (project) root.object.get("loop") orelse return error.MissingLoopSettings else root;
    if (value != .object) return error.InvalidLoopSettings;
    if (project) {
        var keys = root.object.iterator();
        while (keys.next()) |entry| {
            if (!std.mem.eql(u8, entry.key_ptr.*, "loop") and !std.mem.eql(u8, entry.key_ptr.*, "schema_version")) return error.UnknownField;
        }
    }
    var iter = value.object.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const raw = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "verifier")) verifier_present.* = true;
        if (std.mem.eql(u8, key, "max_turns") or std.mem.eql(u8, key, "token_budget") or std.mem.eql(u8, key, "timeout_seconds")) {
            if (raw != .integer and raw != .null) {
                try diagnostic.print("Config {s}, field {s}: expected integer or null\n", .{ source, key });
                return error.InvalidFieldType;
            }
        }
        if (std.mem.eql(u8, key, "backend") or std.mem.eql(u8, key, "output_mode") or std.mem.eql(u8, key, "verifier")) {
            if (raw != .string and !(raw == .null and std.mem.eql(u8, key, "verifier"))) {
                try diagnostic.print("Config {s}, field {s}: expected backend/output name\n", .{ source, key });
                return error.InvalidFieldType;
            }
        }
        if (std.mem.eql(u8, key, "model") or std.mem.eql(u8, key, "prompt_file")) {
            if (raw != .string and raw != .null) return error.InvalidFieldType;
        }
        if (std.mem.eql(u8, key, "extra_backend_args")) {
            if (raw != .array) return error.InvalidFieldType;
            for (raw.array.items) |item| if (item != .string) return error.InvalidFieldType;
        }
        if (raw == .string) {
            if (std.mem.eql(u8, key, "backend") or std.mem.eql(u8, key, "verifier")) {
                if (std.meta.stringToEnum(options.BackendKind, raw.string) == null) return error.InvalidEnumTag;
            }
            if (std.mem.eql(u8, key, "output_mode") and std.meta.stringToEnum(options.OutputMode, raw.string) == null) return error.InvalidEnumTag;
        }
        var found = false;
        inline for (std.meta.fields(Config)) |field| {
            if (std.mem.eql(u8, key, field.name)) {
                if (project and std.mem.eql(u8, key, "schema_version")) return error.UnknownField;
                @field(settings, field.name) = std.json.parseFromValueLeaky(field.type, a, entry.value_ptr.*, .{}) catch |err| {
                    try diagnostic.print("Config {s}, field {s}: {s}\n", .{ source, key, @errorName(err) });
                    return err;
                };
                found = true;
            }
        }
        if (!found) {
            try diagnostic.print("Config {s}: unknown loop field {s}\n", .{ source, key });
            return error.UnknownField;
        }
        if (std.mem.eql(u8, key, "prompt_file")) {
            if (settings.prompt_file) |file| settings.prompt_file = try std.fs.path.resolve(a, &.{ std.fs.path.dirname(source) orelse ".", file });
        }
        if (std.mem.eql(u8, key, "max_turns") and settings.max_turns == 0) return error.InvalidLimit;
        if (std.mem.eql(u8, key, "token_budget") and settings.token_budget == 0) return error.InvalidLimit;
        if (std.mem.eql(u8, key, "timeout_seconds") and settings.timeout_seconds == 0) return error.InvalidLimit;
    }
}

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
    var parsed = try std.json.parseFromSlice(Config, allocator, bytes, .{ .allocate = .alloc_always });
    if (parsed.value.schema_version != 1) {
        parsed.deinit();
        return error.UnsupportedSchemaVersion;
    }
    return parsed;
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
    // Interactive editing changes only its three controls. Preserve key presence
    // as well as values for settings it does not edit.
    const original = std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, "{}"),
        else => return err,
    };
    defer allocator.free(original);
    var document = try std.json.parseFromSlice(std.json.Value, allocator, original, .{ .allocate = .alloc_always });
    defer document.deinit();
    if (document.value != .object) return error.InvalidConfigObject;
    const a = document.arena.allocator();
    try document.value.object.put(a, "backend", .{ .string = @tagName(config.backend) });
    try document.value.object.put(a, "model", if (config.model) |v| .{ .string = v } else .null);
    try document.value.object.put(a, "max_turns", if (config.max_turns) |v| .{ .integer = v } else .null);
    const encoded = try std.json.Stringify.valueAlloc(allocator, document.value, .{});
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

test "resolution preserves field presence, clears, path origins, and CLI precedence" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "user", .default_dir);
    try tmp.dir.createDir(std.testing.io, "project", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "user/loop.json", .data =
        \\{"backend":"droid","model":"user-model","max_turns":9,"prompt_file":"tasks/user.md","yolo":true,"verify_enabled":true,"extra_backend_args":["--user"],"token_budget":500,"timeout_seconds":90}
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/.matcha.json", .data =
        \\{"schema_version":1,"loop":{"backend":"agy","model":null,"max_turns":null,"yolo":false,"verify_enabled":false,"extra_backend_args":[],"token_budget":null}}
    });
    const user = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/user/loop.json", .{tmp.sub_path});
    defer a.free(user);
    const project = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/project/.matcha.json", .{tmp.sub_path});
    defer a.free(project);
    var diag: std.Io.Writer.Allocating = .init(a);
    defer diag.deinit();
    var inherited = try resolve(a, std.testing.io, .{ .backend = .codex, .prompt = "explicit" }, user, project, &diag.writer);
    defer inherited.deinit();
    try std.testing.expectEqual(options.BackendKind.agy, inherited.run.backend);
    try std.testing.expect(inherited.run.model == null);
    try std.testing.expect(inherited.run.max_turns == null);
    try std.testing.expect(inherited.run.token_budget == null);
    try std.testing.expect(!inherited.run.yolo);
    try std.testing.expect(!inherited.run.verify_enabled);
    try std.testing.expectEqual(@as(usize, 0), inherited.run.extra_backend_args.len);
    try std.testing.expectEqual(@as(u64, 90), inherited.run.timeout_seconds.?);
    const expected_prompt = try std.fs.path.resolve(a, &.{ std.fs.path.dirname(user).?, "tasks/user.md" });
    defer a.free(expected_prompt);
    try std.testing.expectEqualStrings(expected_prompt, inherited.run.prompt_file.?);

    var overridden = try resolve(a, std.testing.io, .{
        .backend = .codex,
        .backend_explicit = true,
        .prompt = "explicit",
        .model = "cli-model",
        .max_turns = null,
        .turn_limit_explicit = true,
        .prompt_file = "cli.md",
        .yolo = true,
        .verifier = .codex,
        .token_budget = 12,
        .extra_args_explicit = true,
        .extra_backend_args = &.{"--cli"},
    }, user, project, &diag.writer);
    defer overridden.deinit();
    try std.testing.expectEqual(options.BackendKind.codex, overridden.run.backend);
    try std.testing.expectEqualStrings("cli-model", overridden.run.model.?);
    try std.testing.expect(overridden.run.max_turns == null);
    try std.testing.expect(overridden.run.yolo);
    try std.testing.expect(overridden.run.verify_enabled);
    try std.testing.expectEqual(@as(u64, 12), overridden.run.token_budget.?);
    try std.testing.expectEqualStrings("--cli", overridden.run.extra_backend_args[0]);
    try std.testing.expectEqualStrings("cli.md", overridden.run.prompt_file.?);
}

test "resolution only opens selected files and diagnoses invalid explicit sources" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const selected = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/selected.json", .{tmp.sub_path});
    defer a.free(selected);
    var diag: std.Io.Writer.Allocating = .init(a);
    defer diag.deinit();
    var absent = try resolve(a, std.testing.io, .{ .backend = .codex, .prompt = "x" }, null, selected, &diag.writer);
    absent.deinit();
    try std.testing.expectError(error.FileNotFound, resolve(a, std.testing.io, .{ .backend = .codex, .prompt = "x", .config_path = selected }, null, selected, &diag.writer));
    const cases = [_]struct { json: []const u8, err: anyerror }{
        .{ .json = "{\"schema_version\":99,\"loop\":{}}", .err = error.UnsupportedSchemaVersion },
        .{ .json = "{\"schema_version\":1,\"loop\":{\"backend\":\"1\"}}", .err = error.InvalidEnumTag },
        .{ .json = "{\"schema_version\":1,\"loop\":{\"model\":[65]}}", .err = error.InvalidFieldType },
        .{ .json = "{\"schema_version\":1,\"loop\":{\"extra_backend_args\":[[65]]}}", .err = error.InvalidFieldType },
        .{ .json = "{\"schema_version\":1,\"loop\":{\"max_turns\":\"5\"}}", .err = error.InvalidFieldType },
        .{ .json = "{\"schema_version\":1,\"loop\":{\"max_turns\":5.0}}", .err = error.InvalidFieldType },
        .{ .json = "{\"schema_version\":1,\"loop\":{\"backend\":1}}", .err = error.InvalidFieldType },
        .{ .json = "{\"schema_version\":1,\"loop\":{\"verifier\":2}}", .err = error.InvalidFieldType },
        .{ .json = "{\"loop\":{}}", .err = error.MissingSchemaVersion },
        .{ .json = "{\"schema_version\":1,\"loop\":{\"mispelled\":true}}", .err = error.UnknownField },
        .{ .json = "{\"schema_version\":1,\"loop\":{\"yolo\":\"true\"}}", .err = error.UnexpectedToken },
        .{ .json = "{\"schema_version\":1,\"loop\":{\"max_turns\":0}}", .err = error.InvalidLimit },
    };
    for (cases) |case| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "selected.json", .data = case.json });
        try std.testing.expectError(case.err, resolve(a, std.testing.io, .{ .backend = .codex, .prompt = "x", .config_path = selected }, null, selected, &diag.writer));
    }
    try std.testing.expect(std.mem.indexOf(u8, diag.written(), selected) != null);
}

test "resolved layer ownership cleans all partial allocation failures" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "user.json", .data = "{\"model\":\"user\",\"prompt_file\":\"user.md\",\"extra_backend_args\":[\"--one\",\"two\"]}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project.json", .data = "{\"schema_version\":1,\"loop\":{\"model\":\"project\",\"prompt_file\":\"project.md\",\"extra_backend_args\":[\"replacement\"]}}" });
    const user = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/user.json", .{tmp.sub_path});
    defer a.free(user);
    const project = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/project.json", .{tmp.sub_path});
    defer a.free(project);
    var diag: std.Io.Writer.Allocating = .init(a);
    defer diag.deinit();
    var succeeded = false;
    for (0..128) |fail_index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        if (resolve(failing.allocator(), std.testing.io, .{ .backend = .codex, .prompt = "explicit" }, user, project, &diag.writer)) |resolved| {
            var owned = resolved;
            owned.deinit();
            succeeded = true;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (succeeded and !failing.has_induced_failure) break;
    }
    try std.testing.expect(succeeded);
}

test "legacy user config editing preserves fields outside interactive controls" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "loop.json", .data = "{\"backend\":\"droid\",\"prompt_file\":\"task.md\",\"verifier\":\"agy\",\"yolo\":true,\"verify_enabled\":false,\"extra_backend_args\":[\"--flag\"],\"token_budget\":500,\"timeout_seconds\":30,\"output_mode\":\"quiet\"}" });
    const source = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/loop.json", .{tmp.sub_path});
    defer a.free(source);
    var loaded = try loadAtPath(a, std.testing.io, source);
    defer loaded.deinit();
    var edited = loaded.value;
    edited.backend = .codex;
    edited.model = "new-model";
    edited.max_turns = 20;
    const saved = try saveAtPath(a, std.testing.io, try a.dupe(u8, source), edited);
    defer a.free(saved);
    var reread = try loadAtPath(a, std.testing.io, source);
    defer reread.deinit();
    try std.testing.expectEqual(options.BackendKind.codex, reread.value.backend);
    try std.testing.expectEqualStrings("new-model", reread.value.model.?);
    try std.testing.expectEqualStrings("task.md", reread.value.prompt_file.?);
    try std.testing.expectEqual(options.BackendKind.agy, reread.value.verifier.?);
    try std.testing.expect(reread.value.yolo);
    try std.testing.expect(!reread.value.verify_enabled);
    try std.testing.expectEqualStrings("--flag", reread.value.extra_backend_args[0]);
    try std.testing.expectEqual(@as(u64, 500), reread.value.token_budget.?);
    try std.testing.expectEqual(@as(u64, 30), reread.value.timeout_seconds.?);
    try std.testing.expectEqual(options.OutputMode.quiet, reread.value.output_mode);
}

test "interactive save preserves absence of verifier override" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const source = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/loop.json", .{tmp.sub_path});
    defer a.free(source);
    const saved = try saveAtPath(a, std.testing.io, try a.dupe(u8, source), .{ .model = "edited" });
    defer a.free(saved);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, source, a, .limited(4096));
    defer a.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "verifier") == null);
}
