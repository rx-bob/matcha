const std = @import("std");
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("poll.h");
    @cInclude("sys/ioctl.h");
});

const assets = @import("assets.zig");
const errors = @import("errors.zig");
const path = @import("path.zig");
const json_input = @import("json_input.zig");
const render_html = @import("render_html.zig");
const render_markdown = @import("render_markdown.zig");
const plan_read = @import("plan_read.zig");
const serve_options = @import("serve_options.zig");
const serve = @import("serve.zig");
const loop_options = @import("loop_options.zig");
const loop_config = @import("loop_config.zig");
const loop_models = @import("loop_models.zig");
const loop_store = @import("loop_store.zig");
const loop_runtime = @import("loop.zig");
const loop_backend = @import("loop_backend.zig");

pub const version = "0.1.0";

pub const ExitCode = serve_options.ExitCode;

pub const RenderOptions = struct {
    target: render_html.RenderTarget,
    input: []const u8,
    output: []const u8,
};

pub const RenderOptionsResult = union(enum) {
    ok: RenderOptions,
    err: errors.CliError,
};

pub fn run(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const args = if (argv.len > 0) argv[1..] else argv;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    const exit_code = runArgsRuntime(args, init.io, stdout, stderr, null, init.environ_map, null) catch |err| blk: {
        try stderr.print("Internal error: {s}\n", .{@errorName(err)});
        break :blk ExitCode.failure;
    };
    try stdout.flush();
    try stderr.flush();

    if (exit_code != .ok) {
        std.process.exit(@intFromEnum(exit_code));
    }
}

pub fn runArgs(args: []const []const u8, io: std.Io, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !ExitCode {
    var environment = std.process.Environ.Map.init(std.heap.page_allocator);
    defer environment.deinit();
    if (std.c.getenv("PATH")) |path_value| try environment.put("PATH", std.mem.span(path_value));
    return runArgsRuntime(args, io, stdout, stderr, null, &environment, null);
}

fn runArgsWithLoopStoreRoot(
    args: []const []const u8,
    io: std.Io,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    store_root: ?[]const u8,
) !ExitCode {
    var environment = std.process.Environ.Map.init(std.heap.page_allocator);
    defer environment.deinit();
    if (std.c.getenv("PATH")) |path_value| try environment.put("PATH", std.mem.span(path_value));
    return runArgsRuntime(args, io, stdout, stderr, store_root, &environment, null);
}

pub fn runArgsRuntime(
    args: []const []const u8,
    io: std.Io,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    store_root: ?[]const u8,
    parent_environment: *const std.process.Environ.Map,
    runner_override: ?loop_backend.BackendRunner,
) !ExitCode {
    const command = if (args.len > 0) args[0] else "";

    if (isHelpCommand(command)) {
        try writeHelp(stdout);
        return .ok;
    }

    if (isVersionCommand(command)) {
        try writeVersion(stdout);
        return .ok;
    }

    if (std.mem.eql(u8, command, "usage")) {
        try writeUsageGuide(stdout);
        return .ok;
    }

    if (std.mem.eql(u8, command, "plan")) {
        if (args.len > 1 and std.mem.eql(u8, args[1], "read")) {
            return runPlanReadCommand(io, args[2..], stdout, stderr);
        }
        return runRenderCommand(.plan, io, args[1..], stdout, stderr);
    }

    if (std.mem.eql(u8, command, "map")) {
        return runRenderCommand(.map, io, args[1..], stdout, stderr);
    }

    if (std.mem.eql(u8, command, "serve")) {
        return runServeCommand(io, args[1..], stdout, stderr);
    }

    if (std.mem.eql(u8, command, "loop")) {
        return runLoopCommand(io, args[1..], stdout, stderr, store_root, parent_environment, runner_override);
    }

    try writeHelp(stdout);
    try stdout.writeByte('\n');
    try stderr.print("Unknown command: {s}\n", .{command});
    return .usage;
}

fn runLoopCommand(
    io: std.Io,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    store_root: ?[]const u8,
    parent_environment: *const std.process.Environ.Map,
    runner_override: ?loop_backend.BackendRunner,
) !ExitCode {
    return runLoopCommandWithInputs(io, args, stdout, stderr, store_root, parent_environment, runner_override, null);
}

pub const LoopInputs = struct {
    user_path: ?[]const u8 = null,
    project_path: []const u8,
    stdin_bytes: []const u8 = "",
};

pub fn runLoopCommandWithInputs(
    io: std.Io,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    store_root: ?[]const u8,
    parent_environment: *const std.process.Environ.Map,
    runner_override: ?loop_backend.BackendRunner,
    inputs: ?LoopInputs,
) !ExitCode {
    const command = switch (loop_options.parseLoopCommand(std.heap.page_allocator, args, true, "")) {
        .ok => |parsed| parsed,
        .err => |cli_error| {
            try writeCliError(stderr, cli_error);
            try writeLoopUsage(stderr);
            return .usage;
        },
    };
    defer switch (command) {
        .run => |run_options| loop_options.deinitParsedRun(std.heap.page_allocator, run_options),
        .@"resume" => |resume_options| loop_options.deinitParsedResume(std.heap.page_allocator, resume_options),
        else => {},
    };
    switch (command) {
        .config => return runLoopConfig(io, stdout, stderr),
        .help => {
            try writeLoopHelp(stdout);
            return .ok;
        },
        else => {},
    }

    var store = loop_store.Store.init(std.heap.page_allocator, io, store_root) catch |err| {
        try stderr.print("Cannot initialize loop store: {s}\n", .{@errorName(err)});
        return .failure;
    };
    defer store.deinit();

    switch (command) {
        .run => |run_options| {
            const user_path = if (inputs == null) try loop_config.configPathAlloc(std.heap.page_allocator) else null;
            defer if (user_path) |v| std.heap.page_allocator.free(v);
            var resolved = loop_config.resolve(std.heap.page_allocator, io, run_options, if (inputs) |v| v.user_path else user_path, run_options.config_path orelse (if (inputs) |v| v.project_path else ".matcha.json"), stderr) catch return .failure;
            defer resolved.deinit();
            var effective_options = resolved.run;
            const a = resolved.arena.allocator();
            if (!run_options.prompt_explicit and run_options.prompt_file == null and (inputs != null or !(std.Io.File.stdin().isTty(io) catch true))) {
                var buffer: [4096]u8 = undefined;
                var reader = std.Io.File.stdin().reader(io, &buffer);
                const bytes = if (inputs) |v| v.stdin_bytes else reader.interface.allocRemaining(a, .limited(1024 * 1024)) catch |err| {
                    try stderr.print("Cannot read prompt stdin (maximum 1 MiB): {s}\n", .{@errorName(err)});
                    return .failure;
                };
                if (std.mem.trim(u8, bytes, " \t\r\n").len != 0) effective_options.prompt = bytes;
            }
            if (!run_options.prompt_explicit and effective_options.prompt.len == 0) {
                if (effective_options.prompt_file) |prompt_path| {
                    effective_options.prompt = std.Io.Dir.cwd().readFileAlloc(io, prompt_path, a, .limited(1024 * 1024)) catch |err| {
                        try stderr.print("Cannot read prompt file {s} (maximum 1 MiB): {s}\n", .{ prompt_path, @errorName(err) });
                        return .failure;
                    };
                }
            }
            if (std.mem.trim(u8, effective_options.prompt, " \t\r\n").len == 0) {
                try writeCliError(stderr, .missing_prompt);
                return .usage;
            }
            var real_runner: loop_backend.RealBackendRunner = .{};
            const services: loop_runtime.Services = .{
                .allocator = std.heap.page_allocator,
                .io = io,
                .store = &store,
                .parent_environment = parent_environment,
                .runner = runner_override orelse real_runner.runner(),
                .stdout = stdout,
                .stderr = stderr,
            };
            return switch (try loop_runtime.run(services, effective_options)) {
                .ok => .ok,
                .failure => .failure,
            };
        },
        .@"resume" => |resume_options| {
            var id: ?[]const u8 = resume_options.id;
            var owned_id: ?[]const u8 = null;
            defer if (owned_id) |value| std.heap.page_allocator.free(value);
            if (resume_options.last) {
                owned_id = try store.resolveLatestLoopId();
                id = owned_id;
            }
            const resolved_id = id orelse {
                try stderr.writeAll("No loop to resume; create one with matcha loop or pass an id.\n");
                return .usage;
            };
            var real_runner: loop_backend.RealBackendRunner = .{};
            const services: loop_runtime.Services = .{
                .allocator = std.heap.page_allocator,
                .io = io,
                .store = &store,
                .parent_environment = parent_environment,
                .runner = runner_override orelse real_runner.runner(),
                .stdout = stdout,
                .stderr = stderr,
            };
            return switch (loop_runtime.resumeLoopWithOptions(services, resolved_id, resume_options) catch |err| {
                if (err == error.LoopCannotResume) {
                    try stderr.print("Cannot resume loop {s} from its current status\n", .{resolved_id});
                    return .failure;
                }
                if (err == error.FileNotFound or err == error.NotDir) return reportLoopStoreError(err, resolved_id, stderr);
                return err;
            }) {
                .ok => .ok,
                .failure => .failure,
            };
        },
        .list => return writeLoopList(&store, stdout, stderr),
        .show => |options| {
            const id = resolveLoopId(options.id, io) orelse {
                try stderr.writeAll("Loop ID required; pass <id> or set MATCHA_LOOP_ID\n");
                return .usage;
            };
            return writeLoopShow(&store, id, stdout, stderr);
        },
        .update => |options| {
            const id = resolveLoopId(options.id, io) orelse {
                try stderr.writeAll("Loop ID required; pass <id> or set MATCHA_LOOP_ID\n");
                return .usage;
            };
            return updateLoop(&store, id, options, stdout, stderr);
        },
        .verify => |options| {
            const id = resolveLoopId(options.id, io) orelse {
                try stderr.writeAll("Loop ID required; pass <id> or set MATCHA_LOOP_ID\n");
                return .usage;
            };
            return verifyLoop(&store, id, options, stdout, stderr);
        },
        else => unreachable,
    }
}

fn runLoopConfig(io: std.Io, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !ExitCode {
    var config: loop_config.Config = .{};
    var parsed: ?std.json.Parsed(loop_config.Config) = loop_config.load(std.heap.page_allocator, io) catch |err| blk: {
        if (err != error.FileNotFound) {
            try stderr.print("Cannot read existing matcha loop config: {s}\n", .{@errorName(err)});
            return .failure;
        }
        break :blk null;
    };
    defer if (parsed) |*value| value.deinit();
    if (parsed) |*value| {
        config = value.value;
        if (config.model) |model| {
            // Clear the borrowed JSON slice before transferring ownership so
            // an allocation failure cannot make the outer cleanup free it.
            config.model = null;
            config.model = try std.heap.page_allocator.dupe(u8, model);
        }
    }
    defer if (config.model) |model| std.heap.page_allocator.free(model);

    var input = stdinDirectoryAcquirer(io);
    const acquirer = input.acquirer();
    if (!acquirer.isInteractive()) {
        try stderr.writeAll("matcha loop config requires an interactive terminal.\n");
        return .usage;
    }

    const backend_choices = [_][]const u8{ "codex", "droid", "agy" };
    const backend_index: usize = switch (config.backend) {
        .codex => 0,
        .droid => 1,
        .agy => 2,
    };
    const previous_backend = config.backend;
    config.backend = switch (try selectConfigOption(stdout, "Default harness", &backend_choices, backend_index)) {
        0 => .codex,
        1 => .droid,
        2 => .agy,
        else => unreachable,
    };
    if (config.backend != previous_backend) {
        if (config.model) |old_model| std.heap.page_allocator.free(old_model);
        config.model = null;
    }

    var discovery_binary: ?[]const u8 = null;
    defer if (discovery_binary) |v| std.heap.page_allocator.free(v);
    if (config.backend == previous_backend) {
        if (config.backend_bin) |v| {
            const source = try loop_config.configPathAlloc(std.heap.page_allocator);
            defer std.heap.page_allocator.free(source);
            discovery_binary = try loop_config.resolveExecutablePath(std.heap.page_allocator, io, std.fs.path.dirname(source) orelse ".", v);
        }
    }
    var catalog = try loop_models.load(std.heap.page_allocator, io, config.backend, discovery_binary);
    defer catalog.deinit();
    var model_choices: std.ArrayList(ConfigModelChoice) = .empty;
    defer {
        for (model_choices.items) |choice| if (choice.owns_label) std.heap.page_allocator.free(choice.label);
        model_choices.deinit(std.heap.page_allocator);
    }
    try model_choices.append(std.heap.page_allocator, .{ .id = null, .label = "Harness default (no model override)" });
    var selected_model: usize = 0;
    var has_saved_model = false;
    for (catalog.items.items) |model| {
        const label = try std.fmt.allocPrint(std.heap.page_allocator, "{s} [{s}]", .{ model.name, model.id });
        errdefer std.heap.page_allocator.free(label);
        const index = model_choices.items.len;
        try model_choices.append(std.heap.page_allocator, .{ .id = model.id, .label = label, .owns_label = true });
        if (config.model) |saved| if (std.mem.eql(u8, saved, model.id)) {
            selected_model = index;
            has_saved_model = true;
        };
    }
    if (config.model) |saved| {
        if (!has_saved_model) {
            const label = try std.fmt.allocPrint(std.heap.page_allocator, "Saved model [{s}]", .{saved});
            errdefer std.heap.page_allocator.free(label);
            selected_model = model_choices.items.len;
            try model_choices.append(std.heap.page_allocator, .{ .id = saved, .label = label, .owns_label = true });
        }
    }
    const custom_model_choice = model_choices.items.len;
    try model_choices.append(std.heap.page_allocator, .{ .id = null, .label = "Enter a custom model ID", .custom = true });
    const model_labels = try std.heap.page_allocator.alloc([]const u8, model_choices.items.len);
    defer std.heap.page_allocator.free(model_labels);
    for (model_choices.items, 0..) |choice, index| model_labels[index] = choice.label;
    const selected_choice = try selectConfigOption(stdout, "Default model", model_labels, selected_model);
    if (selected_choice == custom_model_choice) {
        try stdout.writeAll("Model ID: ");
        try stdout.flush();
        const model_line = try readConfigLine(acquirer, stderr);
        defer std.heap.page_allocator.free(model_line);
        const model_value = std.mem.trim(u8, model_line, " \t\r\n");
        if (model_value.len == 0) {
            try stderr.writeAll("Model ID cannot be empty.\n");
            return .usage;
        }
        const owned_model = try std.heap.page_allocator.dupe(u8, model_value);
        if (config.model) |old_model| std.heap.page_allocator.free(old_model);
        config.model = owned_model;
    } else if (model_choices.items[selected_choice].id) |selected_id| {
        const owned_model = try std.heap.page_allocator.dupe(u8, selected_id);
        if (config.model) |old_model| std.heap.page_allocator.free(old_model);
        config.model = owned_model;
    } else {
        if (config.model) |old_model| std.heap.page_allocator.free(old_model);
        config.model = null;
    }

    const turn_choices = [_][]const u8{ "unlimited", "set a maximum" };
    const turn_selection = try selectConfigOption(stdout, "Turn limit", &turn_choices, if (config.max_turns == null) 0 else 1);
    if (turn_selection == 0) {
        config.max_turns = null;
    } else {
        try stdout.print("Maximum turns (current: {d}): ", .{config.max_turns orelse 10});
        try stdout.flush();
        const turns_line = try readConfigLine(acquirer, stderr);
        defer std.heap.page_allocator.free(turns_line);
        const turns_value = std.mem.trim(u8, turns_line, " \t\r\n");
        config.max_turns = std.fmt.parseInt(u32, turns_value, 10) catch {
            try stderr.writeAll("Maximum turns must be a positive integer.\n");
            return .usage;
        };
        if (config.max_turns.? == 0) {
            try stderr.writeAll("Maximum turns must be a positive integer.\n");
            return .usage;
        }
    }

    const saved_path = loop_config.save(std.heap.page_allocator, io, config) catch |err| {
        try stderr.print("Cannot save matcha loop config: {s}\n", .{@errorName(err)});
        return .failure;
    };
    defer std.heap.page_allocator.free(saved_path);
    try stdout.print("Saved matcha loop defaults to {s}\n", .{saved_path});
    return .ok;
}

fn selectConfigOption(stdout: *std.Io.Writer, title: []const u8, choices: []const []const u8, initial: usize) !usize {
    var original: c.struct_termios = undefined;
    if (c.tcgetattr(c.STDIN_FILENO, &original) != 0) return error.TerminalSetupFailed;
    var raw = original;
    raw.c_lflag &= @as(c.tcflag_t, ~@as(c.tcflag_t, c.ICANON | c.ECHO));
    raw.c_cc[c.VMIN] = 1;
    raw.c_cc[c.VTIME] = 0;
    if (c.tcsetattr(c.STDIN_FILENO, c.TCSANOW, &raw) != 0) return error.TerminalSetupFailed;
    defer _ = c.tcsetattr(c.STDIN_FILENO, c.TCSANOW, &original);

    var selected = @min(initial, choices.len - 1);
    var first_visible = visibleMenuStart(selected, choices.len);
    try drawConfigMenu(stdout, title, choices, selected, first_visible, false);
    while (true) {
        var byte: u8 = 0;
        if (c.read(c.STDIN_FILENO, &byte, 1) != 1) return error.TerminalReadFailed;
        if (byte == '\r' or byte == '\n') {
            try stdout.writeByte('\n');
            try stdout.flush();
            return selected;
        }
        if (byte == 3) return error.ConfigCancelled;
        var changed = false;
        if (byte == 0x1b) {
            var poll_fd = c.struct_pollfd{ .fd = c.STDIN_FILENO, .events = c.POLLIN, .revents = 0 };
            if (c.poll(&poll_fd, 1, 80) > 0 and (poll_fd.revents & c.POLLIN) != 0) {
                var sequence: [2]u8 = undefined;
                if (c.read(c.STDIN_FILENO, &sequence, 2) == 2 and sequence[0] == '[') {
                    if (sequence[1] == 'A') {
                        selected = if (selected == 0) choices.len - 1 else selected - 1;
                        changed = true;
                    } else if (sequence[1] == 'B') {
                        selected = (selected + 1) % choices.len;
                        changed = true;
                    }
                }
            }
        } else if (byte == 'k' or byte == 'K') {
            selected = if (selected == 0) choices.len - 1 else selected - 1;
            changed = true;
        } else if (byte == 'j' or byte == 'J') {
            selected = (selected + 1) % choices.len;
            changed = true;
        }
        if (changed) {
            first_visible = visibleMenuStart(selected, choices.len);
            try drawConfigMenu(stdout, title, choices, selected, first_visible, true);
        }
    }
}

const ConfigModelChoice = struct {
    id: ?[]const u8,
    label: []const u8,
    owns_label: bool = false,
    custom: bool = false,
};

fn visibleMenuStart(selected: usize, count: usize) usize {
    const visible_count = @min(count, 10);
    if (selected >= visible_count) return selected - visible_count + 1;
    return 0;
}

fn drawConfigMenu(stdout: *std.Io.Writer, title: []const u8, choices: []const []const u8, selected: usize, first_visible: usize, redraw: bool) !void {
    const visible_count = @min(choices.len, 10);
    const columns = configMenuColumns();
    if (redraw) {
        try stdout.print("\x1b[{d}A\r\x1b[J", .{visible_count + 1});
    }
    var header_buffer: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "{s} ({d}/{d}; ↑/↓, Enter)", .{ title, selected + 1, choices.len });
    try stdout.writeAll(truncateUtf8(header, columns));
    try stdout.writeByte('\n');
    for (choices[first_visible .. first_visible + visible_count], first_visible..) |choice, index| {
        try stdout.writeAll(if (index == selected) "> " else "  ");
        try stdout.writeAll(truncateUtf8(choice, columns -| 2));
        try stdout.writeByte('\n');
    }
    try stdout.flush();
}

fn configMenuColumns() usize {
    var window: c.struct_winsize = undefined;
    if (c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &window) == 0 and window.ws_col > 0) return window.ws_col;
    return 80;
}

