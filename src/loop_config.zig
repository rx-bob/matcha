const std = @import("std");
const options = @import("loop_options.zig");
const path = @import("path.zig");

pub const Config = struct {
    schema_version: u32 = 1,
    backend: options.BackendKind = .codex,
    backend_bin: ?[]const u8 = null,
    model: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
    env: []const options.EnvEntry = &.{},
    path_prepend: []const []const u8 = &.{},
    max_turns: ?u32 = null,
    prompt_file: ?[]const u8 = null,
    verifier: ?options.BackendKind = null,
    verifier_options: options.VerifierOptions = .{},
    verify_enabled: bool = true,
    yolo: bool = false,
    sandbox: ?options.SandboxPolicy = null,
    token_budget: ?u64 = null,
    timeout_seconds: ?u64 = null,
    output_mode: options.OutputMode = .live,
    log_dir: ?[]const u8 = null,
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
    result.run.backend_bin = if (cli.backend_bin) |v| try resolveExecutablePath(a, io, ".", v) else settings.backend_bin;
    result.run.model = cli.model orelse settings.model;
    result.run.reasoning_effort = cli.reasoning_effort orelse settings.reasoning_effort;
    result.run.max_turns = if (cli.turn_limit_explicit) cli.max_turns else settings.max_turns;
    result.run.verifier_explicit = cli.verifier_explicit or verifier_present;
    result.run.verifier = cli.verifier orelse settings.verifier;
    result.run.verifier_options = settings.verifier_options;
    if (cli.verifier_options.model_explicit) {
        result.run.verifier_options.model = cli.verifier_options.model;
        result.run.verifier_options.model_explicit = true;
    }
    if (cli.verifier_options.reasoning_explicit) {
        result.run.verifier_options.reasoning_effort = cli.verifier_options.reasoning_effort;
        result.run.verifier_options.reasoning_explicit = true;
    }
    if (cli.verifier_options.backend_bin_explicit) {
        result.run.verifier_options.backend_bin = if (cli.verifier_options.backend_bin) |v| try resolveExecutablePath(a, io, ".", v) else null;
        result.run.verifier_options.backend_bin_explicit = true;
    }
    if (cli.verifier_options.args_explicit) {
        result.run.verifier_options.args = cli.verifier_options.args;
        result.run.verifier_options.args_explicit = true;
    }
    if (result.run.verifier_options.model) |v| result.run.verifier_options.model = try a.dupe(u8, v);
    const verifier_args = try a.alloc([]const u8, result.run.verifier_options.args.len);
    for (result.run.verifier_options.args, 0..) |v, i| verifier_args[i] = try a.dupe(u8, v);
    result.run.verifier_options.args = verifier_args;
    result.run.verify_enabled = if (!cli.verify_enabled) false else if (cli.verifier != null or cli.verifier_options.model_explicit or cli.verifier_options.backend_bin_explicit or cli.verifier_options.args_explicit) true else settings.verify_enabled;
    if (cli.sandbox != null and cli.yolo) return error.ConflictingPolicy;
    result.run.sandbox = if (cli.yolo) null else cli.sandbox orelse settings.sandbox;
    result.run.yolo = if (cli.sandbox != null) false else cli.yolo or settings.yolo;
    result.run.token_budget = cli.token_budget orelse settings.token_budget;
    result.run.timeout_seconds = cli.timeout_seconds orelse settings.timeout_seconds;
    result.run.output_mode = if (cli.output_mode != .live) cli.output_mode else settings.output_mode;
    result.run.log_dir = cli.log_dir orelse settings.log_dir;
    result.run.env = settings.env;
    for (cli.env_files) |file| try applyEnvFile(a, io, &result.run.env, file, diagnostic);
    for (cli.env) |entry| try mergeEnv(a, &result.run.env, entry);
    result.run.path_prepend = if (cli.path_prepend_explicit) try resolvePaths(a, io, ".", cli.path_prepend) else settings.path_prepend;
    result.run.extra_backend_args = if (cli.extra_args_explicit) cli.extra_backend_args else settings.extra_backend_args;
    result.run.prompt_file = cli.prompt_file orelse settings.prompt_file;
    result.run.prompt = try a.dupe(u8, result.run.prompt);
    if (result.run.model) |v| result.run.model = try a.dupe(u8, v);
    if (result.run.reasoning_effort) |v| result.run.reasoning_effort = try a.dupe(u8, v);
    if (result.run.verifier_options.reasoning_effort) |v| result.run.verifier_options.reasoning_effort = try a.dupe(u8, v);
    if (result.run.prompt_file) |v| result.run.prompt_file = try a.dupe(u8, v);
    if (result.run.log_dir) |v| result.run.log_dir = try std.fs.path.resolve(a, &.{ ".", v });
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
    applyObject(a, settings, root, source, project, diagnostic, verifier_present, io, true) catch |err| {
        try diagnostic.print("Invalid config {s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

fn applyObject(a: std.mem.Allocator, settings: *Config, root: std.json.Value, source: []const u8, project: bool, diagnostic: *std.Io.Writer, verifier_present: *bool, io: std.Io, resolve_paths: bool) !void {
    if (root != .object) return error.InvalidConfigObject;
    if (root.object.get("schema_version")) |version| {
        if (version != .integer or version.integer != 1) return error.UnsupportedSchemaVersion;
    } else if (project) return error.MissingSchemaVersion;
    const value = if (project) root.object.get("loop") orelse return error.MissingLoopSettings else root;
    if (value != .object) return error.InvalidLoopSettings;
    if (value.object.get("env_files")) |files| {
        if (files != .array) return error.InvalidFieldType;
        for (files.array.items) |item| {
            if (item != .string or item.string.len == 0) return error.InvalidFieldType;
            if (resolve_paths) {
                const file = try std.fs.path.resolve(a, &.{ std.fs.path.dirname(source) orelse ".", item.string });
                try applyEnvFile(a, io, &settings.env, file, diagnostic);
            }
        }
    }
    if (value.object.get("env")) |env_value| {
        if (env_value != .object) return error.InvalidFieldType;
        var env_it = env_value.object.iterator();
        while (env_it.next()) |entry| {
            if (entry.value_ptr.* != .string) return error.InvalidFieldType;
            try mergeEnv(a, &settings.env, .{ .key = entry.key_ptr.*, .value = entry.value_ptr.string });
        }
    }
    if (value.object.get("path_prepend")) |paths| {
        if (paths != .array) return error.InvalidFieldType;
        const raw_paths = try a.alloc([]const u8, paths.array.items.len);
        for (paths.array.items, 0..) |item, index| {
            if (item != .string or item.string.len == 0) return error.InvalidFieldType;
            raw_paths[index] = item.string;
        }
        settings.path_prepend = if (resolve_paths) try resolvePaths(a, io, std.fs.path.dirname(source) orelse ".", raw_paths) else raw_paths;
    }
    if (project) {
        var keys = root.object.iterator();
        while (keys.next()) |entry| {
            if (!std.mem.eql(u8, entry.key_ptr.*, "loop") and !std.mem.eql(u8, entry.key_ptr.*, "schema_version")) return error.UnknownField;
        }
    }
    if (value.object.contains("sandbox") and value.object.contains("yolo")) {
        try diagnostic.print("Config {s}: sandbox and yolo cannot both be selected in one layer\n", .{source});
        return error.ConflictingPolicy;
    }
    var iter = value.object.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const raw = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "env") or std.mem.eql(u8, key, "env_files") or std.mem.eql(u8, key, "path_prepend")) continue;
        if (std.mem.eql(u8, key, "sandbox")) {
            if (raw != .string and raw != .null) {
                try diagnostic.print("Config {s}, field sandbox: expected policy name or null\n", .{source});
                return error.InvalidFieldType;
            }
            settings.sandbox = if (raw == .null) .@"backend-default" else std.meta.stringToEnum(options.SandboxPolicy, raw.string) orelse {
                try diagnostic.print("Config {s}, field sandbox: expected read-only, workspace-write, danger-full-access, or backend-default\n", .{source});
                return error.InvalidEnumTag;
            };
            settings.yolo = false;
            continue;
        }
        if (std.mem.eql(u8, key, "yolo")) {
            if (raw != .bool) return error.InvalidFieldType;
            settings.yolo = raw.bool;
            if (raw.bool) settings.sandbox = null;
            continue;
        }
        if (std.mem.eql(u8, key, "verifier")) {
            applyVerifier(a, settings, raw, source, verifier_present, io, resolve_paths, diagnostic) catch |err| {
                try diagnostic.print("Config {s}, field verifier: {s}\n", .{ source, @errorName(err) });
                return err;
            };
            continue;
        }
        if (std.mem.eql(u8, key, "verifier_options")) return error.UnknownField;
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
        if (std.mem.eql(u8, key, "model") or std.mem.eql(u8, key, "reasoning_effort") or std.mem.eql(u8, key, "prompt_file") or std.mem.eql(u8, key, "backend_bin") or std.mem.eql(u8, key, "log_dir")) {
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
        if (resolve_paths and std.mem.eql(u8, key, "backend_bin")) {
            if (settings.backend_bin) |binary_value| {
                settings.backend_bin = resolveExecutablePath(a, io, std.fs.path.dirname(source) orelse ".", binary_value) catch |err| {
                    try diagnostic.print("Config {s}, field backend_bin: {s}\n", .{ source, @errorName(err) });
                    return err;
                };
            }
        }
        if (resolve_paths and std.mem.eql(u8, key, "prompt_file")) {
            if (settings.prompt_file) |file| settings.prompt_file = try std.fs.path.resolve(a, &.{ std.fs.path.dirname(source) orelse ".", file });
        }
        if (resolve_paths and std.mem.eql(u8, key, "log_dir")) {
            if (settings.log_dir) |directory| settings.log_dir = try std.fs.path.resolve(a, &.{ std.fs.path.dirname(source) orelse ".", directory });
        }
        if (std.mem.eql(u8, key, "max_turns") and settings.max_turns == 0) return error.InvalidLimit;
        if (std.mem.eql(u8, key, "token_budget") and settings.token_budget == 0) return error.InvalidLimit;
        if (std.mem.eql(u8, key, "timeout_seconds") and settings.timeout_seconds == 0) return error.InvalidLimit;
    }
}

fn applyVerifier(a: std.mem.Allocator, settings: *Config, value: std.json.Value, source: []const u8, backend_present: *bool, io: std.Io, resolve_paths: bool, diagnostic: *std.Io.Writer) !void {
    if (value == .null) {
        settings.verifier = null;
        settings.verifier_options = .{};
        backend_present.* = true;
        return;
    }
    if (value == .string) {
        settings.verifier = std.meta.stringToEnum(options.BackendKind, value.string) orelse return error.InvalidEnumTag;
        backend_present.* = true;
        return;
    }
    if (value != .object) return error.InvalidFieldType;
    var fields = value.object.iterator();
    while (fields.next()) |entry| {
        const key = entry.key_ptr.*;
        const raw = entry.value_ptr.*;
        errdefer diagnostic.print("Config {s}, verifier.{s} is invalid\n", .{ source, key }) catch {};
        if (std.mem.eql(u8, key, "backend")) {
            if (raw != .string and raw != .null) return error.InvalidFieldType;
            settings.verifier = if (raw == .null) null else std.meta.stringToEnum(options.BackendKind, raw.string) orelse return error.InvalidEnumTag;
            backend_present.* = true;
        } else if (std.mem.eql(u8, key, "model")) {
            if (raw != .string and raw != .null) return error.InvalidFieldType;
            settings.verifier_options.model = if (raw == .null) null else raw.string;
            settings.verifier_options.model_explicit = true;
        } else if (std.mem.eql(u8, key, "backend_bin")) {
            if (raw != .string and raw != .null) return error.InvalidFieldType;
            if (raw == .string and (raw.string.len == 0 or std.mem.indexOfScalar(u8, raw.string, 0) != null)) return error.InvalidExecutable;
            settings.verifier_options.backend_bin = if (raw == .null) null else if (resolve_paths) try resolveExecutablePath(a, io, std.fs.path.dirname(source) orelse ".", raw.string) else raw.string;
            settings.verifier_options.backend_bin_explicit = true;
        } else if (std.mem.eql(u8, key, "args")) {
            if (raw != .array) return error.InvalidFieldType;
            const args = try a.alloc([]const u8, raw.array.items.len);
            for (raw.array.items, 0..) |item, i| {
                if (item != .string) return error.InvalidFieldType;
                args[i] = item.string;
            }
            settings.verifier_options.args = args;
            settings.verifier_options.args_explicit = true;
        } else if (std.mem.eql(u8, key, "reasoning_effort")) {
            if (raw != .string and raw != .null) return error.InvalidFieldType;
            settings.verifier_options.reasoning_effort = if (raw == .null) null else raw.string;
            settings.verifier_options.reasoning_explicit = true;
        } else {
            try diagnostic.print("Config {s}: unknown verifier field {s}\n", .{ source, key });
            return error.UnknownField;
        }
    }
}

/// Bare names remain late-bound to the invocation PATH. Paths capture their source base.
pub fn resolveExecutablePath(a: std.mem.Allocator, io: std.Io, base: []const u8, value: []const u8) ![]const u8 {
    if (value.len == 0 or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidExecutable;
    const path_bearing = std.mem.indexOfScalar(u8, value, '/') != null or
        (@import("builtin").os.tag == .windows and std.mem.indexOfScalar(u8, value, '\\') != null);
    if (path_bearing) {
        const cwd = try std.process.currentPathAlloc(io, a);
        defer a.free(cwd);
        return std.fs.path.resolve(a, &.{ cwd, base, value });
    }
    return a.dupe(u8, value);
}

pub fn resolvePaths(a: std.mem.Allocator, io: std.Io, base: []const u8, values: []const []const u8) ![]const []const u8 {
    const cwd = try std.process.currentPathAlloc(io, a);
    defer a.free(cwd);
    const result = try a.alloc([]const u8, values.len);
    for (values, 0..) |value, index| {
        if (value.len == 0 or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidPathPrepend;
        result[index] = try std.fs.path.resolve(a, &.{ cwd, base, value });
    }
    return result;
}

pub fn mergeEnv(a: std.mem.Allocator, entries: *[]const options.EnvEntry, entry: options.EnvEntry) !void {
    if (!options.validEnvKey(entry.key) or std.mem.indexOfScalar(u8, entry.value, 0) != null) return error.InvalidEnvironmentEntry;
    for (entries.*, 0..) |existing, index| {
        if (std.mem.eql(u8, existing.key, entry.key)) {
            const replacement = try a.alloc(options.EnvEntry, entries.len);
            @memcpy(replacement, entries.*);
            replacement[index] = .{ .key = try a.dupe(u8, entry.key), .value = try a.dupe(u8, entry.value) };
            entries.* = replacement;
            return;
        }
    }
    const extended = try a.alloc(options.EnvEntry, entries.len + 1);
    @memcpy(extended[0..entries.len], entries.*);
    extended[entries.len] = .{ .key = try a.dupe(u8, entry.key), .value = try a.dupe(u8, entry.value) };
    entries.* = extended;
}

pub fn applyEnvFile(a: std.mem.Allocator, io: std.Io, entries: *[]const options.EnvEntry, file_path: []const u8, diagnostic: *std.Io.Writer) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, file_path, a, .limited(1024 * 1024)) catch |err| {
        try diagnostic.print("Cannot read env file {s}: {s}\n", .{ file_path, @errorName(err) });
        return err;
    };
    defer a.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trimStart(u8, line[7..], " \t");
        const parsed = options.parseEnvAssignment(line) orelse {
            try diagnostic.print("Invalid env file {s}:{d}: expected KEY=VALUE\n", .{ file_path, line_number });
            return error.InvalidEnvFile;
        };
        var value = parsed.value;
        if (value.len > 0 and (value[0] == '"' or value[0] == '\'')) {
            if (value.len < 2 or value[value.len - 1] != value[0]) {
                try diagnostic.print("Invalid env file {s}:{d}: unmatched quote\n", .{ file_path, line_number });
                return error.InvalidEnvFile;
            }
            value = value[1 .. value.len - 1];
        } else if (value.len > 0 and (value[value.len - 1] == '"' or value[value.len - 1] == '\'')) {
            try diagnostic.print("Invalid env file {s}:{d}: unmatched quote\n", .{ file_path, line_number });
            return error.InvalidEnvFile;
        }
        try mergeEnv(a, entries, .{ .key = parsed.key, .value = value });
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
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    var settings: Config = .{};
    var verifier_present = false;
    var diagnostic: std.Io.Writer.Allocating = .init(parsed.arena.allocator());
    defer diagnostic.deinit();
    try applyObject(parsed.arena.allocator(), &settings, parsed.value, config_path, false, &diagnostic.writer, &verifier_present, io, false);
    return .{ .arena = parsed.arena, .value = settings };
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

test "dotenv keeps literal values and reports malformed source lines" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/values.env", .{tmp.sub_path});
    defer allocator.free(file);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "values.env", .data = "# comment\nexport JAVA_HOME=\"/opt/jdk 21\"\r\nPATH='$HOME/bin'\nEMPTY=\nA=one=two\nA=last\n" });
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var entries: []const options.EnvEntry = &.{};
    var diagnostic = std.Io.Writer.Allocating.init(allocator);
    defer diagnostic.deinit();
    try applyEnvFile(arena.allocator(), std.testing.io, &entries, file, &diagnostic.writer);
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expectEqualStrings("/opt/jdk 21", entries[0].value);
    try std.testing.expectEqualStrings("$HOME/bin", entries[1].value);
    try std.testing.expectEqualStrings("", entries[2].value);
    try std.testing.expectEqualStrings("last", entries[3].value);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "values.env", .data = "GOOD=one\nBROKEN=\"unterminated\n" });
    try std.testing.expectError(error.InvalidEnvFile, applyEnvFile(arena.allocator(), std.testing.io, &entries, file, &diagnostic.writer));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.written(), ":2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.written(), "unterminated") == null);
}