fn readConfigLine(acquirer: DirectoryAcquirer, stderr: *std.Io.Writer) ![]const u8 {
    return switch (acquirer.readLine(std.heap.page_allocator)) {
        .ok => |line| line,
        .err => |err| {
            try stderr.print("Could not read configuration input: {s}\n", .{@tagName(err)});
            return error.ConfigInputFailed;
        },
    };
}

fn resolveLoopId(explicit_id: ?[]const u8, io: std.Io) ?[]const u8 {
    _ = io;
    if (explicit_id) |id| return id;
    const env = std.c.getenv("MATCHA_LOOP_ID") orelse return null;
    const value = std.mem.span(env);
    return if (value.len > 0) value else null;
}

fn updateLoop(store: *const loop_store.Store, id: []const u8, options: loop_options.UpdateOptions, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !ExitCode {
    var parsed = store.loadState(id) catch |err| return reportLoopStoreError(err, id, stderr);
    defer parsed.deinit();
    var state = parsed.value;
    switch (options.status) {
        .complete => {
            if (state.status != .active) {
                try stderr.print("Cannot mark loop {s} complete from status {s}\n", .{ id, @tagName(state.status) });
                return .failure;
            }
            state.status = if (state.verify_enabled) .verifying else .complete;
            state.completion_summary = options.summary;
        },
        .blocked => {
            if (state.status != .active) {
                try stderr.print("Cannot record blocker for loop {s} from status {s}\n", .{ id, @tagName(state.status) });
                return .failure;
            }
            state.blocked_strikes = @min(state.blocked_strikes +| 1, 3);
            state.last_blocker_summary = options.summary;
            if (state.blocked_strikes >= 3) {
                state.status = .blocked;
            } else {
                state.status = .active;
            }
        },
    }
    state.updated_at_ms = @intCast(@max(0, std.Io.Clock.real.now(store.io).toMilliseconds()));
    store.saveState(state) catch |err| return reportLoopStoreError(err, id, stderr);
    if (options.status == .blocked and state.status == .active) {
        try stdout.print("Blocker recorded (strike {d}/3); loop remains active—attempt an alternative path.\n", .{state.blocked_strikes});
    } else {
        try stdout.print("Loop {s} status: {s}\n", .{ id, @tagName(state.status) });
    }
    return .ok;
}

fn verifyLoop(store: *const loop_store.Store, id: []const u8, options: loop_options.VerifyOptions, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !ExitCode {
    var parsed = store.loadState(id) catch |err| return reportLoopStoreError(err, id, stderr);
    defer parsed.deinit();
    var state = parsed.value;
    if (state.status != .verifying) {
        try stderr.print("Cannot verify loop {s} from status {s}\n", .{ id, @tagName(state.status) });
        return .failure;
    }
    if (options.passed) {
        state.status = .complete;
    } else {
        state.status = .active;
        state.blocked_strikes = 0;
        state.last_verifier_feedback = options.reason;
    }
    state.updated_at_ms = @intCast(@max(0, std.Io.Clock.real.now(store.io).toMilliseconds()));
    store.saveState(state) catch |err| return reportLoopStoreError(err, id, stderr);
    try stdout.print("Loop {s} verification: {s}\n", .{ id, if (options.passed) "passed" else "rejected" });
    return .ok;
}

fn writeLoopList(store: *const loop_store.Store, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !ExitCode {
    const ids = store.listLoopIds() catch |err| return reportLoopStoreError(err, "<loops>", stderr);
    defer {
        for (ids) |id| store.allocator.free(id);
        store.allocator.free(ids);
    }
    try stdout.writeAll("ID\tSTATUS\tBACKEND\tTURNS\tTOKENS\tOBJECTIVE\n");
    for (ids) |id| {
        var parsed = store.loadState(id) catch |err| return reportLoopStoreError(err, id, stderr);
        defer parsed.deinit();
        const objective = try oneLineObjective(store.allocator, parsed.value.objective);
        defer store.allocator.free(objective);
        const clipped = truncateUtf8(objective, 40);
        try stdout.print("{s}\t{s}\t{s}\t{d}\t{d}\t{s}{s}\n", .{
            id,
            @tagName(parsed.value.status),
            @tagName(parsed.value.backend),
            parsed.value.turns_completed,
            parsed.value.tokens_used,
            clipped,
            if (clipped.len < objective.len) "…" else "",
        });
    }
    return .ok;
}

fn writeLoopShow(store: *const loop_store.Store, id: []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !ExitCode {
    var parsed = store.loadState(id) catch |err| return reportLoopStoreError(err, id, stderr);
    defer parsed.deinit();
    const state = parsed.value;
    try stdout.print("ID: {s}\nStatus: {s}\nBackend: {s}\nVerifier: {s}\nVerification: {s}\nTurns: {d}\nTokens: {d}\nBudgets: max-turns=", .{
        state.id,                                                               @tagName(state.status),                              @tagName(state.backend),
        if (state.verifier_backend) |backend| @tagName(backend) else "default", if (state.verify_enabled) "enabled" else "disabled", state.turns_completed,
        state.tokens_used,
    });
    if (state.max_turns) |value| try stdout.print("{d}", .{value}) else try stdout.writeAll("unlimited");
    try stdout.writeAll(", token-budget=");
    if (state.token_budget) |value| try stdout.print("{d}", .{value}) else try stdout.writeAll("unlimited");
    try stdout.writeAll(", timeout=");
    if (state.timeout_seconds) |value| try stdout.print("{d}s", .{value}) else try stdout.writeAll("unlimited");
    try stdout.print("\nSandbox: {s}", .{if (state.sandbox) |policy| @tagName(policy) else "adapter default"});
    try stdout.print("\nExecutable: {s}", .{state.backend_bin orelse @tagName(state.backend)});
    try stdout.print("\nModel: {s}\nYolo: {s}\nSession: {s}\nWorking directory: {s}\nObjective:\n{s}\n", .{
        state.model orelse "backend default",
        if (state.yolo) "enabled" else "disabled",
        state.worker_session_id orelse "none",
        state.cwd,
        state.objective,
    });
    try stdout.print("Reasoning effort: {s}\n", .{state.reasoning_effort orelse "backend default"});
    const verifier_execution = loop_runtime.roleSettings(state, .verifier);
    try stdout.print("Verifier model: {s}\nVerifier executable: {s}\nVerifier reasoning effort: {s}\n", .{
        verifier_execution.model orelse "backend default",
        verifier_execution.backend_bin orelse @tagName(verifier_execution.backend),
        verifier_execution.reasoning_effort orelse "backend default",
    });
    const history = store.readRecentTurnLog(id, 5) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return reportLoopStoreError(err, id, stderr),
    };
    defer store.allocator.free(history);
    try stdout.writeAll("Recent turns:\n");
    if (history.len == 0) try stdout.writeAll("  (none)\n") else try stdout.print("{s}", .{history});
    return .ok;
}

fn reportLoopStoreError(err: anyerror, id: []const u8, stderr: *std.Io.Writer) !ExitCode {
    if (err == error.FileNotFound or err == error.NotDir) {
        try stderr.print("Loop not found: {s}\n", .{id});
    } else {
        try stderr.print("Loop store error for {s}: {s}\n", .{ id, @errorName(err) });
    }
    return .failure;
}

fn truncateUtf8(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    var end = max_bytes;
    while (end > 0 and end < text.len and (text[end] & 0xc0) == 0x80) : (end -= 1) {}
    return text[0..end];
}

fn oneLineObjective(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (words.next()) |word| {
        if (result.items.len > 0) try result.append(allocator, ' ');
        try result.appendSlice(allocator, word);
    }
    return result.toOwnedSlice(allocator);
}

fn writeLoopUsage(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("Usage: matcha loop [options] | resume | list | show | update | verify | help\n");
}

pub fn writeLoopHelp(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(
        \\matcha loop
        \\
        \\Usage:
        \\  matcha loop [options] <prompt> [options]
        \\  matcha loop --prompt-file <path> [options]
        \\  matcha loop config
        \\  matcha loop resume [<id>|--last] [--objective <new objective>] [execution overrides]
        \\  matcha loop list
        \\  matcha loop show [<id>]
        \\  matcha loop update [<id>] --status <complete|blocked> [--summary <text>]
        \\  matcha loop verify [<id>] --pass | --fail --reason <text>
        \\
        \\Loop callbacks accept MATCHA_LOOP_ID when <id> is omitted.
        \\The default backend is codex; use -b to select droid or agy.
        \\Use matcha loop config to set default harness, model, and turn limit.
        \\Run options --model, -b, --max-turns, and --unlimited override saved defaults.
        \\Prompt may come from positional text, --prompt-file, or piped stdin. Options work before or after text.
        \\Options include --yolo, --verifier, --no-verify, --token-budget, --timeout, --quiet, and --json.
        \\Verifier overrides: --verifier-model <model>, --verifier-bin <executable>,
        \\  repeatable --verifier-arg=<argument>. Empty model/bin selects native default.
        \\Arguments after -- belong only to the worker in new loops.
        \\Execution overrides on run and resume: --env KEY=VALUE, --env-file <path>,
        \\  --path-prepend <dir>, --backend-bin <executable>, --verifier-bin <executable>,
        \\  --model <id>, --verifier-model <id>, --reasoning-effort <level>,
        \\  --verifier-reasoning-effort <level>, --sandbox <policy>, --yolo, --log-dir <dir>.
        \\Env values are literal; env files use KEY=VALUE lines and are flattened into snapshots.
        \\Configured PATH prefixes follow Matcha's callback binary directory.
        \\Resume uses saved settings plus explicit overrides; --config and new prompts are run-only.
        \\--sandbox <workspace-write|danger-full-access|backend-default> selects isolation.
        \\Codex supports the first two; backend-default resets to native policy for all backends.
        \\Read-only cannot support loop callbacks. Sandbox never implies --yolo approval bypass.
        \\--sandbox and --yolo conflict in one layer; either replaces an inherited policy.
        \\--backend-bin <executable> selects one executable; arguments belong after --.
        \\--config <path> selects a project config instead of launch-directory .matcha.json.
        \\Precedence: CLI > project > user defaults. Prompt: explicit > pipe > configured file.
        \\Prompt files and stdin are limited to 1 MiB; file paths in configs are source-relative.
        \\Use matcha loop --help for this help.
        \\
    );
}

fn isHelpCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "help") or
        std.mem.eql(u8, command, "--help") or
        std.mem.eql(u8, command, "-h");
}

fn isVersionCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "version") or
        std.mem.eql(u8, command, "--version") or
        std.mem.eql(u8, command, "-V");
}

pub fn writeVersion(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("matcha {s}\n", .{version});
}

fn runRenderCommand(
    target: render_html.RenderTarget,
    io: std.Io,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !ExitCode {
    if (args.len > 0 and isHelpCommand(args[0])) {
        switch (target) {
            .plan => try writePlanHelp(stdout),
            .map => try writeMapHelp(stdout),
        }
        return .ok;
    }

    var options: RenderOptions = switch (parseRenderOptions(target, args)) {
        .ok => |parsed| parsed,
        .err => |cli_error| {
            try writeCliError(stderr, cli_error);
            return .usage;
        },
    };

    switch (normalizeRenderPaths(std.heap.page_allocator, &options)) {
        .ok => {},
        .err => |cli_error| {
            try writeCliError(stderr, cli_error);
            return .usage;
        },
    }
    defer std.heap.page_allocator.free(options.input);
    defer std.heap.page_allocator.free(options.output);

    if (!prepareOutputDirectory(io, stderr, options.output)) {
        return .failure;
    }

    var document = json_input.readJsonDocument(io, std.heap.page_allocator, options.input) catch |err| {
        const cli_error: errors.CliError = switch (err) {
            json_input.DocumentParseError.CannotReadInput => .{ .cannot_read_input = options.input },
            json_input.DocumentParseError.InvalidJson => .{ .invalid_json = options.input },
            json_input.DocumentParseError.OutOfMemory => return error.OutOfMemory,
        };
        try writeCliError(stderr, cli_error);
        return .failure;
    };
    defer document.deinit();

    switch (target) {
        .plan => try render_html.writePlanHtml(io, options.output, document.title, document.raw),
        .map => try render_html.writeMapHtml(io, options.output, document.title, document.raw),
    }
    try stdout.print("Wrote {s}\n", .{options.output});
    return .ok;
}

fn runPlanReadCommand(
    io: std.Io,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !ExitCode {
    var document = plan_read.parsePlanReadInput(io, std.heap.page_allocator, args) catch |err| {
        switch (err) {
            plan_read.PlanReadError.missing_path, plan_read.PlanReadError.extra_arguments, plan_read.PlanReadError.invalid_argument => {
                try stderr.print("Usage: matcha plan read <path>\n", .{});
                return .usage;
            },
            plan_read.PlanReadError.missing_home => {
                try stderr.print("Cannot expand input path: HOME and USERPROFILE are not set\n", .{});
                return .failure;
            },
            plan_read.PlanReadError.cannot_read_input => {
                const input_path = if (args.len > 0) args[0] else "<path>";
                try stderr.print("Cannot read {s}\n", .{input_path});
                return .failure;
            },
            plan_read.PlanReadError.unsupported_input => {
                try stderr.print("Unsupported input: {s}\n", .{if (args.len > 0) args[0] else "<path>"});
                return .failure;
            },
            plan_read.PlanReadError.invalid_json => {
                try stderr.print("Invalid JSON in {s}\n", .{if (args.len > 0) args[0] else "<path>"});
                return .failure;
            },
            plan_read.PlanReadError.out_of_memory => {
                return .failure;
            },
        }
    };
    defer document.deinit();

    const markdown = render_markdown.renderPlanMarkdown(std.heap.page_allocator, document.data) catch |err| switch (err) {
        render_markdown.RenderError.NotAnObject => {
            try stderr.print("Invalid plan document: expected JSON object\n", .{});
            return .failure;
        },
        render_markdown.RenderError.OutOfMemory => {
            return .failure;
        },
    };
    defer std.heap.page_allocator.free(markdown);

    try stdout.print("{s}\n", .{markdown});
    return .ok;
}

fn runServeCommand(
    io: std.Io,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !ExitCode {
    if (args.len > 0 and isHelpCommand(args[0])) {
        try writeServeHelp(stdout);
        return .ok;
    }

    var stdin_acquirer = stdinDirectoryAcquirer(io);
    return runServeCommandAcquired(io, args, stdout, stderr, stdin_acquirer.acquirer(), realServerRunner());
}

/// Injectable server runner so command dispatch can be exercised without
/// starting a real blocking listener.
pub const ServerRunner = struct {
    context: *anyopaque,
    runFn: *const fn (context: *anyopaque, io: std.Io, options: serve_options.ServeOptions, stdout: *std.Io.Writer, stderr: *std.Io.Writer) anyerror!ExitCode,

    pub fn run(
        self: ServerRunner,
        io: std.Io,
        options: serve_options.ServeOptions,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) anyerror!ExitCode {
        return self.runFn(self.context, io, options, stdout, stderr);
    }
};

var real_runner_storage: RealServerRunner = .{};

fn realServerRunner() ServerRunner {
    return .{
        .context = @ptrCast(&real_runner_storage),
        .runFn = RealServerRunner.run,
    };
}

const RealServerRunner = struct {
    fn run(
        context: *anyopaque,
        io: std.Io,
        options: serve_options.ServeOptions,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) anyerror!ExitCode {
        _ = context;
        return serve.run(io, options, stdout, stderr);
    }
};

fn runServeCommandAcquired(
    io: std.Io,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    acquirer: DirectoryAcquirer,
    runner: ServerRunner,
) !ExitCode {
    if (args.len > 0 and isHelpCommand(args[0])) {
        try writeServeHelp(stdout);
        return .ok;
    }

    var options: serve_options.ServeOptions = switch (serve_options.parseServeOptions(std.heap.page_allocator, args)) {
        .ok => |parsed| parsed,
        .err => |cli_error| {
            try writeCliError(stderr, cli_error);
            try writeServeUsage(stderr);
            return .usage;
        },
    };
    _ = &options;
    var owns_directory = options.directory_set;
    defer if (owns_directory) std.heap.page_allocator.free(options.directory);

    if (!options.directory_set) {
        switch (acquireServeDirectory(acquirer, stdout, stderr)) {
            .ok => |entered| {
                options.directory = entered;
                owns_directory = true;
            },
            .err => |cli_error| {
                try writeCliError(stderr, cli_error);
                try writeServeUsage(stderr);
                return .usage;
            },
        }
    }

    if (!serve_options.validateDirectory(io, options.directory)) {
        try writeCliError(stderr, .{ .not_a_directory = options.directory });
        return .usage;
    }

    return runner.run(io, options, stdout, stderr);
}

/// Outcome of acquiring a serve directory interactively or from arguments.
pub const DirectoryAcquireResult = union(enum) {
    ok: []const u8,
    err: errors.CliError,
};

/// Injectable source for interactive directory acquisition.
pub const DirectoryAcquirer = struct {
    context: *anyopaque,
    isInteractiveFn: *const fn (context: *anyopaque) bool,
    readLineFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator) DirectoryAcquireResult,

    pub fn isInteractive(self: DirectoryAcquirer) bool {
        return self.isInteractiveFn(self.context);
    }

    pub fn readLine(self: DirectoryAcquirer, allocator: std.mem.Allocator) DirectoryAcquireResult {
        return self.readLineFn(self.context, allocator);
    }
};

/// Acquire a serve directory when one was not supplied on the command line.
///
/// Non-interactive invocations return a `missing_value` error immediately so the
/// caller can print usage and exit without blocking on stdin. Interactive
/// invocations prompt once, accept home-relative paths, and treat an empty
/// response or end-of-file as a clear failure rather than re-prompting.
pub fn acquireServeDirectory(
    acquirer: DirectoryAcquirer,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) DirectoryAcquireResult {
    _ = stderr;
    if (!acquirer.isInteractive()) {
        return .{ .err = .{ .missing_value = "directory" } };
    }

    stdout.writeAll("Directory to serve: ") catch return .{ .err = .{ .path_error = "" } };

    const entered = acquirer.readLine(std.heap.page_allocator);
    return switch (entered) {
        .ok => |line| blk: {
            defer std.heap.page_allocator.free(line);
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) break :blk .{ .err = .{ .missing_value = "directory" } };
            const expanded = path.expandHomePath(std.heap.page_allocator, trimmed) catch |err| switch (err) {
                error.MissingHome => break :blk .{ .err = .{ .missing_home = "entered directory" } },
                else => break :blk .{ .err = .{ .path_error = "entered directory" } },
            };
            if (expanded.ptr == trimmed.ptr) {
                const owned = std.heap.page_allocator.dupe(u8, expanded) catch break :blk .{ .err = .{ .path_error = "entered directory" } };
                break :blk .{ .ok = owned };
            }
            break :blk .{ .ok = expanded };
        },
        .err => |e| .{ .err = e },
    };
}

const StdinDirectoryAcquirer = struct {
    io: std.Io,
    reader: *std.Io.File.Reader,

    fn isInteractiveImpl(context: *anyopaque) bool {
        const self: *StdinDirectoryAcquirer = @ptrCast(@alignCast(context));
        return std.Io.File.stdin().isTty(self.io) catch false;
    }

    fn readLineImpl(context: *anyopaque, allocator: std.mem.Allocator) DirectoryAcquireResult {
        const self: *StdinDirectoryAcquirer = @ptrCast(@alignCast(context));
        const line = self.reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return .{ .err = .{ .missing_value = "directory" } },
            else => return .{ .err = .{ .path_error = "" } },
        };
        return .{ .ok = allocator.dupe(u8, line) catch return .{ .err = .{ .path_error = "" } } };
    }

    fn acquirer(self: *StdinDirectoryAcquirer) DirectoryAcquirer {
        return .{
            .context = @ptrCast(self),
            .isInteractiveFn = StdinDirectoryAcquirer.isInteractiveImpl,
            .readLineFn = StdinDirectoryAcquirer.readLineImpl,
        };
    }
};