test "config and cli environment layers flatten with source-relative path prefixes" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const user = try std.fmt.allocPrint(a, "{s}/user.json", .{root});
    defer a.free(user);
    const project = try std.fmt.allocPrint(a, "{s}/project.json", .{root});
    defer a.free(project);
    const cli_file = try std.fmt.allocPrint(a, "{s}/cli.env", .{root});
    defer a.free(cli_file);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "user.env", .data = "X=user-file\nU=user\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project.env", .data = "X=project-file\nP=project\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "cli.env", .data = "X=cli-file\nC=cli\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "user.json", .data = "{\"env_files\":[\"user.env\"],\"env\":{\"X\":\"user-direct\"},\"path_prepend\":[\"user-bin\"]}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project.json", .data = "{\"schema_version\":1,\"loop\":{\"env_files\":[\"project.env\"],\"env\":{\"X\":\"project-direct\"},\"path_prepend\":[\"project-bin\"]}}" });
    var diagnostic = std.Io.Writer.Allocating.init(a);
    defer diagnostic.deinit();
    var resolved = try resolve(a, std.testing.io, .{ .backend = .codex, .prompt = "task", .env_files = &.{cli_file}, .env = &.{.{ .key = "X", .value = "cli-direct" }} }, user, project, &diagnostic.writer);
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 4), resolved.run.env.len);
    for (resolved.run.env) |entry| {
        if (std.mem.eql(u8, entry.key, "X")) try std.testing.expectEqualStrings("cli-direct", entry.value);
    }
    try std.testing.expectEqualStrings("U", resolved.run.env[1].key);
    try std.testing.expectEqualStrings("project-bin", std.fs.path.basename(resolved.run.path_prepend[0]));
    try std.testing.expect(std.fs.path.isAbsolute(resolved.run.path_prepend[0]));
    var with_cli_paths = try resolve(a, std.testing.io, .{ .backend = .codex, .prompt = "task", .path_prepend = &.{ "first-bin", "second-bin" }, .path_prepend_explicit = true }, user, project, &diagnostic.writer);
    defer with_cli_paths.deinit();
    try std.testing.expectEqual(@as(usize, 2), with_cli_paths.run.path_prepend.len);
    try std.testing.expectEqualStrings("first-bin", std.fs.path.basename(with_cli_paths.run.path_prepend[0]));
    try std.testing.expectEqualStrings("second-bin", std.fs.path.basename(with_cli_paths.run.path_prepend[1]));
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
        .{ .json = "{\"schema_version\":1,\"loop\":{\"yolo\":\"true\"}}", .err = error.InvalidFieldType },
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
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "user.json", .data = "{\"model\":\"user\",\"backend_bin\":\"./user tool\",\"prompt_file\":\"user.md\",\"extra_backend_args\":[\"--one\",\"two\"]}" });
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