var stdin_reader_storage: std.Io.File.Reader = undefined;

fn stdinDirectoryAcquirer(io: std.Io) StdinDirectoryAcquirer {
    stdin_reader_storage = std.Io.File.Reader.init(.stdin(), io, &stdin_line_buffer);
    return .{
        .io = io,
        .reader = &stdin_reader_storage,
    };
}

var stdin_line_buffer: [4096]u8 = undefined;

fn writeServeUsage(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("Usage: matcha serve <directory> [--host <host>] [--port <port>] [--interval <seconds>]\n");
}

pub fn writeServeHelp(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(
        \\matcha serve
        \\
        \\Usage:
        \\  matcha serve <directory> [options]
        \\
        \\Serve generated Matcha HTML plans and maps from <directory> as a
        \\read-only catalog and artifact browser.
        \\
        \\Arguments:
        \\  <directory>          Root directory to scan for Matcha artifacts
        \\
        \\Behavior:
        \\  - Only regular .html files are considered.
        \\  - Markers determine artifact type:
        \\      plan:  <script id="plan-data" ...>
        \\      map:   <script id="map-data" ...>
        \\    Non-marked HTML is ignored.
        \\  - Scanning is recursive and groups entries by:
        \\      embedded project metadata, then first path segment, then Ungrouped.
        \\  - Artifact routes are read-only:
        \\      /artifacts/<url-encoded-relative-path>
        \\  - Directory is scanned at startup and every 5 seconds by default.
        \\Options:
        \\  --host <host>        Bind address (default: 0.0.0.0)
        \\  --port <port>        Bind port (default: 27004)
        \\  --interval <seconds> Catalog refresh interval in seconds (default: 5)
        \\
        \\The --host, --port, and --interval options accept either a space-separated
        \\value (--port 27004) or an equals-style value (--port=27004).
        \\
        \\By default, --host 0.0.0.0 binds every interface, so peers on your local
        \\network can browse artifacts. Use --host 127.0.0.1 for loopback-only access.
        \\
        \\If no <directory> is provided and this is an interactive terminal, the
        \\command prompts for one path. In non-interactive mode it exits immediately
        \\with usage.
        \\
        \\Examples:
        \\  matcha serve ./artifacts
        \\  matcha serve ~/artifacts --host 127.0.0.1 --port 8080 --interval 10
        \\
    );
}

fn normalizeRenderPaths(allocator: std.mem.Allocator, options: *RenderOptions) RenderOptionsResult {
    const expanded_input = path.expandHomePath(allocator, options.input) catch |err| {
        switch (err) {
            error.MissingHome => return RenderOptionsResult{ .err = .{ .missing_home = options.input } },
            else => return RenderOptionsResult{ .err = .{ .path_error = options.input } },
        }
    };
    const normalized_input = if (expanded_input.ptr == options.input.ptr)
        allocator.dupe(u8, expanded_input) catch return RenderOptionsResult{ .err = .{ .path_error = options.input } }
    else
        expanded_input;
    const expanded_output = path.expandHomePath(allocator, options.output) catch |err| {
        allocator.free(normalized_input);
        switch (err) {
            error.MissingHome => return RenderOptionsResult{ .err = .{ .missing_home = options.output } },
            else => return RenderOptionsResult{ .err = .{ .path_error = options.output } },
        }
    };
    const normalized_output = if (expanded_output.ptr == options.output.ptr)
        allocator.dupe(u8, expanded_output) catch {
            allocator.free(normalized_input);
            return RenderOptionsResult{ .err = .{ .path_error = options.output } };
        }
    else
        expanded_output;
    options.input = normalized_input;
    options.output = normalized_output;
    return RenderOptionsResult{ .ok = options.* };
}

test "render path normalization returns owned copies for ordinary paths" {
    const allocator = std.testing.allocator;
    var options: RenderOptions = .{ .target = .plan, .input = "relative/input.json", .output = "dist/output.html" };
    const normalized = normalizeRenderPaths(allocator, &options);
    try std.testing.expect(normalized == .ok);
    defer allocator.free(options.input);
    defer allocator.free(options.output);
    try std.testing.expectEqualStrings("relative/input.json", options.input);
    try std.testing.expectEqualStrings("dist/output.html", options.output);
}

fn prepareOutputDirectory(io: std.Io, stderr: *std.Io.Writer, output: []const u8) bool {
    const output_parent = path.parentDirectory(output) orelse return true;
    std.Io.Dir.cwd().createDirPath(io, output_parent) catch |err| {
        stderr.print("Cannot create output directory {s}: {s}\n", .{
            output_parent,
            @errorName(err),
        }) catch return false;
        return false;
    };
    return true;
}

pub fn parseRenderOptions(target: render_html.RenderTarget, args: []const []const u8) RenderOptionsResult {
    var options: RenderOptions = .{
        .target = target,
        .input = render_html.defaultInput(target),
        .output = render_html.defaultOutput(target),
    };

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-i")) {
            index += 1;
            options.input = readFlagValue(args, index) orelse return .{ .err = .{ .missing_value = arg } };
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--input=")) {
            options.input = arg["--input=".len..];
            continue;
        }

        if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            index += 1;
            options.output = readFlagValue(args, index) orelse return .{ .err = .{ .missing_value = arg } };
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--output=")) {
            options.output = arg["--output=".len..];
            continue;
        }

        return .{ .err = .{ .unknown_option = arg } };
    }

    return .{ .ok = options };
}

fn readFlagValue(args: []const []const u8, index: usize) ?[]const u8 {
    if (index >= args.len or std.mem.startsWith(u8, args[index], "-")) {
        return null;
    }

    return args[index];
}

fn writeCliError(writer: *std.Io.Writer, cli_error: errors.CliError) std.Io.Writer.Error!void {
    return errors.writeCliError(writer, cli_error);
}

pub fn writeHelp(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(
        \\matcha
        \\
        \\Usage:
        \\  matcha [command] [options]
        \\
        \\Commands:
        \\  help, --help, -h  Show this help text
        \\  usage            Explain CLI usage and input formats for LLMs
        \\  version          Show the CLI version
        \\  plan             Render a plan based on the given input
        \\  map              Render a map based on the given input
        \\  serve            Serve generated Matcha HTML artifacts on the local network
        \\  loop             Run or inspect a persistent autonomous loop
        \\
        \\Plan commands:
        \\  matcha plan --help              Show detailed help for plan rendering
        \\  matcha plan read <path>         Print a matcha plan as Markdown to stdout
        \\
        \\Map commands:
        \\  matcha map --help               Show detailed help for map rendering
        \\
        \\Serve commands:
        \\  matcha serve --help             Show detailed help for serve mode
        \\
        \\Loop commands:
        \\  matcha loop --help              Show loop commands and options
        \\
        \\Options:
        \\  -i, --input <path>    JSON file to render
        \\  -o, --output <path>   HTML file to write
        \\
    );
}

pub fn writePlanHelp(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(
        \\matcha plan
        \\
        \\Usage:
        \\  matcha plan [options]
        \\  matcha plan read <path>
        \\
        \\Render a plan JSON file to a self-contained HTML page. Without --input, it reads
        \\sample_plan.json; without --output, it writes dist/plan.html.
        \\
        \\Options:
        \\  -i, --input <path>    Plan JSON file to render
        \\  -o, --output <path>   HTML file to write
        \\
        \\Read subcommand:
        \\  matcha plan read <path>  Print a matcha plan as Markdown to stdout. The path can be
        \\                        raw plan JSON or a matcha-generated plan HTML file.
        \\
        \\Plan input format:
        \\
    );
    try writeIndentedTrimmed(writer, assets.llm_output_format.contents);
}

pub fn writeMapHelp(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(
        \\matcha map
        \\
        \\Usage:
        \\  matcha map [options]
        \\
        \\Render a UML-style map JSON file to a self-contained HTML page. Without --input,
        \\it reads sample_map.json; without --output, it writes dist/map.html.
        \\
        \\Options:
        \\  -i, --input <path>    Map JSON file to render
        \\  -o, --output <path>   HTML file to write
        \\
        \\Map input format:
        \\
    );
    try writeIndentedTrimmed(writer, assets.llm_uml_output_format.contents);
}

pub fn writeUsageGuide(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(
        \\matcha usage for LLMs
        \\
        \\Purpose:
        \\  matcha turns structured JSON into self-contained HTML artifacts.
        \\  Use "matcha plan" for implementation plans.
        \\  Use "matcha map" for semantic UML-style diagrams.
        \\
        \\Commands:
        \\  matcha plan --input path/to/plan.json --output path/to/plan.html
        \\  matcha map --input path/to/map.json --output path/to/map.html
        \\  matcha plan read path/to/plan.json          Print Markdown to stdout
        \\  matcha plan read path/to/plan.html          Read a matcha-generated plan HTML back as Markdown
        \\  matcha loop --help                         Run or inspect a persistent loop
        \\  matcha loop resume --last                  Resume the most recent paused loop
        \\
        \\Defaults:
        \\  matcha plan reads sample_plan.json and writes dist/plan.html.
        \\  matcha map reads sample_map.json and writes dist/map.html.
        \\
        \\Path rules:
        \\  --input is a JSON file matching the selected command format.
        \\  --output is the HTML file to write.
        \\  Parent directories for --output are created automatically.
        \\  Quoted home paths such as "~/clankers/file.html" are expanded by matcha.
        \\
        \\LLM workflow:
        \\  1. Decide whether the requested artifact is a plan or map.
        \\  2. Produce exactly one valid JSON object matching the format below.
        \\  3. Save that JSON to a file.
        \\  4. Run the matching matcha command with --input and --output.
        \\  5. Do not put Markdown fences or commentary in the JSON input file.
        \\  6. To read an existing plan as Markdown, run `matcha plan read <path>`.
        \\  7. No --output option exists for plan read; redirect stdout (`> plan.md`) or pipe it.
        \\  8. Resume a paused autonomous loop with `matcha loop resume [<id>|--last]`; use
        \\     `--objective "..."` to replace its objective when resuming.
        \\
        \\Reading plans as Markdown:
        \\  Use `matcha plan read` when you need to consume an existing plan without parsing JSON or
        \\  scraping rendered HTML. The command is deterministic, offline, and writes to stdout only.
        \\
        \\Plan input format:
        \\
    );
    try writeIndentedTrimmed(writer, assets.llm_output_format.contents);
    try writer.writeAll(
        \\
        \\Map input format:
        \\
    );
    try writeIndentedTrimmed(writer, assets.llm_uml_output_format.contents);
    try writer.writeByte('\n');
}

fn writeIndentedTrimmed(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |line| {
        try writer.writeAll("  ");
        try writer.writeAll(std.mem.trim(u8, line, "\r"));
        try writer.writeByte('\n');
    }
}

test "command module imports all CLI responsibility modules" {
    try std.testing.expectEqualStrings("plan.js", assets.plan_js.name);
    try std.testing.expect(path.isHomeRelative("~/sample_plan.json"));
    try std.testing.expectEqualStrings("dist/plan.html", render_html.defaultOutput(.plan));
    try std.testing.expectEqualStrings("# ", render_markdown.headingPrefix(.plan));
}

test "root help aliases print help" {
    const aliases = [_][]const u8{ "help", "--help", "-h" };

    for (aliases) |alias| {
        var stdout_buffer: [2048]u8 = undefined;
        var stderr_buffer: [128]u8 = undefined;
        var stdout: std.Io.Writer = .fixed(&stdout_buffer);
        var stderr: std.Io.Writer = .fixed(&stderr_buffer);
        const code = try runArgs(&.{alias}, std.testing.io, &stdout, &stderr);
        const output = stdout_buffer[0..stdout.end];

        try std.testing.expectEqual(ExitCode.ok, code);
        try std.testing.expect(std.mem.indexOf(u8, output, "matcha plan --help") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "matcha map --help") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "help, --help, -h") != null);
        try std.testing.expectEqual(@as(usize, 0), stderr.end);
    }
}

test "root version aliases print current CLI version" {
    const aliases = [_][]const u8{ "version", "--version", "-V" };

    for (aliases) |alias| {
        var stdout_buffer: [64]u8 = undefined;
        var stderr_buffer: [128]u8 = undefined;
        var stdout: std.Io.Writer = .fixed(&stdout_buffer);
        var stderr: std.Io.Writer = .fixed(&stderr_buffer);
        const code = try runArgs(&.{alias}, std.testing.io, &stdout, &stderr);

        try std.testing.expectEqual(ExitCode.ok, code);
        try std.testing.expectEqualStrings("matcha 0.1.0\n", stdout_buffer[0..stdout.end]);
        try std.testing.expectEqual(@as(usize, 0), stderr.end);
    }
}

test "usage includes embedded plan and map format instructions" {
    var stdout_buffer: [32768]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const code = try runArgs(&.{"usage"}, std.testing.io, &stdout, &stderr);
    const output = stdout_buffer[0..stdout.end];

    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, output, "matcha usage for LLMs") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Plan input format:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  Plan input format") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Map input format:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  Map input format") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.end);
}

test "render command defaults match current CLI" {
    const plan_options = expectRenderOptions(parseRenderOptions(.plan, &.{}));
    try std.testing.expectEqual(render_html.RenderTarget.plan, plan_options.target);
    try std.testing.expectEqualStrings("sample_plan.json", plan_options.input);
    try std.testing.expectEqualStrings("dist/plan.html", plan_options.output);

    const map_options = expectRenderOptions(parseRenderOptions(.map, &.{}));
    try std.testing.expectEqual(render_html.RenderTarget.map, map_options.target);
    try std.testing.expectEqualStrings("sample_map.json", map_options.input);
    try std.testing.expectEqualStrings("dist/map.html", map_options.output);
}

test "render command parses separated input and output flags" {
    const plan_options = expectRenderOptions(parseRenderOptions(.plan, &.{
        "-i",
        "plans/input.json",
        "-o",
        "dist/custom-plan.html",
    }));
    try std.testing.expectEqualStrings("plans/input.json", plan_options.input);
    try std.testing.expectEqualStrings("dist/custom-plan.html", plan_options.output);

    const map_options = expectRenderOptions(parseRenderOptions(.map, &.{
        "--input",
        "maps/input.json",
        "--output",
        "dist/custom-map.html",
    }));
    try std.testing.expectEqualStrings("maps/input.json", map_options.input);
    try std.testing.expectEqualStrings("dist/custom-map.html", map_options.output);
}

test "render command parses equals-style input and output flags" {
    const plan_options = expectRenderOptions(parseRenderOptions(.plan, &.{
        "--input=plans/input.json",
        "--output=dist/custom-plan.html",
    }));
    try std.testing.expectEqualStrings("plans/input.json", plan_options.input);
    try std.testing.expectEqualStrings("dist/custom-plan.html", plan_options.output);

    const map_options = expectRenderOptions(parseRenderOptions(.map, &.{
        "--output=dist/custom-map.html",
        "--input=maps/input.json",
    }));
    try std.testing.expectEqualStrings("maps/input.json", map_options.input);
    try std.testing.expectEqualStrings("dist/custom-map.html", map_options.output);
}

test "plan read accepts raw JSON input path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const input_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/plan.json", .{tmp.dir.path.?});
    defer std.testing.allocator.free(input_path);
    try tmp.dir.writeFile("plan.json", "{\"title\":\"Raw JSON Plan\",\"schemaVersion\":1}\n");

    var stdout_buffer: [256]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "plan", "read", input_path }, std.testing.io, &stdout, &stderr);
    const output = stdout_buffer[0..stdout.end];

    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, output, "# Raw JSON Plan") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "- **Schema Version:** 1") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.end);
}

test "plan read accepts generated plan HTML input path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const input_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/plan.html", .{tmp.dir.path.?});
    defer std.testing.allocator.free(input_path);
    try tmp.dir.writeFile("plan.html",
        \\<html><body>
        \\  <script type="application/json" id="plan-data">
        \\    {"title":"HTML Fixture","schemaVersion":1}
        \\  </script>
        \\</body></html>
    );

    var stdout_buffer: [256]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "plan", "read", input_path }, std.testing.io, &stdout, &stderr);
    const output = stdout_buffer[0..stdout.end];

    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, output, "# HTML Fixture") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.end);
}

test "plan read rejects missing and extra arguments with usage" {
    var stdout_buffer: [256]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const missing_arg_code = try runArgs(&.{ "plan", "read" }, std.testing.io, &stdout, &stderr);
    try std.testing.expectEqual(ExitCode.usage, missing_arg_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Usage: matcha plan read <path>") != null);

    stdout.end = 0;
    stderr.end = 0;
    const extra_arg_code = try runArgs(
        &.{ "plan", "read", "one.json", "two.json" },
        std.testing.io,
        &stdout,
        &stderr,
    );
    try std.testing.expectEqual(ExitCode.usage, extra_arg_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Usage: matcha plan read <path>") != null);
    try std.testing.expectEqual(@as(usize, 0), stdout.end);
}

test "plan read rejects unsupported non-json non-plan-html input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const input_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/unsupported.txt", .{tmp.dir.path.?});
    defer std.testing.allocator.free(input_path);
    try tmp.dir.writeFile("unsupported.txt", "this is not json or plan html");

    var stdout_buffer: [256]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "plan", "read", input_path }, std.testing.io, &stdout, &stderr);
    try std.testing.expectEqual(ExitCode.failure, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Unsupported input:") != null);
    try std.testing.expectEqual(@as(usize, 0), stdout.end);
}

test "plan read rejects flag-like arguments" {
    var stdout_buffer: [256]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "plan", "read", "--output", "ignored.md" }, std.testing.io, &stdout, &stderr);

    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Usage: matcha plan read <path>") != null);
    try std.testing.expectEqual(@as(usize, 0), stdout.end);
}

test "plan read fixture output is stable and stdout-only" {
    const allocator = std.testing.allocator;

    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);

    const sample_plan_path = try std.fmt.allocPrint(allocator, "{s}/sample_plan.json", .{cwd});
    defer allocator.free(sample_plan_path);

    const expected_path = try std.fmt.allocPrint(allocator, "{s}/testdata/sample_plan.md", .{cwd});
    defer allocator.free(expected_path);

    const expected_markdown = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        expected_path,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(expected_markdown);

    const plan_contents = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        sample_plan_path,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(plan_contents);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const input_path = try std.fmt.allocPrint(allocator, "{s}/sample_plan.json", .{tmp.dir.path.?});
    defer allocator.free(input_path);
    try tmp.dir.writeFile("sample_plan.json", plan_contents);

    var start_count: usize = 0;
    var initial_entry_iterator = tmp.dir.iterate();
    while (try initial_entry_iterator.next()) |_| {
        start_count += 1;
    }

    var stdout_buffer: [131072]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    try std.testing.expect(expected_markdown.len < stdout_buffer.len);

    const first_code = try runArgs(&.{ "plan", "read", input_path }, std.testing.io, &stdout, &stderr);
    const first_output = stdout_buffer[0..stdout.end];
    try std.testing.expectEqual(ExitCode.ok, first_code);
    try std.testing.expectEqual(@as(usize, 0), stderr.end);
    try std.testing.expectEqualStrings(expected_markdown, first_output);

    stdout.end = 0;
    stderr.end = 0;
    const second_code = try runArgs(&.{ "plan", "read", input_path }, std.testing.io, &stdout, &stderr);
    const second_output = stdout_buffer[0..stdout.end];
    try std.testing.expectEqual(ExitCode.ok, second_code);
    try std.testing.expectEqualStrings(first_output, second_output);
    try std.testing.expectEqual(@as(usize, 0), stderr.end);

    var final_entry_iterator = tmp.dir.iterate();
    var final_count: usize = 0;
    while (try final_entry_iterator.next()) |_| {
        final_count += 1;
    }

    try std.testing.expectEqual(start_count, final_count);
}

test "render command rejects missing flag values" {
    try expectMissingValue("-i", parseRenderOptions(.plan, &.{"-i"}));
    try expectMissingValue("--input", parseRenderOptions(.plan, &.{ "--input", "--output", "dist/plan.html" }));
    try expectMissingValue("-o", parseRenderOptions(.map, &.{"-o"}));
    try expectMissingValue("--output", parseRenderOptions(.map, &.{ "--output", "-i", "sample_map.json" }));
}

test "render command rejects unknown options" {
    try expectUnknownOption("--theme", parseRenderOptions(.plan, &.{ "--theme", "dracula" }));
    try expectUnknownOption("sample_map.json", parseRenderOptions(.map, &.{"sample_map.json"}));
}

test "runArgs reports render option errors to stderr" {
    var stdout_buffer: [2048]u8 = undefined;
    var stderr_buffer: [256]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "plan", "--wat" }, std.testing.io, &stdout, &stderr);

    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expectEqual(@as(usize, 0), stdout.end);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Unknown option: --wat") != null);
}

test "render command help aliases print subcommand help" {
    var stdout_buffer: [32768]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const plan_code = try runArgs(&.{ "plan", "--help" }, std.testing.io, &stdout, &stderr);
    const plan_output = stdout_buffer[0..stdout.end];
    try std.testing.expectEqual(ExitCode.ok, plan_code);
    try std.testing.expect(std.mem.indexOf(u8, plan_output, "matcha plan") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_output, "Plan input format:") != null);

    stdout = .fixed(&stdout_buffer);
    stderr = .fixed(&stderr_buffer);
    const map_code = try runArgs(&.{ "map", "-h" }, std.testing.io, &stdout, &stderr);
    const map_output = stdout_buffer[0..stdout.end];
    try std.testing.expectEqual(ExitCode.ok, map_code);
    try std.testing.expect(std.mem.indexOf(u8, map_output, "matcha map") != null);
    try std.testing.expect(std.mem.indexOf(u8, map_output, "Map input format:") != null);
}

test "unknown root command prints help then error and exits non-zero" {
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [256]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{"nope"}, std.testing.io, &stdout, &stderr);
    const output = stdout_buffer[0..stdout.end];
    const error_output = stderr_buffer[0..stderr.end];

    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, output, "Commands:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "usage            Explain CLI usage and input formats for LLMs") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_output, "Unknown command: nope") != null);
}

test "runArgs validates input file JSON before writing output" {
    const work_dir = "/tmp/matcha-zig-e2s4";
    const valid_input = "/tmp/matcha-zig-e2s4/valid.json";
    const output_path = "/tmp/matcha-zig-e2s4/nested/plan.html";

    defer std.fs.cwd().deleteTree(work_dir) catch {};
    std.fs.cwd().deleteTree(work_dir) catch {};
    try std.fs.cwd().makePath(work_dir);

    var input_file = try std.fs.cwd().createFile(valid_input, .{ .truncate = true });
    defer input_file.close();
    try input_file.writeAll("{}");

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "plan", "--input", valid_input, "--output", output_path }, std.testing.io, &stdout, &stderr);

    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer[0..stdout.end], "Wrote " ++ output_path) != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.end);
}

test "runArgs reports missing input files as user-facing errors" {
    const missing_input = "/tmp/matcha-zig-e2s4/missing.json";
    const output_path = "/tmp/matcha-zig-e2s4/output.html";

    defer std.fs.cwd().deleteTree("/tmp/matcha-zig-e2s4") catch {};
    try std.fs.cwd().makePath("/tmp/matcha-zig-e2s4");

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [256]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "plan", "--input", missing_input, "--output", output_path }, std.testing.io, &stdout, &stderr);

    try std.testing.expectEqual(ExitCode.failure, code);
    try std.testing.expectEqual(@as(usize, 0), stdout.end);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Cannot read ") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], missing_input) != null);
}