test "backend executable resolution preserves source base and bare names" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const user = try std.fs.path.join(a, &.{ root, "user.json" });
    defer a.free(user);
    const project = try std.fs.path.join(a, &.{ root, "project.json" });
    defer a.free(project);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "user.json", .data = "{\"backend_bin\":\"./tools/worker with spaces\"}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project.json", .data = "{\"schema_version\":1,\"loop\":{\"model\":\"project-model\"}}" });
    var diag: std.Io.Writer.Allocating = .init(a);
    defer diag.deinit();
    var inherited = try resolve(a, std.testing.io, .{ .backend = .codex, .prompt = "x" }, user, project, &diag.writer);
    defer inherited.deinit();
    const expected = try resolveExecutablePath(a, std.testing.io, root, "./tools/worker with spaces");
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, inherited.run.backend_bin.?);
    for ([_][]const u8{ "worker-name", "./worker with spaces" }) |binary| {
        var cli = try resolve(a, std.testing.io, .{ .backend = .codex, .backend_bin = binary, .prompt = "x" }, user, project, &diag.writer);
        defer cli.deinit();
        const resolved = try resolveExecutablePath(a, std.testing.io, ".", binary);
        defer a.free(resolved);
        try std.testing.expectEqualStrings(resolved, cli.run.backend_bin.?);
        if (std.mem.startsWith(u8, binary, "./")) try std.testing.expect(std.fs.path.isAbsolute(cli.run.backend_bin.?)) else try std.testing.expectEqualStrings(binary, cli.run.backend_bin.?);
    }
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project.json", .data = "{\"schema_version\":1,\"loop\":{\"backend_bin\":null}}" });
    var cleared = try resolve(a, std.testing.io, .{ .backend = .codex, .prompt = "x" }, user, project, &diag.writer);
    defer cleared.deinit();
    try std.testing.expect(cleared.run.backend_bin == null);
    try std.testing.expectError(error.InvalidExecutable, resolveExecutablePath(a, std.testing.io, ".", ""));
    try std.testing.expectError(error.InvalidExecutable, resolveExecutablePath(a, std.testing.io, ".", "bad\x00name"));
}

test "nested verifier patches retain presence source paths and replacement args" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const user = try std.fs.path.join(a, &.{ root, "user.json" });
    defer a.free(user);
    const project = try std.fs.path.join(a, &.{ root, "project.json" });
    defer a.free(project);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "user.json", .data = "{\"model\":\"worker\",\"verifier\":{\"backend\":\"agy\",\"model\":\"user-verifier\",\"backend_bin\":\"./tools/verifier with spaces\",\"args\":[\"--user\"]}}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project.json", .data = "{\"schema_version\":1,\"loop\":{\"verifier\":{\"model\":null,\"args\":[]}}}" });
    var diagnostic: std.Io.Writer.Allocating = .init(a);
    defer diagnostic.deinit();
    var resolved = try resolve(a, std.testing.io, .{ .backend = .codex, .prompt = "task" }, user, project, &diagnostic.writer);
    defer resolved.deinit();
    try std.testing.expectEqual(options.BackendKind.agy, resolved.run.verifier.?);
    try std.testing.expect(resolved.run.verifier_options.model_explicit);
    try std.testing.expect(resolved.run.verifier_options.model == null);
    try std.testing.expectEqual(@as(usize, 0), resolved.run.verifier_options.args.len);
    try std.testing.expect(resolved.run.verifier_options.args_explicit);
    const expected = try resolveExecutablePath(a, std.testing.io, root, "./tools/verifier with spaces");
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, resolved.run.verifier_options.backend_bin.?);
    const parsed = options.parseLoopCommand(a, &.{ "task", "--verifier-model=cli", "--verifier-bin=", "--verifier-arg=--cli", "--verifier-arg", "value", "--", "--worker" }, true, "");
    defer options.deinitParsedRun(a, parsed.ok.run);
    var overridden = try resolve(a, std.testing.io, parsed.ok.run, user, project, &diagnostic.writer);
    defer overridden.deinit();
    try std.testing.expectEqualStrings("cli", overridden.run.verifier_options.model.?);
    try std.testing.expect(overridden.run.verifier_options.backend_bin_explicit);
    try std.testing.expect(overridden.run.verifier_options.backend_bin == null);
    try std.testing.expectEqual(@as(usize, 2), overridden.run.verifier_options.args.len);
    try std.testing.expectEqualStrings("--cli", overridden.run.verifier_options.args[0]);
    try std.testing.expectEqualStrings("--worker", overridden.run.extra_backend_args[0]);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project.json", .data = "{\"schema_version\":1,\"loop\":{\"verifier\":null}}" });
    var cleared = try resolve(a, std.testing.io, .{ .backend = .codex, .prompt = "task" }, user, project, &diagnostic.writer);
    defer cleared.deinit();
    try std.testing.expect(cleared.run.verifier == null);
    try std.testing.expect(!cleared.run.verifier_options.model_explicit);
    try std.testing.expect(!cleared.run.verifier_options.backend_bin_explicit);
}