test "runArgs reports invalid JSON as user-facing errors" {
    const work_dir = "/tmp/matcha-zig-e2s4";
    const invalid_input = "/tmp/matcha-zig-e2s4/invalid.json";
    const output_path = "/tmp/matcha-zig-e2s4/invalid-output.html";

    defer std.fs.cwd().deleteTree(work_dir) catch {};
    std.fs.cwd().deleteTree(work_dir) catch {};
    try std.fs.cwd().makePath(work_dir);

    var input_file = try std.fs.cwd().createFile(invalid_input, .{ .truncate = true });
    defer input_file.close();
    try input_file.writeAll("not json");

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [256]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "plan", "--input", invalid_input, "--output", output_path }, std.testing.io, &stdout, &stderr);

    try std.testing.expectEqual(ExitCode.failure, code);
    try std.testing.expectEqual(@as(usize, 0), stdout.end);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Invalid JSON in ") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], invalid_input) != null);
}

test "runArgs uses default plan path contract in temporary working directory" {
    const allocator = std.testing.allocator;

    const original_cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(original_cwd);

    const sample_plan_path = try std.fmt.allocPrint(allocator, "{s}/sample_plan.json", .{original_cwd});
    defer allocator.free(sample_plan_path);
    const sample_plan = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        sample_plan_path,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(sample_plan);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}", .{tmp.dir.path.?});
    defer allocator.free(tmp_path);

    try tmp.dir.writeFile("sample_plan.json", sample_plan);
    defer _ = std.Io.chdir(original_cwd) catch {};
    try std.Io.chdir(tmp_path);

    var stdout_buffer: [256]u8 = undefined;
    var stderr_buffer: [64]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{"plan"}, std.testing.io, &stdout, &stderr);
    const output = stdout_buffer[0..stdout.end];

    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, output, "Wrote dist/plan.html") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.end);

    var file = try std.Io.Dir.cwd().openFile("dist/plan.html", .{});
    defer file.close();
    const html = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "<title>SwiftUI Calculator Implementation Plan</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"plan-data\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "window.PLAN_DATA") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "matcha-plan-theme") != null);
}

test "runArgs uses default map path contract in temporary working directory" {
    const allocator = std.testing.allocator;

    const original_cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(original_cwd);

    const sample_map_path = try std.fmt.allocPrint(allocator, "{s}/sample_map.json", .{original_cwd});
    defer allocator.free(sample_map_path);
    const sample_map = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        sample_map_path,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(sample_map);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}", .{tmp.dir.path.?});
    defer allocator.free(tmp_path);

    try tmp.dir.writeFile("sample_map.json", sample_map);
    defer _ = std.Io.chdir(original_cwd) catch {};
    try std.Io.chdir(tmp_path);

    var stdout_buffer: [256]u8 = undefined;
    var stderr_buffer: [64]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{"map"}, std.testing.io, &stdout, &stderr);
    const output = stdout_buffer[0..stdout.end];

    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, output, "Wrote dist/map.html") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.end);

    var file = try std.Io.Dir.cwd().openFile("dist/map.html", .{});
    defer file.close();
    const html = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "<title>Matcha Plan And Map Renderer</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"map-data\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "window.MAP_DATA") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "matcha-map-theme") != null);
}

test "runArgs explicit input/output paths for plan and map write expected HTML markers" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = tmp.dir.path.?;
    const plan_input = try std.fmt.allocPrint(allocator, "{s}/plan-input.json", .{root});
    defer allocator.free(plan_input);
    const plan_output = try std.fmt.allocPrint(allocator, "{s}/nested/plan-output.html", .{root});
    defer allocator.free(plan_output);
    const map_input = try std.fmt.allocPrint(allocator, "{s}/map-input.json", .{root});
    defer allocator.free(map_input);
    const map_output = try std.fmt.allocPrint(allocator, "{s}/nested/map-output.html", .{root});
    defer allocator.free(map_output);

    const plan_input_file = try tmp.dir.createFile("plan-input.json", .{ .truncate = true });
    defer plan_input_file.close();
    try plan_input_file.writeAll("{\"title\":\"Plan Explicit Fixture\",\"schemaVersion\":1}\n");

    const map_input_file = try tmp.dir.createFile("map-input.json", .{ .truncate = true });
    defer map_input_file.close();
    try map_input_file.writeAll("{\"title\":\"Map Explicit Fixture\",\"schemaVersion\":1,\"diagramKind\":\"mixed\"}\n");

    var stdout_buffer: [256]u8 = undefined;
    var stderr_buffer: [64]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const plan_code = try runArgs(&.{ "plan", "--input", plan_input, "--output", plan_output }, std.testing.io, &stdout, &stderr);
    try std.testing.expectEqual(ExitCode.ok, plan_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer[0..stdout.end], "Wrote " ++ plan_output) != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.end);

    const plan_file = try std.Io.Dir.openFileAbsolute(std.testing.io, plan_output, .{});
    defer plan_file.close();
    const plan_html = try plan_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(plan_html);
    try std.testing.expect(std.mem.indexOf(u8, plan_html, "<title>Plan Explicit Fixture</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_html, "id=\"sidebar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_html, "window.PLAN_DATA") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_html, "matcha-plan-theme") != null);

    stdout = .fixed(&stdout_buffer);
    stderr = .fixed(&stderr_buffer);
    const map_code = try runArgs(&.{ "map", "--input", map_input, "--output", map_output }, std.testing.io, &stdout, &stderr);
    try std.testing.expectEqual(ExitCode.ok, map_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer[0..stdout.end], "Wrote " ++ map_output) != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.end);

    const map_file = try std.Io.Dir.openFileAbsolute(std.testing.io, map_output, .{});
    defer map_file.close();
    const map_html = try map_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(map_html);
    try std.testing.expect(std.mem.indexOf(u8, map_html, "<title>Map Explicit Fixture</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, map_html, "id=\"map-root\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, map_html, "window.MAP_DATA") != null);
    try std.testing.expect(std.mem.indexOf(u8, map_html, "matcha-map-theme") != null);
}

test "serve --help prints subcommand help" {
    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "serve", "--help" }, std.testing.io, &stdout, &stderr);
    const output = stdout_buffer[0..stdout.end];
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, output, "matcha serve") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Usage:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--host") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--port") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--interval") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "27004") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "default: 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "plan-data") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "map-data") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "0.0.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "127.0.0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "read-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Ungrouped") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.end);
}

test "serve -h alias prints subcommand help" {
    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "serve", "-h" }, std.testing.io, &stdout, &stderr);
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer[0..stdout.end], "matcha serve") != null);
}

test "serve accepts a real directory and reports validation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var runner = FakeServerRunner{};
    const code = try runServeCommandAcquired(
        std.testing.io,
        &.{tmp.dir.path.?},
        &stdout,
        &stderr,
        nonInteractiveAcquirer().acquirer(),
        runner.runner(),
    );
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(runner.last_options != null);
    try std.testing.expect(runner.last_options.?.directory_set);
    try std.testing.expectEqualStrings(tmp.dir.path.?, runner.last_options.?.directory);
}

test "serve rejects a missing directory with usage in non-interactive mode" {
    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var harness = nonInteractiveAcquirer();
    var runner = FakeServerRunner{};
    const code = try runServeCommandAcquired(
        std.testing.io,
        &.{},
        &stdout,
        &stderr,
        harness.acquirer(),
        runner.runner(),
    );
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Missing value for directory") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Usage: matcha serve") != null);
    try std.testing.expectEqual(@as(usize, 0), stdout.end);
    try std.testing.expect(!harness.readLineCalled());
    try std.testing.expect(runner.last_options == null);
}

test "serve non-interactive missing directory returns usage without reading input" {
    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var harness = nonInteractiveAcquirer();
    harness.line = "should-not-be-read";
    var runner = FakeServerRunner{};
    const code = try runServeCommandAcquired(
        std.testing.io,
        &.{},
        &stdout,
        &stderr,
        harness.acquirer(),
        runner.runner(),
    );
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(!harness.readLineCalled());
}

test "serve prompts interactively and accepts a valid entered directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var harness = interactiveAcquirer(std.testing.allocator);
    defer harness.deinit(std.testing.allocator);
    harness.line = try std.testing.allocator.dupe(u8, tmp.dir.path.?);
    defer std.testing.allocator.free(harness.line.?);

    var runner = FakeServerRunner{};
    const code = try runServeCommandAcquired(
        std.testing.io,
        &.{},
        &stdout,
        &stderr,
        harness.acquirer(),
        runner.runner(),
    );
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(harness.readLineCalled());
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer[0..stdout.end], "Directory to serve:") != null);
    try std.testing.expect(runner.last_options != null);
    try std.testing.expectEqualStrings(tmp.dir.path.?, runner.last_options.?.directory);
}

test "serve prompted path supports home expansion" {
    const allocator = std.testing.allocator;
    const home = path.expandHomePath(allocator, "~") catch return;
    defer allocator.free(home);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var harness = interactiveAcquirer(allocator);
    defer harness.deinit(allocator);

    const tmp_name = try std.fs.path.basename(allocator, tmp.dir.path.?);
    defer allocator.free(tmp_name);
    const prompted_path = try std.fmt.allocPrint(allocator, "~/{s}", .{tmp_name});
    defer allocator.free(prompted_path);

    // Make a matching path under home so validation passes.
    const home_target = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, tmp_name });
    defer allocator.free(home_target);
    std.fs.cwd().deletePath(home_target) catch {};
    defer std.fs.cwd().deletePath(home_target) catch {};
    try std.fs.cwd().makePath(home_target);
    defer std.fs.cwd().deletePath(home_target) catch {};

    harness.line = try allocator.dupe(u8, prompted_path);
    defer allocator.free(harness.line.?);

    var runner = FakeServerRunner{};
    const code = try runServeCommandAcquired(
        std.testing.io,
        &.{},
        &stdout,
        &stderr,
        harness.acquirer(),
        runner.runner(),
    );
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(runner.last_options != null);
    try std.testing.expectEqualStrings(home_target, runner.last_options.?.directory);
}

test "serve interactive empty response fails without re-prompting" {
    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var harness = interactiveAcquirer(std.testing.allocator);
    defer harness.deinit(std.testing.allocator);
    harness.line = try std.testing.allocator.dupe(u8, "");
    defer std.testing.allocator.free(harness.line.?);

    var runner = FakeServerRunner{};
    const code = try runServeCommandAcquired(
        std.testing.io,
        &.{},
        &stdout,
        &stderr,
        harness.acquirer(),
        runner.runner(),
    );
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(harness.readLineCalled());
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Missing value for directory") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Usage: matcha serve") != null);
}

test "serve interactive end-of-file fails without re-prompting" {
    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var harness = interactiveAcquirer(std.testing.allocator);
    defer harness.deinit(std.testing.allocator);
    harness.end_of_file = true;

    var runner = FakeServerRunner{};
    const code = try runServeCommandAcquired(
        std.testing.io,
        &.{},
        &stdout,
        &stderr,
        harness.acquirer(),
        runner.runner(),
    );
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(harness.readLineCalled());
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Missing value for directory") != null);
}

test "serve interactive invalid entered directory fails with not a directory" {
    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var harness = interactiveAcquirer(std.testing.allocator);
    defer harness.deinit(std.testing.allocator);
    harness.line = try std.testing.allocator.dupe(u8, "/tmp/matcha-interactive-nonexistent-xyz");
    defer std.testing.allocator.free(harness.line.?);

    var runner = FakeServerRunner{};
    const code = try runServeCommandAcquired(
        std.testing.io,
        &.{},
        &stdout,
        &stderr,
        harness.acquirer(),
        runner.runner(),
    );
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Not a directory:") != null);
}

test "serve explicit directory never triggers a prompt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var harness = nonInteractiveAcquirer();
    harness.line = "should-not-be-read";
    var runner = FakeServerRunner{};
    const code = try runServeCommandAcquired(
        std.testing.io,
        &.{tmp.dir.path.?},
        &stdout,
        &stderr,
        harness.acquirer(),
        runner.runner(),
    );
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(!harness.readLineCalled());
    try std.testing.expectEqual(@as(usize, 0), stdout.end);
    try std.testing.expect(runner.last_options != null);
    try std.testing.expectEqualStrings(tmp.dir.path.?, runner.last_options.?.directory);
}