test "nested verifier validation is strict and interactive edits preserve raw paths" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/loop.json", .{tmp.sub_path});
    defer a.free(source);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "loop.json", .data = "{\"verifier\":{\"backend\":\"droid\",\"model\":null,\"backend_bin\":\"./relative tool\",\"args\":[\"--literal\"]}}" });
    var loaded = try loadAtPath(a, std.testing.io, source);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("./relative tool", loaded.value.verifier_options.backend_bin.?);
    var edited = loaded.value;
    edited.model = "worker-edit";
    const saved = try saveAtPath(a, std.testing.io, try a.dupe(u8, source), edited);
    defer a.free(saved);
    var after = try loadAtPath(a, std.testing.io, source);
    defer after.deinit();
    try std.testing.expect(after.value.verifier_options.model_explicit);
    try std.testing.expect(after.value.verifier_options.model == null);
    try std.testing.expectEqualStrings("./relative tool", after.value.verifier_options.backend_bin.?);
    try std.testing.expectEqualStrings("--literal", after.value.verifier_options.args[0]);
    const cases = [_]struct { json: []const u8, err: anyerror }{
        .{ .json = "{\"verifier\":{\"bogus\":true}}", .err = error.UnknownField },
        .{ .json = "{\"verifier\":{\"model\":[65]}}", .err = error.InvalidFieldType },
        .{ .json = "{\"verifier\":{\"backend\":\"1\"}}", .err = error.InvalidEnumTag },
        .{ .json = "{\"verifier\":{\"args\":[12]}}", .err = error.InvalidFieldType },
        .{ .json = "{\"verifier\":{\"reasoning_effort\":12}}", .err = error.InvalidFieldType },
    };
    for (cases) |case| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "loop.json", .data = case.json });
        try std.testing.expectError(case.err, loadAtPath(a, std.testing.io, source));
    }
}

test "nested verifier resolved allocations clean partial failures" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/loop.json", .{tmp.sub_path});
    defer a.free(source);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "loop.json", .data = "{\"schema_version\":1,\"loop\":{\"verifier\":{\"model\":\"verifier\",\"backend_bin\":\"./tool\",\"args\":[\"--one\",\"two\"]}}}" });
    var diagnostic: std.Io.Writer.Allocating = .init(a);
    defer diagnostic.deinit();
    var succeeded = false;
    for (0..128) |fail_index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        if (resolve(failing.allocator(), std.testing.io, .{ .backend = .codex, .prompt = "task" }, null, source, &diagnostic.writer)) |result| {
            var owned = result;
            owned.deinit();
            succeeded = true;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (succeeded and !failing.has_induced_failure) break;
    }
    try std.testing.expect(succeeded);
}

test "policy layers replace inherited sandbox or yolo as one choice" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const user = try std.fs.path.join(a, &.{ root, "user.json" });
    defer a.free(user);
    const project = try std.fs.path.join(a, &.{ root, "project.json" });
    defer a.free(project);
    var diagnostic: std.Io.Writer.Allocating = .init(a);
    defer diagnostic.deinit();
    const cases = [_]struct { user: []const u8, project: []const u8, sandbox: ?options.SandboxPolicy, yolo: bool }{
        .{ .user = "{\"yolo\":true}", .project = "{\"sandbox\":\"workspace-write\"}", .sandbox = .@"workspace-write", .yolo = false },
        .{ .user = "{\"sandbox\":\"workspace-write\"}", .project = "{\"yolo\":true}", .sandbox = null, .yolo = true },
        .{ .user = "{\"yolo\":true}", .project = "{\"sandbox\":null}", .sandbox = .@"backend-default", .yolo = false },
        .{ .user = "{\"sandbox\":\"danger-full-access\"}", .project = "{\"yolo\":false}", .sandbox = .@"danger-full-access", .yolo = false },
        .{ .user = "{\"yolo\":true}", .project = "{\"yolo\":false}", .sandbox = null, .yolo = false },
        .{ .user = "{}", .project = "{}", .sandbox = null, .yolo = false },
    };
    for (cases) |case| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "user.json", .data = case.user });
        const encoded = try std.fmt.allocPrint(a, "{{\"schema_version\":1,\"loop\":{s}}}", .{case.project});
        defer a.free(encoded);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project.json", .data = encoded });
        var resolved = try resolve(a, std.testing.io, .{ .backend = .codex, .prompt = "task" }, user, project, &diagnostic.writer);
        defer resolved.deinit();
        try std.testing.expectEqual(case.sandbox, resolved.run.sandbox);
        try std.testing.expectEqual(case.yolo, resolved.run.yolo);
        var cli_sandbox = try resolve(a, std.testing.io, .{ .backend = .codex, .prompt = "task", .sandbox = .@"read-only" }, user, project, &diagnostic.writer);
        defer cli_sandbox.deinit();
        try std.testing.expectEqual(options.SandboxPolicy.@"read-only", cli_sandbox.run.sandbox.?);
        try std.testing.expect(!cli_sandbox.run.yolo);
        var cli_yolo = try resolve(a, std.testing.io, .{ .backend = .codex, .prompt = "task", .yolo = true }, user, project, &diagnostic.writer);
        defer cli_yolo.deinit();
        try std.testing.expect(cli_yolo.run.sandbox == null);
        try std.testing.expect(cli_yolo.run.yolo);
    }
    const invalid = [_]struct { json: []const u8, err: anyerror }{
        .{ .json = "{\"sandbox\":\"workspace-write\",\"yolo\":true}", .err = error.ConflictingPolicy },
        .{ .json = "{\"yolo\":false,\"sandbox\":null}", .err = error.ConflictingPolicy },
        .{ .json = "{\"sandbox\":1}", .err = error.InvalidFieldType },
        .{ .json = "{\"sandbox\":\"1\"}", .err = error.InvalidEnumTag },
        .{ .json = "{\"sandbox\":\"full\"}", .err = error.InvalidEnumTag },
    };
    for (invalid) |case| {
        const encoded = try std.fmt.allocPrint(a, "{{\"schema_version\":1,\"loop\":{s}}}", .{case.json});
        defer a.free(encoded);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project.json", .data = encoded });
        try std.testing.expectError(case.err, resolve(a, std.testing.io, .{ .backend = .codex, .prompt = "task" }, null, project, &diagnostic.writer));
    }
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.written(), project) != null);
}