const FakeDirectoryAcquirer = struct {
    interactive: bool,
    line: ?[]const u8 = null,
    end_of_file: bool = false,
    read_line_called: bool = false,

    fn isInteractiveImpl(context: *anyopaque) bool {
        const self: *FakeDirectoryAcquirer = @ptrCast(@alignCast(context));
        return self.interactive;
    }

    fn readLineImpl(context: *anyopaque, allocator: std.mem.Allocator) DirectoryAcquireResult {
        const self: *FakeDirectoryAcquirer = @ptrCast(@alignCast(context));
        self.read_line_called = true;
        if (self.end_of_file) return .{ .err = .{ .missing_value = "directory" } };
        if (self.line) |line| return .{ .ok = allocator.dupe(u8, line) catch return .{ .err = .{ .path_error = "" } } };
        return .{ .err = .{ .missing_value = "directory" } };
    }

    fn acquirer(self: *FakeDirectoryAcquirer) DirectoryAcquirer {
        return .{
            .context = @ptrCast(self),
            .isInteractiveFn = FakeDirectoryAcquirer.isInteractiveImpl,
            .readLineFn = FakeDirectoryAcquirer.readLineImpl,
        };
    }

    fn readLineCalled(self: *FakeDirectoryAcquirer) bool {
        return self.read_line_called;
    }

    fn deinit(self: *FakeDirectoryAcquirer, allocator: std.mem.Allocator) void {
        if (self.line) |line| allocator.free(line);
    }
};

fn nonInteractiveAcquirer() FakeDirectoryAcquirer {
    return .{ .interactive = false };
}

fn interactiveAcquirer(_: std.mem.Allocator) FakeDirectoryAcquirer {
    return .{ .interactive = true };
}

const FakeServerRunner = struct {
    last_options: ?serve_options.ServeOptions = null,
    last_stdout: ?*std.Io.Writer = null,
    last_stderr: ?*std.Io.Writer = null,
    exit_code: ExitCode = .ok,

    fn run(
        context: *anyopaque,
        io: std.Io,
        options: serve_options.ServeOptions,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) anyerror!ExitCode {
        _ = io;
        const self: *FakeServerRunner = @ptrCast(@alignCast(context));
        self.last_options = options;
        self.last_stdout = stdout;
        self.last_stderr = stderr;
        return self.exit_code;
    }

    fn runner(self: *FakeServerRunner) ServerRunner {
        return .{
            .context = @ptrCast(self),
            .runFn = FakeServerRunner.run,
        };
    }
};

test "serve rejects an invalid directory with not a directory error" {
    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "serve", "/tmp/matcha-nonexistent-xyz-12345" }, std.testing.io, &stdout, &stderr);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Not a directory:") != null);
    try std.testing.expectEqual(@as(usize, 0), stdout.end);
}

test "serve rejects extra positional arguments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "serve", tmp.dir.path.?, "/extra" }, std.testing.io, &stdout, &stderr);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Unexpected argument:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Usage: matcha serve") != null);
}

test "serve rejects invalid port" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "serve", "--port", "abc", tmp.dir.path.? }, std.testing.io, &stdout, &stderr);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Invalid port:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Usage: matcha serve") != null);
}

test "serve rejects invalid interval" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "serve", "--interval", "0", tmp.dir.path.? }, std.testing.io, &stdout, &stderr);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Invalid interval:") != null);
}

test "serve rejects unknown flag" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "serve", "--theme", "dracula", tmp.dir.path.? }, std.testing.io, &stdout, &stderr);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Unknown option:") != null);
}

test "serve rejects a file path as directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/not-a-dir.txt", .{tmp.dir.path.?});
    defer std.testing.allocator.free(file_path);
    try tmp.dir.writeFile("not-a-dir.txt", "data");

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "serve", file_path }, std.testing.io, &stdout, &stderr);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Not a directory:") != null);
}

test "root help mentions serve command" {
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{"help"}, std.testing.io, &stdout, &stderr);
    const output = stdout_buffer[0..stdout.end];
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, output, "serve            Serve generated Matcha HTML artifacts on the local network") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "matcha serve --help") != null);
}

test "existing plan and map behavior unchanged by serve addition" {
    {
        var stdout_buffer: [64]u8 = undefined;
        var stderr_buffer: [128]u8 = undefined;
        var stdout: std.Io.Writer = .fixed(&stdout_buffer);
        var stderr: std.Io.Writer = .fixed(&stderr_buffer);
        const code = try runArgs(&.{"version"}, std.testing.io, &stdout, &stderr);
        try std.testing.expectEqual(ExitCode.ok, code);
        try std.testing.expectEqualStrings("matcha 0.1.0\n", stdout_buffer[0..stdout.end]);
    }

    {
        var stdout_buffer: [4096]u8 = undefined;
        var stderr_buffer: [128]u8 = undefined;
        var stdout: std.Io.Writer = .fixed(&stdout_buffer);
        var stderr: std.Io.Writer = .fixed(&stderr_buffer);
        const code = try runArgs(&.{ "plan", "--wat" }, std.testing.io, &stdout, &stderr);
        try std.testing.expectEqual(ExitCode.usage, code);
        try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Unknown option: --wat") != null);
    }

    {
        var stdout_buffer: [4096]u8 = undefined;
        var stderr_buffer: [128]u8 = undefined;
        var stdout: std.Io.Writer = .fixed(&stdout_buffer);
        var stderr: std.Io.Writer = .fixed(&stderr_buffer);
        const code = try runArgs(&.{ "map", "--wat" }, std.testing.io, &stdout, &stderr);
        try std.testing.expectEqual(ExitCode.usage, code);
        try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Unknown option: --wat") != null);
    }

    {
        var stdout_buffer: [4096]u8 = undefined;
        var stderr_buffer: [128]u8 = undefined;
        var stdout: std.Io.Writer = .fixed(&stdout_buffer);
        var stderr: std.Io.Writer = .fixed(&stderr_buffer);
        const code = try runArgs(&.{"nope"}, std.testing.io, &stdout, &stderr);
        try std.testing.expectEqual(ExitCode.usage, code);
        try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Unknown command: nope") != null);
    }
}

fn expectRenderOptions(result: RenderOptionsResult) RenderOptions {
    return switch (result) {
        .ok => |options| options,
        .err => unreachable,
    };
}

fn expectMissingValue(expected_flag: []const u8, result: RenderOptionsResult) !void {
    switch (result) {
        .ok => return error.ExpectedError,
        .err => |cli_error| switch (cli_error) {
            .missing_value => |flag| {
                try std.testing.expectEqualStrings(expected_flag, flag);
                return;
            },
            .unknown_option => return error.WrongError,
            else => return error.WrongError,
        },
    }
}

fn expectUnknownOption(expected_option: []const u8, result: RenderOptionsResult) !void {
    switch (result) {
        .ok => return error.ExpectedError,
        .err => |cli_error| switch (cli_error) {
            .missing_value => return error.WrongError,
            .unknown_option => |option| {
                try std.testing.expectEqualStrings(expected_option, option);
                return;
            },
            else => return error.WrongError,
        },
    }
}

test "loop CLI help, list, show, update, and verify callbacks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(store_root);
    var store = try loop_store.Store.init(std.testing.allocator, std.testing.io, store_root);
    defer store.deinit();
    const state: loop_store.LoopState = .{
        .id = "6722c1a0-0001",
        .backend = .codex,
        .cwd = "/work",
        .objective = "repair the edge case",
        .started_at_ms = 100,
        .updated_at_ms = 100,
        .turns_completed = 2,
        .tokens_used = 99,
        .blocked_strikes = 0,
    };
    try store.createLoop(state);
    try store.appendTurnLog(state.id, .{ .turn = 1, .role = .worker, .backend = .codex, .outcome = .continued, .summary = "implemented core" });

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    var code = try runArgsWithLoopStoreRoot(&.{ "loop", "--help" }, std.testing.io, &stdout, &stderr, store_root);
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer[0..stdout.end], "matcha loop") != null);

    stdout = .fixed(&stdout_buffer);
    stderr = .fixed(&stderr_buffer);
    code = try runArgsWithLoopStoreRoot(&.{ "loop", "list" }, std.testing.io, &stdout, &stderr, store_root);
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer[0..stdout.end], "repair the edge case") != null);

    stdout = .fixed(&stdout_buffer);
    stderr = .fixed(&stderr_buffer);
    code = try runArgsWithLoopStoreRoot(&.{ "loop", "show", state.id }, std.testing.io, &stdout, &stderr, store_root);
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer[0..stdout.end], "implemented core") != null);

    var strike: u8 = 1;
    while (strike <= 3) : (strike += 1) {
        stdout = .fixed(&stdout_buffer);
        stderr = .fixed(&stderr_buffer);
        code = try runArgsWithLoopStoreRoot(&.{ "loop", "update", state.id, "--status", "blocked", "--summary", "blocked step" }, std.testing.io, &stdout, &stderr, store_root);
        try std.testing.expectEqual(ExitCode.ok, code);
        var loaded = try store.loadState(state.id);
        defer loaded.deinit();
        try std.testing.expectEqual(if (strike == 3) loop_store.LoopStatus.blocked else loop_store.LoopStatus.active, loaded.value.status);
        try std.testing.expectEqual(strike, loaded.value.blocked_strikes);
    }

    var loaded = try store.loadState(state.id);
    defer loaded.deinit();
    var active = loaded.value;
    active.status = .active;
    active.verify_enabled = true;
    active.blocked_strikes = 2;
    try store.saveState(active);
    stdout = .fixed(&stdout_buffer);
    stderr = .fixed(&stderr_buffer);
    code = try runArgsWithLoopStoreRoot(&.{ "loop", "update", state.id, "--status", "complete", "--summary", "ready" }, std.testing.io, &stdout, &stderr, store_root);
    try std.testing.expectEqual(ExitCode.ok, code);
    var verifying = try store.loadState(state.id);
    defer verifying.deinit();
    try std.testing.expectEqual(loop_store.LoopStatus.verifying, verifying.value.status);
    try std.testing.expectEqualStrings("ready", verifying.value.completion_summary.?);

    stdout = .fixed(&stdout_buffer);
    stderr = .fixed(&stderr_buffer);
    code = try runArgsWithLoopStoreRoot(&.{ "loop", "verify", state.id, "--fail", "--reason", "missing edge test" }, std.testing.io, &stdout, &stderr, store_root);
    try std.testing.expectEqual(ExitCode.ok, code);
    var rejected = try store.loadState(state.id);
    defer rejected.deinit();
    try std.testing.expectEqual(loop_store.LoopStatus.active, rejected.value.status);
    try std.testing.expectEqual(@as(u8, 0), rejected.value.blocked_strikes);
    try std.testing.expectEqualStrings("missing edge test", rejected.value.last_verifier_feedback.?);
}

const ResumeCliFake = struct {
    allocator: std.mem.Allocator,
    store: *loop_store.Store,
    prompt: ?[]u8 = null,
    resumed: bool = false,

    fn runner(self: *ResumeCliFake) loop_backend.BackendRunner {
        return .{ .context = @ptrCast(self), .runTurnFn = ResumeCliFake.runTurn };
    }

    fn deinit(self: *ResumeCliFake) void {
        if (self.prompt) |value| self.allocator.free(value);
    }

    fn runTurn(context: *anyopaque, request: loop_backend.TurnRequest) anyerror!loop_backend.TurnExecutionResult {
        const self: *ResumeCliFake = @ptrCast(@alignCast(context));
        self.prompt = try self.allocator.dupe(u8, request.prompt);
        for (request.argv) |arg| if (std.mem.eql(u8, arg, "resume")) {
            self.resumed = true;
        };
        var loaded = try self.store.loadState(request.loop_id);
        defer loaded.deinit();
        var state = loaded.value;
        state.status = .complete;
        state.completion_summary = "CLI fake completed.";
        try std.testing.expectEqualStrings(state.backend_bin orelse @tagName(state.backend), request.argv[0]);
        try self.store.saveState(state);
        return .{
            .allocator = self.allocator,
            .exit_code = 0,
            .session_id = try self.allocator.dupe(u8, "saved-session"),
            .tokens_used = 1,
            .last_assistant_text = try self.allocator.dupe(u8, "complete"),
            .stderr_tail = try self.allocator.dupe(u8, ""),
            .was_interrupted = false,
        };
    }
};

test "loop resume CLI accepts last and injects the changed objective" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store_root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(store_root);
    var store = try loop_store.Store.init(allocator, std.testing.io, store_root);
    defer store.deinit();
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const state: loop_store.LoopState = .{
        .id = "6722c1a0-0002",
        .status = .paused,
        .backend = .codex,
        .cwd = cwd,
        .objective = "old objective",
        .worker_session_id = "saved-session",
        .started_at_ms = 100,
        .updated_at_ms = 100,
        .blocked_strikes = 2,
    };
    try store.createLoop(state);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var fake = ResumeCliFake{ .allocator = allocator, .store = &store };
    defer fake.deinit();
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const code = try runArgsRuntime(&.{ "loop", "resume", "--last", "--objective", "updated objective" }, std.testing.io, &stdout, &stderr, store_root, &env, fake.runner());
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(fake.resumed);
    try std.testing.expect(std.mem.indexOf(u8, fake.prompt.?, "updated objective") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.prompt.?, "objective was updated by the user") != null);
    var after = try store.loadState(state.id);
    defer after.deinit();
    try std.testing.expectEqualStrings("updated objective", after.value.objective);
    try std.testing.expectEqual(@as(u8, 0), after.value.blocked_strikes);
    try std.testing.expect(!after.value.objective_update_pending);
}

test "loop resume CLI accepts an explicit loop id" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store_root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(store_root);
    var store = try loop_store.Store.init(allocator, std.testing.io, store_root);
    defer store.deinit();
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const state: loop_store.LoopState = .{
        .id = "6722c1a0-0003",
        .status = .paused,
        .backend = .codex,
        .cwd = cwd,
        .objective = "resume by ID",
        .worker_session_id = "saved-session",
        .started_at_ms = 100,
        .updated_at_ms = 100,
    };
    try store.createLoop(state);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var fake = ResumeCliFake{ .allocator = allocator, .store = &store };
    defer fake.deinit();
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const code = try runArgsRuntime(&.{ "loop", "resume", state.id }, std.testing.io, &stdout, &stderr, store_root, &env, fake.runner());
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(fake.resumed);
}

test "loop resume CLI reports a missing ID without an internal error" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store_root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(store_root);
    var stdout_buffer: [2048]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const code = try runArgsWithLoopStoreRoot(&.{ "loop", "resume", "6722c1a0-ffff" }, std.testing.io, &stdout, &stderr, store_root);
    try std.testing.expectEqual(ExitCode.failure, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Loop not found:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Internal error:") == null);
}

test "configured CLI captures winning prompt and callback writes preserve resolved settings" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const project = try std.fmt.allocPrint(a, "{s}/selected.json", .{root});
    defer a.free(project);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "selected.json", .data = "{\"schema_version\":1,\"loop\":{\"backend\":\"droid\",\"backend_bin\":\"./custom worker\",\"model\":\"captured-model\",\"max_turns\":7,\"prompt_file\":\"task.md\",\"verify_enabled\":false,\"yolo\":true,\"output_mode\":\"quiet\"}}" });
    const file_prompt = "  first page\n\nsecond page\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "task.md", .data = file_prompt });
    var store = try loop_store.Store.init(a, std.testing.io, root);
    defer store.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const cwd = try std.process.currentPathAlloc(std.testing.io, a);
    defer a.free(cwd);
    const cases = [_]struct { args: []const []const u8, stdin: []const u8, expected: []const u8 }{
        .{ .args = &.{}, .stdin = " \n", .expected = file_prompt },
        .{ .args = &.{ "explicit", "--max-turns", "5" }, .stdin = "ignored pipe", .expected = "explicit" },
        .{ .args = &.{}, .stdin = "  pipe\nmultiline\n", .expected = "  pipe\nmultiline\n" },
    };
    for (cases, 0..) |case, index| {
        if (index == 1) try tmp.dir.deleteFile(std.testing.io, "task.md");
        var fake = ResumeCliFake{ .allocator = a, .store = &store };
        defer fake.deinit();
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        var err: std.Io.Writer.Allocating = .init(a);
        defer err.deinit();
        const code = try runLoopCommandWithInputs(std.testing.io, case.args, &out.writer, &err.writer, root, &env, fake.runner(), .{ .project_path = project, .stdin_bytes = case.stdin });
        try std.testing.expectEqual(ExitCode.ok, code);
        const id = (try store.resolveLatestLoopId()).?;
        defer a.free(id);
        // IDs contain randomness; locate the state for this objective rather than relying on sort order.
        const ids = try store.listLoopIds();
        defer {
            for (ids) |v| a.free(v);
            a.free(ids);
        }
        var found = false;
        for (ids) |candidate| {
            var state = try store.loadState(candidate);
            defer state.deinit();
            if (!std.mem.eql(u8, state.value.objective, case.expected)) continue;
            found = true;
            try std.testing.expectEqualStrings(cwd, state.value.cwd);
            try std.testing.expectEqualStrings("captured-model", state.value.model.?);
            const expected_binary = try loop_config.resolveExecutablePath(a, std.testing.io, root, "./custom worker");
            defer a.free(expected_binary);
            try std.testing.expectEqualStrings(expected_binary, state.value.backend_bin.?);
            try std.testing.expectEqual(loop_options.BackendKind.droid, state.value.backend);
            try std.testing.expectEqual(@as(u32, if (index == 1) 5 else 7), state.value.max_turns.?);
            try std.testing.expectEqual(ExitCode.ok, try updateLoop(&store, candidate, .{ .status = .complete, .summary = "callback" }, &out.writer, &err.writer));
            var after = try store.loadState(candidate);
            defer after.deinit();
            try std.testing.expectEqualStrings(case.expected, after.value.objective);
            try std.testing.expectEqualStrings(state.value.model.?, after.value.model.?);
            try std.testing.expectEqual(state.value.output_mode, after.value.output_mode);
            try std.testing.expectEqual(state.value.max_turns, after.value.max_turns);
        }
        try std.testing.expect(found);
    }
}

const TwoRoleCliFake = struct {
    store: *loop_store.Store,
    calls: usize = 0,
    fn runner(self: *TwoRoleCliFake) loop_backend.BackendRunner {
        return .{ .context = self, .runTurnFn = runTurn };
    }
    fn runTurn(context: *anyopaque, request: loop_backend.TurnRequest) !loop_backend.TurnExecutionResult {
        const self: *TwoRoleCliFake = @ptrCast(@alignCast(context));
        var state = try self.store.loadState(request.loop_id);
        defer state.deinit();
        const verifying = self.calls == 1;
        try std.testing.expectEqualStrings(request.loop_id, request.environ_map.get("MATCHA_LOOP_ID").?);
        try std.testing.expectEqualStrings("shared", request.environ_map.get("FIXTURE_ENV").?);
        try std.testing.expectEqualStrings(if (verifying) "/verifier executable" else "/worker executable", request.argv[0]);
        var found_worker = false;
        var found_verifier = false;
        var found_model = false;
        for (request.argv) |arg| {
            if (std.mem.eql(u8, arg, "--worker-only")) found_worker = true;
            if (std.mem.eql(u8, arg, "--verifier-only")) found_verifier = true;
            if (std.mem.eql(u8, arg, if (verifying) "verifier-model" else "worker-model")) found_model = true;
        }
        try std.testing.expect(found_model);
        try std.testing.expectEqual(!verifying, found_worker);
        try std.testing.expectEqual(verifying, found_verifier);
        if (verifying) {
            try std.testing.expect(request.on_session_id == null);
            try std.testing.expectEqual(ExitCode.ok, try verifyLoop(self.store, request.loop_id, .{ .passed = true }, request.diagnostics.?, request.diagnostics.?));
        } else {
            try std.testing.expectEqual(ExitCode.ok, try updateLoop(self.store, request.loop_id, .{ .status = .complete, .summary = "ready" }, request.diagnostics.?, request.diagnostics.?));
        }
        self.calls += 1;
        return .{ .allocator = self.store.allocator, .exit_code = 0, .session_id = try self.store.allocator.dupe(u8, "worker-session"), .tokens_used = 1, .last_assistant_text = null, .stderr_tail = try self.store.allocator.dupe(u8, ""), .was_interrupted = false };
    }
};

test "CLI verifier overrides reach separate roles and survive callback writes" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const project = try std.fs.path.join(a, &.{ root, "absent.json" });
    defer a.free(project);
    var store = try loop_store.Store.init(a, std.testing.io, root);
    defer store.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("FIXTURE_ENV", "shared");
    var fake = TwoRoleCliFake{ .store = &store };
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var diagnostic: std.Io.Writer.Allocating = .init(a);
    defer diagnostic.deinit();
    const result = try runLoopCommandWithInputs(std.testing.io, &.{ "task", "--backend-bin=/worker executable", "--model=worker-model", "--verifier=agy", "--verifier-model=verifier-model", "--verifier-bin=/verifier executable", "--verifier-arg=--verifier-only", "--json", "--", "--worker-only" }, &output.writer, &diagnostic.writer, root, &env, fake.runner(), .{ .project_path = project });
    try std.testing.expectEqual(ExitCode.ok, result);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    const id = (try store.resolveLatestLoopId()).?;
    defer a.free(id);
    var state = try store.loadState(id);
    defer state.deinit();
    try std.testing.expectEqualStrings("verifier-model", state.value.verifier_options.model.?);
    try std.testing.expect(state.value.verifier_options.model_explicit);
    try std.testing.expectEqualStrings("/verifier executable", state.value.verifier_options.backend_bin.?);
    try std.testing.expectEqualStrings("--verifier-only", state.value.verifier_options.args[0]);
    try std.testing.expectEqualStrings("--worker-only", state.value.extra_args[0]);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "verifier-model") != null);
}

test "unavailable verifier fails real preflight before any worker or durable loop" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    const project = try std.fs.path.join(a, &.{ root, "absent.json" });
    defer a.free(project);
    const worker = try loop_config.resolveExecutablePath(a, io, root, "./worker");
    defer a.free(worker);
    const file = try tmp.dir.createFile(io, "worker", .{ .permissions = .executable_file });
    try file.writeStreamingAll(io, "#!/bin/sh\nexit 88\n");
    file.close(io);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var diagnostic: std.Io.Writer.Allocating = .init(a);
    defer diagnostic.deinit();
    const result = try runLoopCommandWithInputs(io, &.{ "task", "--backend-bin", worker, "--verifier-bin=/no/such/verifier" }, &output.writer, &diagnostic.writer, root, &env, null, .{ .project_path = project });
    try std.testing.expectEqual(ExitCode.failure, result);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.written(), "/no/such/verifier") != null);
    var store = try loop_store.Store.init(a, io, root);
    defer store.deinit();
    const ids = try store.listLoopIds();
    defer {
        for (ids) |id| a.free(id);
        a.free(ids);
    }
    try std.testing.expectEqual(@as(usize, 0), ids.len);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "turn.started") == null);
}

test "CLI resume sandbox replaces saved yolo without reloading config" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    var store = try loop_store.Store.init(a, io, root);
    defer store.deinit();
    const cwd = try std.process.currentPathAlloc(io, a);
    defer a.free(cwd);
    const initial: loop_store.LoopState = .{ .id = "sandbox-0001", .status = .paused, .backend = .codex, .yolo = true, .verify_enabled = false, .cwd = cwd, .objective = "saved objective", .started_at_ms = 1, .updated_at_ms = 1 };
    try store.createLoop(initial);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var fake = ResumeCliFake{ .allocator = a, .store = &store };
    defer fake.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var diagnostic: std.Io.Writer.Allocating = .init(a);
    defer diagnostic.deinit();
    const code = try runArgsRuntime(&.{ "loop", "resume", initial.id, "--sandbox=workspace-write" }, io, &out.writer, &diagnostic.writer, root, &env, fake.runner());
    try std.testing.expectEqual(ExitCode.ok, code);
    var saved = try store.loadState(initial.id);
    defer saved.deinit();
    try std.testing.expect(!saved.value.yolo);
    try std.testing.expectEqual(loop_options.SandboxPolicy.@"workspace-write", saved.value.sandbox.?);
    try std.testing.expectEqualStrings(initial.objective, saved.value.objective);
}

test "CLI rejects unsupported enabled verifier policy before worker but permits disabled verifier" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]bool{ false, true }) |disabled| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        defer a.free(root);
        const project = try std.fs.path.join(a, &.{ root, "project.json" });
        defer a.free(project);
        try tmp.dir.writeFile(io, .{ .sub_path = "project.json", .data = "{\"schema_version\":1,\"loop\":{\"verifier\":{\"backend\":\"agy\"}}}" });
        var store = try loop_store.Store.init(a, io, root);
        defer store.deinit();
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        var fake = ResumeCliFake{ .allocator = a, .store = &store };
        defer fake.deinit();
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        var diagnostic: std.Io.Writer.Allocating = .init(a);
        defer diagnostic.deinit();
        const args: []const []const u8 = if (disabled) &.{ "task", "--sandbox=workspace-write", "--no-verify" } else &.{ "task", "--sandbox=workspace-write" };
        const code = try runLoopCommandWithInputs(io, args, &out.writer, &diagnostic.writer, root, &env, fake.runner(), .{ .project_path = project });
        try std.testing.expectEqual(if (disabled) ExitCode.ok else ExitCode.failure, code);
        try std.testing.expectEqual(disabled, fake.prompt != null);
        if (!disabled) {
            const ids = try store.listLoopIds();
            defer {
                for (ids) |id| a.free(id);
                a.free(ids);
            }
            try std.testing.expectEqual(@as(usize, 0), ids.len);
            try std.testing.expect(std.mem.indexOf(u8, diagnostic.written(), "agy") != null);
        }
    }
}
