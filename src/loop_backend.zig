const std = @import("std");
const options = @import("loop_options.zig");
const stream = @import("loop_stream.zig");
const loop_log = @import("loop_log.zig");

pub const BackendKind = options.BackendKind;

pub const OnSessionId = *const fn (?*anyopaque, []const u8) anyerror!void;
pub const OnChildId = *const fn (?*anyopaque, ?std.process.Child.Id) void;

pub const TurnRequest = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    backend: BackendKind,
    argv: []const []const u8,
    environ_map: *const std.process.Environ.Map,
    loop_id: []const u8,
    loop_dir: []const u8,
    prompt: []const u8,
    cwd: std.process.Child.Cwd = .inherit,
    event_context: ?*anyopaque = null,
    event_handler: ?stream.EventHandler = null,
    session_context: ?*anyopaque = null,
    on_session_id: ?OnSessionId = null,
    child_context: ?*anyopaque = null,
    on_child_id: ?OnChildId = null,
    diagnostics: ?*std.Io.Writer = null,
    log_pair: ?*loop_log.Pair = null,
    log_context: loop_log.Pair.Context = .{},
};

pub const TurnExecutionResult = struct {
    allocator: std.mem.Allocator,
    exit_code: i32,
    session_id: ?[]u8,
    tokens_used: u64,
    last_assistant_text: ?[]u8,
    stderr_tail: []u8,
    was_interrupted: bool,

    pub fn deinit(self: *TurnExecutionResult) void {
        if (self.session_id) |value| self.allocator.free(value);
        if (self.last_assistant_text) |value| self.allocator.free(value);
        self.allocator.free(self.stderr_tail);
        self.* = undefined;
    }
};

pub const PreflightRequest = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: BackendOptions,
    environ_map: *const std.process.Environ.Map,
    cwd: []const u8,
    diagnostics: ?*std.Io.Writer = null,
};

/// Injectable backend runner, matching the callback shape used by CLI runners.
pub const BackendRunner = struct {
    context: *anyopaque,
    runTurnFn: *const fn (context: *anyopaque, request: TurnRequest) anyerror!TurnExecutionResult,
    preflightFn: ?*const fn (context: *anyopaque, request: PreflightRequest) anyerror!void = null,

    pub fn preflight(self: BackendRunner, request: PreflightRequest) !void {
        if (self.preflightFn) |check| try check(self.context, request);
    }

    pub fn runTurn(self: BackendRunner, request: TurnRequest) anyerror!TurnExecutionResult {
        return self.runTurnFn(self.context, request);
    }
};

pub const RealBackendRunner = struct {
    pub fn runner(self: *RealBackendRunner) BackendRunner {
        return .{ .context = @ptrCast(self), .runTurnFn = RealBackendRunner.runTurn, .preflightFn = RealBackendRunner.preflight };
    }

    fn preflight(_: *anyopaque, request: PreflightRequest) !void {
        checkExecutable(request) catch |err| {
            if (request.diagnostics) |writer| {
                try writer.print("Cannot use backend executable '{s}': {s}\n", .{ request.config.backend_bin orelse @tagName(request.config.backend), @errorName(err) });
                try writer.flush();
            }
            return err;
        };
    }

    fn runTurn(context: *anyopaque, request: TurnRequest) anyerror!TurnExecutionResult {
        _ = context;
        return executeTurn(request);
    }
};

/// Validate each enabled role before starting work; spawning still validates again.
fn checkExecutable(request: PreflightRequest) !void {
    const command = request.config.backend_bin orelse @tagName(request.config.backend);
    if (command.len == 0 or std.mem.indexOfScalar(u8, command, 0) != null) return error.InvalidExecutable;
    if (std.mem.indexOfScalar(u8, command, '/') != null) return checkCandidate(request, command);
    var entries = std.mem.splitScalar(u8, request.environ_map.get("PATH") orelse "/usr/local/bin:/bin:/usr/bin", ':');
    var denied = false;
    while (entries.next()) |entry| {
        const candidate = try std.fmt.allocPrint(request.allocator, "{s}/{s}", .{ if (entry.len == 0) "." else entry, command });
        defer request.allocator.free(candidate);
        checkCandidate(request, candidate) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            error.AccessDenied, error.PermissionDenied, error.NotExecutable => {
                denied = true;
                continue;
            },
            else => return err,
        };
        return;
    }
    return if (denied) error.AccessDenied else error.FileNotFound;
}

fn checkCandidate(request: PreflightRequest, candidate: []const u8) !void {
    const resolved = try std.fs.path.resolve(request.allocator, &.{ request.cwd, candidate });
    defer request.allocator.free(resolved);
    const stat = try std.Io.Dir.cwd().statFile(request.io, resolved, .{});
    if (stat.kind != .file) return error.NotExecutable;
    try std.Io.Dir.cwd().access(request.io, resolved, .{ .execute = true });
}

/// Zig's spawn searches the parent PATH even with an explicit child environment.
/// Try literal path candidates so the actual child PATH determines selection.
fn spawnSelected(request: TurnRequest) !std.process.Child {
    const command = request.argv[0];
    if (std.mem.indexOfScalar(u8, command, '/') != null) return spawnCandidate(request, request.argv);
    const argv = try request.allocator.dupe([]const u8, request.argv);
    defer request.allocator.free(argv);
    const child_path = request.environ_map.get("PATH") orelse "/usr/local/bin:/bin:/usr/bin";
    var entries = std.mem.splitScalar(u8, child_path, ':');
    var denied = false;
    while (entries.next()) |entry| {
        const candidate = try std.fmt.allocPrint(request.allocator, "{s}/{s}", .{ if (entry.len == 0) "." else entry, command });
        defer request.allocator.free(candidate);
        argv[0] = candidate;
        return spawnCandidate(request, argv) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            error.AccessDenied => {
                denied = true;
                continue;
            },
            else => return err,
        };
    }
    return if (denied) error.AccessDenied else error.FileNotFound;
}

fn spawnCandidate(request: TurnRequest, argv: []const []const u8) !std.process.Child {
    return std.process.spawn(request.io, .{
        .argv = argv,
        .cwd = request.cwd,
        .environ_map = request.environ_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
}

const stderr_tail_capacity = 8 * 1024;
extern "c" fn kill(pid: std.posix.pid_t, signal_number: c_int) c_int;

fn stopChild(id: std.process.Child.Id) void {
    _ = kill(@intCast(id), @intCast(@intFromEnum(std.posix.SIG.KILL)));
}

/// Spawn a backend, stream its stdout events, drain stderr concurrently, and return after wait.
pub fn executeTurn(request: TurnRequest) anyerror!TurnExecutionResult {
    try writePromptFile(request);

    var child = spawnSelected(request) catch |err| {
        if (err == error.FileNotFound) {
            if (request.diagnostics) |diagnostics| {
                try diagnostics.print("Backend executable '{s}' was not found (using child PATH)\n", .{request.argv[0]});
                try diagnostics.flush();
            }
            return error.BackendNotFound;
        }
        if (request.diagnostics) |diagnostics| {
            try diagnostics.print("Cannot launch backend executable '{s}': {s}\n", .{ request.argv[0], @errorName(err) });
            try diagnostics.flush();
        }
        return err;
    };
    defer child.kill(request.io);

    const child_id = child.id orelse return error.MissingChildId;
    if (request.on_child_id) |callback| callback(request.child_context, child_id);
    defer if (request.on_child_id) |callback| callback(request.child_context, null);

    const stdin_file = child.stdin orelse return error.MissingChildStdin;
    const stdout_file = child.stdout orelse return error.MissingChildStdout;
    const stderr_file = child.stderr orelse return error.MissingChildStderr;

    var stderr_drain = StderrDrain.init(request.io, stderr_file, request.log_pair, request.loop_id, request.log_context, child_id);
    var stderr_thread = try std.Thread.spawn(.{}, StderrDrain.run, .{&stderr_drain});
    var stdin_write = StdinWrite.init(request.io, stdin_file, request.prompt);
    var stdin_thread = std.Thread.spawn(.{}, StdinWrite.run, .{&stdin_write}) catch |err| {
        // The stderr worker may be blocked on the child pipe. Kill the child
        // before joining it so a failed second spawn cannot leak the thread.
        child.kill(request.io);
        stderr_thread.join();
        return err;
    };

    var accumulator: stream.TurnAccumulator = .{};
    defer accumulator.deinit(request.allocator);
    var callback_state = StreamCallbackState{
        .request = request,
        .child_id = child_id,
    };
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_reader = stdout_file.readerStreaming(request.io, &stdout_buffer);
    const stream_result = stream.readStreamRaw(request.allocator, &stdout_reader.interface, request.backend, &accumulator, &callback_state, StreamCallbackState.handle, &callback_state, if (request.log_pair != null) rawStdout else null);

    if (stream_result) |_| {} else |_| stopChild(child_id);
    if (callback_state.callback_error != null) stopChild(child_id);

    stdin_thread.join();
    stderr_thread.join();
    // The worker threads closed these pipe handles, so prevent Child.wait from closing
    // the same descriptors a second time during child cleanup.
    child.stdin = null;
    child.stderr = null;
    const term = try child.wait(request.io);

    try stream_result;
    if (callback_state.callback_error) |err| return err;
    if (stderr_drain.log_error) |err| return err;
    if (stdin_write.write_error) return error.ChildStdinWriteFailed;
    if (stderr_drain.read_error) return error.ChildStderrReadFailed;

    const session_id = if (accumulator.session_id) |value| try request.allocator.dupe(u8, value) else null;
    errdefer if (session_id) |value| request.allocator.free(value);
    const last_assistant_text = if (accumulator.last_assistant_message) |value| try request.allocator.dupe(u8, value) else null;
    errdefer if (last_assistant_text) |value| request.allocator.free(value);
    const stderr_tail = try stderr_drain.toOwnedSlice(request.allocator);
    errdefer request.allocator.free(stderr_tail);
    return .{
        .allocator = request.allocator,
        .exit_code = switch (term) {
            .exited => |code| code,
            else => -1,
        },
        .session_id = session_id,
        .tokens_used = accumulator.tokens_used,
        .last_assistant_text = last_assistant_text,
        .stderr_tail = stderr_tail,
        .was_interrupted = term != .exited,
    };
}

fn writePromptFile(request: TurnRequest) !void {
    const prompt_path = try std.fmt.allocPrint(request.allocator, "{s}{c}current_prompt.md", .{
        request.loop_dir,
        std.Io.Dir.path.sep,
    });
    defer request.allocator.free(prompt_path);
    const file = try std.Io.Dir.cwd().createFile(request.io, prompt_path, .{ .truncate = true });
    defer file.close(request.io);
    try file.writeStreamingAll(request.io, request.prompt);
}

const StreamCallbackState = struct {
    request: TurnRequest,
    child_id: std.process.Child.Id,
    callback_error: ?anyerror = null,

    fn failed(self: *StreamCallbackState, err: anyerror) void {
        self.callback_error = err;
        stopChild(self.child_id);
    }

    fn handle(context: ?*anyopaque, event: stream.NormalizedEvent) void {
        const self: *StreamCallbackState = @ptrCast(@alignCast(context.?));
        if (event == .session_id and self.request.on_session_id != null and self.callback_error == null) {
            self.request.on_session_id.?(self.request.session_context, event.session_id) catch |err| {
                self.failed(err);
            };
        }
        if (self.request.event_handler) |handler| handler(self.request.event_context, event);
        if (self.request.log_pair) |pair| {
            const kind: []const u8, const payload: []const u8 = switch (event) {
                .session_id => |value| .{ "session", value },
                .assistant_text => |value| .{ "assistant", value },
                .tool_call => |tool| blk: {
                    pair.recordContext(self.request.io, self.request.loop_id, self.request.log_context, "tool", tool.name) catch |err| {
                        self.failed(err);
                    };
                    break :blk .{ "tool_detail", tool.detail };
                },
                .error_message => |value| .{ "error", value },
                .token_usage => |usage| blk: {
                    var buffer: [80]u8 = undefined;
                    const value = std.fmt.bufPrint(&buffer, "input={d} output={d} total={d}", .{ usage.input_tokens, usage.output_tokens, usage.total_tokens }) catch break :blk .{ "usage", "usage" };
                    pair.recordContext(self.request.io, self.request.loop_id, self.request.log_context, "usage", value) catch |err| {
                        self.failed(err);
                    };
                    return;
                },
                .ignored, .thinking => return,
            };
            pair.recordContext(self.request.io, self.request.loop_id, self.request.log_context, kind, payload) catch |err| {
                self.failed(err);
            };
        }
    }
};

fn rawStdout(context: ?*anyopaque, bytes: []const u8) anyerror!void {
    const state: *StreamCallbackState = @ptrCast(@alignCast(context.?));
    const request = state.request;
    if (state.callback_error) |err| return err;
    if (request.log_pair) |pair| pair.rawContext(request.io, request.loop_id, request.log_context, "stdout", bytes) catch |err| {
        state.failed(err);
        return err;
    };
}

const StdinWrite = struct {
    io: std.Io,
    file: std.Io.File,
    prompt: []const u8,
    write_error: bool = false,

    fn init(io: std.Io, file: std.Io.File, prompt: []const u8) StdinWrite {
        return .{ .io = io, .file = file, .prompt = prompt };
    }

    fn run(self: *StdinWrite) void {
        self.file.writeStreamingAll(self.io, self.prompt) catch {
            self.write_error = true;
        };
        self.file.close(self.io);
    }
};

const StderrDrain = struct {
    io: std.Io,
    file: std.Io.File,
    bytes: [stderr_tail_capacity]u8 = undefined,
    start: usize = 0,
    len: usize = 0,
    read_error: bool = false,
    log_error: ?anyerror = null,
    log_pair: ?*loop_log.Pair,
    loop_id: []const u8,
    log_context: loop_log.Pair.Context,
    child_id: std.process.Child.Id,

    fn init(io: std.Io, file: std.Io.File, log_pair: ?*loop_log.Pair, loop_id: []const u8, log_context: loop_log.Pair.Context, child_id: std.process.Child.Id) StderrDrain {
        return .{ .io = io, .file = file, .log_pair = log_pair, .loop_id = loop_id, .log_context = log_context, .child_id = child_id };
    }

    fn run(self: *StderrDrain) void {
        var buffer: [4096]u8 = undefined;
        while (true) {
            const count = self.file.readStreaming(self.io, &.{&buffer}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => {
                    self.read_error = true;
                    break;
                },
            };
            if (count == 0) break;
            if (self.log_pair) |pair| {
                pair.rawContext(self.io, self.loop_id, self.log_context, "stderr", buffer[0..count]) catch |err| {
                    self.log_error = err;
                    stopChild(self.child_id);
                    break;
                };
                pair.stderr(self.io, self.loop_id, self.log_context, buffer[0..count]) catch |err| {
                    self.log_error = err;
                    stopChild(self.child_id);
                    break;
                };
            }
            self.append(buffer[0..count]);
        }
        self.file.close(self.io);
    }

    fn append(self: *StderrDrain, incoming: []const u8) void {
        if (incoming.len >= self.bytes.len) {
            @memcpy(&self.bytes, incoming[incoming.len - self.bytes.len ..]);
            self.start = 0;
            self.len = self.bytes.len;
            return;
        }
        for (incoming) |byte| {
            if (self.len < self.bytes.len) {
                self.bytes[(self.start + self.len) % self.bytes.len] = byte;
                self.len += 1;
            } else {
                self.bytes[self.start] = byte;
                self.start = (self.start + 1) % self.bytes.len;
            }
        }
    }

    fn toOwnedSlice(self: *const StderrDrain, allocator: std.mem.Allocator) ![]u8 {
        const result = try allocator.alloc(u8, self.len);
        const first = @min(self.len, self.bytes.len - self.start);
        @memcpy(result[0..first], self.bytes[self.start .. self.start + first]);
        if (first < self.len) @memcpy(result[first..], self.bytes[0 .. self.len - first]);
        return result;
    }
};

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
    sandbox: ?options.SandboxPolicy = null,
    legacy_policy_passthrough: bool = false,
    backend_bin: ?[]const u8 = null,
    model: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
    yolo: bool = false,
    extra_args: []const []const u8 = &.{},
};

/// Capability evidence and callback restriction: LOOP_SANDBOX_CAPABILITIES.md.
/// No vendor discovery runs during execution.
pub fn validatePolicy(config: BackendOptions, diagnostic: ?*std.Io.Writer) !void {
    if (config.model) |model| {
        if (std.mem.indexOfScalar(u8, model, 0) != null) return error.InvalidModel;
    }
    if (config.reasoning_effort) |effort| {
        const allowed = [_][]const u8{ "low", "medium", "high", "xhigh", "max" };
        var supported = false;
        for (allowed) |value| if (std.mem.eql(u8, value, effort)) {
            supported = true;
            break;
        };
        if (!supported) {
            if (diagnostic) |writer| try writer.print("Unsupported reasoning effort {s} for {s}\n", .{ effort, @tagName(config.backend) });
            return error.UnsupportedReasoningEffort;
        }
        if (conflictingNativeReasoning(config.backend, config.extra_args)) |arg| {
            if (diagnostic) |writer| try writer.print("Structured reasoning effort conflicts with native argument {s}\n", .{arg});
            return error.ConflictingNativeReasoning;
        }
    }
    if (config.yolo and config.sandbox != null) {
        if (diagnostic) |writer| try writer.writeAll("sandbox and yolo cannot both be selected\n");
        return error.ConflictingPolicy;
    }
    if (config.sandbox) |policy| {
        if (policy == .@"read-only") {
            if (diagnostic) |writer| try writer.writeAll("read-only cannot run a supervised loop: Matcha callbacks must write the loop store; no writable exception is added automatically. Choose workspace-write for Codex or backend-default.\n");
            return error.ReadOnlyPreventsCallbacks;
        }
        if (config.backend != .codex and policy != .@"backend-default") {
            if (diagnostic) |writer| try writer.print("Backend {s} cannot enforce sandbox {s} independently of approvals. Supported sandbox choices: backend-default. --yolo is a separate explicit bypass.\n", .{ @tagName(config.backend), @tagName(policy) });
            return error.UnsupportedSandboxPolicy;
        }
    }
    if (config.sandbox != null or (config.yolo and !config.legacy_policy_passthrough)) {
        if (conflictingNativePolicy(config.backend, config.extra_args)) |arg| {
            if (diagnostic) |writer| try writer.print("Structured permission policy conflicts with native argument {s}; remove one policy source.\n", .{arg});
            return error.ConflictingNativePolicy;
        }
    }
}

fn conflictingNativeReasoning(kind: BackendKind, args: []const []const u8) ?[]const u8 {
    for (args, 0..) |arg, index| {
        switch (kind) {
            .codex => {
                if (std.mem.startsWith(u8, arg, "model_reasoning_effort=")) return arg;
                if (std.mem.startsWith(u8, arg, "--config=model_reasoning_effort=")) return arg;
                if (std.mem.startsWith(u8, arg, "-cmodel_reasoning_effort=")) return arg;
                if ((std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) and index + 1 < args.len and std.mem.startsWith(u8, args[index + 1], "model_reasoning_effort=")) return arg;
            },
            .droid => if (std.mem.eql(u8, arg, "-r") or flagMatches(arg, "--reasoning-effort")) return arg,
            .agy => if (flagMatches(arg, "--effort")) return arg,
        }
    }
    return null;
}

fn flagMatches(arg: []const u8, flag: []const u8) bool {
    return std.mem.eql(u8, arg, flag) or (std.mem.startsWith(u8, arg, flag) and arg.len > flag.len and arg[flag.len] == '=');
}

fn codexPolicyConfig(raw_value: []const u8) bool {
    const value = if (std.mem.startsWith(u8, raw_value, "=")) raw_value[1..] else raw_value;
    const key = std.mem.trim(u8, value[0 .. std.mem.indexOfScalar(u8, value, '=') orelse value.len], " \t\"'");
    return std.mem.eql(u8, key, "sandbox_mode") or std.mem.eql(u8, key, "approval_policy") or
        std.mem.eql(u8, key, "sandbox_permissions") or std.mem.eql(u8, key, "sandbox_workspace_write") or
        std.mem.startsWith(u8, key, "sandbox_workspace_write.") or std.mem.startsWith(u8, key, "approval_policy.");
}

fn conflictingNativePolicy(kind: BackendKind, args: []const []const u8) ?[]const u8 {
    for (args, 0..) |arg, i| {
        const flags: []const []const u8 = switch (kind) {
            .codex => &.{ "-s", "--sandbox", "-a", "--ask-for-approval", "--full-auto", "--approve-for-me", "--yolo", "--dangerously-bypass-approvals-and-sandbox", "--add-dir" },
            .droid => &.{ "--auto", "--skip-permissions-unsafe", "--settings" },
            .agy => &.{ "--sandbox", "--mode", "--dangerously-skip-permissions", "--settings" },
        };
        for (flags) |flag| if (flagMatches(arg, flag)) return arg;
        if (kind == .codex) {
            if ((std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) and i + 1 < args.len and codexPolicyConfig(args[i + 1])) return arg;
            if (std.mem.startsWith(u8, arg, "--config=") and codexPolicyConfig(arg["--config=".len..])) return arg;
            if (std.mem.startsWith(u8, arg, "-c") and arg.len > 2 and codexPolicyConfig(arg[2..])) return arg;
            if ((std.mem.startsWith(u8, arg, "-s") or std.mem.startsWith(u8, arg, "-a")) and arg.len > 2 and arg[1] != '-') return arg;
        }
    }
    return null;
}

/// Build argv for one backend invocation. A null session ID starts a fresh session.
/// `prompt_file` is used by Droid; Codex and Agy consume the prompt through stdin.
pub fn buildArgv(
    allocator: std.mem.Allocator,
    config: BackendOptions,
    loop_dir: []const u8,
    session_id: ?[]const u8,
    prompt_file: []const u8,
) !Argv {
    try validatePolicy(config, null);
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
    try builder.add(config.backend_bin orelse "codex");
    try builder.add("exec");
    if (config.yolo) {
        try builder.add("--dangerously-bypass-approvals-and-sandbox");
    } else if (config.sandbox) |policy| {
        if (policy != .@"backend-default") {
            try builder.add("--sandbox");
            try builder.add(@tagName(policy));
            if (policy == .@"workspace-write") {
                try builder.add("--add-dir");
                try builder.add(loop_dir);
            }
        }
    } else {
        if (!hasSandboxOverride(config.extra_args)) {
            try builder.add("-s");
            try builder.add("workspace-write");
        }
        try builder.add("--add-dir");
        try builder.add(loop_dir);
    }
    if (config.model) |model| {
        try builder.add("--model");
        try builder.add(model);
    }
    if (config.reasoning_effort) |effort| {
        try builder.add("-c");
        const setting = try std.fmt.allocPrint(builder.allocator, "model_reasoning_effort=\"{s}\"", .{effort});
        defer builder.allocator.free(setting);
        try builder.add(setting);
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

fn hasSandboxOverride(args: []const []const u8) bool {
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--sandbox")) return i + 1 < args.len;
        if (std.mem.startsWith(u8, arg, "--sandbox=")) return true;
    }
    return false;
}

fn buildDroid(builder: *ArgvBuilder, config: BackendOptions, session_id: ?[]const u8, prompt_file: []const u8) !void {
    try builder.add(config.backend_bin orelse "droid");
    try builder.add("exec");
    if (config.yolo) {
        try builder.add("--skip-permissions-unsafe");
    } else if (config.sandbox == null) {
        try builder.add("--auto");
        try builder.add("high");
    }
    if (session_id) |id| {
        try builder.add("-s");
        try builder.add(id);
    }
    if (config.model) |model| {
        try builder.add("-m");
        try builder.add(model);
    }
    if (config.reasoning_effort) |effort| {
        try builder.add("--reasoning-effort");
        try builder.add(effort);
    }
    try builder.addMany(config.extra_args);
    try builder.add("-o");
    try builder.add("stream-json");
    try builder.add("-f");
    try builder.add(prompt_file);
}

fn buildAgy(builder: *ArgvBuilder, config: BackendOptions, loop_dir: []const u8, session_id: ?[]const u8) !void {
    try builder.add(config.backend_bin orelse "agy");
    try builder.add("-p");
    if (config.yolo) {
        try builder.add("--dangerously-skip-permissions");
    } else if (config.sandbox == null) {
        try builder.add("--mode");
        try builder.add("auto");
    }
    if (config.sandbox == null) {
        try builder.add("--add-dir");
        try builder.add(loop_dir);
    }
    if (session_id) |id| {
        try builder.add("--conversation");
        try builder.add(id);
    }
    if (config.model) |model| {
        try builder.add("--model");
        try builder.add(model);
    }
    if (config.reasoning_effort) |effort| {
        try builder.add("--effort");
        try builder.add(effort);
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
    return buildChildEnvironmentConfigured(allocator, io, parent, loop_id, &.{}, &.{});
}

pub fn buildChildEnvironmentConfigured(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: *const std.process.Environ.Map,
    loop_id: []const u8,
    overrides: []const options.EnvEntry,
    path_prepend: []const []const u8,
) !ChildEnvironment {
    const executable_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(executable_dir);
    return buildChildEnvironmentWithSettings(allocator, parent, loop_id, executable_dir, overrides, path_prepend);
}

fn buildChildEnvironmentWithBinaryDir(
    allocator: std.mem.Allocator,
    parent: *const std.process.Environ.Map,
    loop_id: []const u8,
    binary_dir: []const u8,
) !ChildEnvironment {
    return buildChildEnvironmentWithSettings(allocator, parent, loop_id, binary_dir, &.{}, &.{});
}

fn buildChildEnvironmentWithSettings(
    allocator: std.mem.Allocator,
    parent: *const std.process.Environ.Map,
    loop_id: []const u8,
    binary_dir: []const u8,
    overrides: []const options.EnvEntry,
    path_prepend: []const []const u8,
) !ChildEnvironment {
    var map = try parent.clone(allocator);
    errdefer map.deinit();
    for (overrides) |entry| {
        if (!options.validEnvKey(entry.key)) return error.InvalidEnvironmentKey;
        try map.put(entry.key, entry.value);
    }
    try map.put("MATCHA_LOOP_ID", loop_id);

    const old_path = map.get("PATH") orelse "";
    const separator: u8 = if (@import("builtin").os.tag == .windows) ';' else ':';
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(allocator);
    try path.appendSlice(allocator, binary_dir);
    for (path_prepend) |entry| {
        if (entry.len == 0) return error.InvalidPathPrepend;
        try path.append(allocator, separator);
        try path.appendSlice(allocator, entry);
    }
    if (old_path.len > 0) {
        try path.append(allocator, separator);
        try path.appendSlice(allocator, old_path);
    }
    try map.put("PATH", path.items);
    return .{ .map = map };
}

/// Human-readable attach command for a native interactive backend session.
pub fn formatNativeResumeCommand(allocator: std.mem.Allocator, backend: BackendKind, backend_bin: ?[]const u8, session_id: []const u8) ![]u8 {
    const command = try quoteShellWord(allocator, backend_bin orelse @tagName(backend));
    defer allocator.free(command);
    const session = try quoteShellWord(allocator, session_id);
    defer allocator.free(session);
    const attach = switch (backend) {
        .codex => "resume",
        .droid => "-r",
        .agy => "--conversation",
    };
    return std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ command, attach, session });
}

fn quoteShellWord(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const safe = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-";
    if (value.len > 0 and std.mem.indexOfNone(u8, value, safe) == null) return allocator.dupe(u8, value);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') try out.appendSlice(allocator, "'\\''") else try out.append(allocator, byte);
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
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

    const sandbox_override = [_][]const u8{ "-s", "danger-full-access", "--model_reasoning_effort", "high" };
    var overridden = try buildArgv(allocator, .{ .backend = .codex, .extra_args = &sandbox_override }, "/loops/id", null, "prompt.md");
    defer overridden.deinit();
    try expectArgv(&overridden, &.{ "codex", "exec", "--add-dir", "/loops/id", "-s", "danger-full-access", "--model_reasoning_effort", "high", "--json", "-" });
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

test "configured child environment preserves override and prefix order" {
    const a = std.testing.allocator;
    var parent = std.process.Environ.Map.init(a);
    defer parent.deinit();
    try parent.put("PATH", "/ambient");
    try parent.put("UNRELATED", "ambient-value");
    var child = try buildChildEnvironmentWithSettings(a, &parent, "current-id", "/matcha", &.{ .{ .key = "PATH", .value = "/literal" }, .{ .key = "JAVA_HOME", .value = "/jdk" } }, &.{ "/first", "/second" });
    defer child.deinit();
    try std.testing.expectEqualStrings("/matcha:/first:/second:/literal", child.map.get("PATH").?);
    try std.testing.expectEqualStrings("/jdk", child.map.get("JAVA_HOME").?);
    try std.testing.expectEqualStrings("ambient-value", child.map.get("UNRELATED").?);
    try std.testing.expectEqualStrings("/ambient", parent.get("PATH").?);
    try std.testing.expectError(error.InvalidEnvironmentKey, buildChildEnvironmentWithSettings(a, &parent, "current-id", "/matcha", &.{.{ .key = "MATCHA_LOOP_ID", .value = "wrong" }}, &.{}));
    var empty = try buildChildEnvironmentWithSettings(a, &parent, "current-id", "/matcha", &.{.{ .key = "PATH", .value = "" }}, &.{});
    defer empty.deinit();
    try std.testing.expectEqualStrings("/matcha", empty.map.get("PATH").?);
}

test "reasoning efforts reach each backend and resumed codex turns" {
    const a = std.testing.allocator;
    for ([_]BackendKind{ .codex, .droid, .agy }) |kind| {
        var argv = try buildArgv(a, .{ .backend = kind, .reasoning_effort = "high" }, "/loops/id", null, "prompt.md");
        defer argv.deinit();
        const flag: []const u8 = switch (kind) {
            .codex => "model_reasoning_effort=\"high\"",
            .droid => "--reasoning-effort",
            .agy => "--effort",
        };
        var found = false;
        for (argv.items) |item| if (std.mem.eql(u8, item, flag)) {
            found = true;
            break;
        };
        try std.testing.expect(found);
    }
    var resumed = try buildArgv(a, .{ .backend = .codex, .reasoning_effort = "xhigh" }, "/loops/id", "saved-session", "prompt.md");
    defer resumed.deinit();
    var resume_effort_found = false;
    for (resumed.items) |item| if (std.mem.eql(u8, item, "model_reasoning_effort=\"xhigh\"")) {
        resume_effort_found = true;
        break;
    };
    try std.testing.expect(resume_effort_found);
    try std.testing.expectError(error.UnsupportedReasoningEffort, buildArgv(a, .{ .backend = .codex, .reasoning_effort = "none" }, "/loops/id", null, "prompt.md"));
    try std.testing.expectError(error.ConflictingNativeReasoning, buildArgv(a, .{ .backend = .codex, .reasoning_effort = "high", .extra_args = &.{ "-c", "model_reasoning_effort=\"low\"" } }, "/loops/id", null, "prompt.md"));
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
        const command = try formatNativeResumeCommand(allocator, backend, null, "s-1");
        defer allocator.free(command);
        try std.testing.expectEqualStrings(expected[i], command);
    }
}

test "real runner streams events, captures early session, stdin, stderr, and exit status" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const loop_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(loop_dir);
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const absolute_loop_dir = try std.fs.path.resolve(allocator, &.{ cwd, loop_dir });
    defer allocator.free(absolute_loop_dir);

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("PATH", "/bin:/usr/bin");

    const script =
        \\payload=$(cat)
        \\[ "${#payload}" -eq 12000 ] || exit 9
        \\printf '{"type":"thread.started","thread_id":"sid-early"}\n'
        \\sleep 0.05
        \\printf '{"type":"item.completed","item":{"type":"agent_message","text":"answer"}}\n'
        \\printf '{"type":"turn.completed","usage":{"input_tokens":4,"output_tokens":2}}\n'
        \\printf 'begin-'
        \\i=0; while [ "$i" -lt 9000 ]; do printf x; i=$((i + 1)); done
        \\i=0; while [ "$i" -lt 9000 ]; do printf y >&2; i=$((i + 1)); done
        \\printf '%s\n' '-stderr-tail-marker' >&2
        \\exit 7
    ;
    const argv = [_][]const u8{ "/bin/sh", "-c", script };
    var events = RunnerEventCapture{};
    var callbacks = RunnerCallbackCapture{ .allocator = allocator };
    defer if (callbacks.session_id) |id| allocator.free(id);
    var runner_impl: RealBackendRunner = .{};
    var pair = try loop_log.open(allocator, std.testing.io, absolute_loop_dir, "loop-1");
    defer pair.deinit(std.testing.io);
    const request = TurnRequest{
        .allocator = allocator,
        .io = std.testing.io,
        .backend = .codex,
        .argv = &argv,
        .environ_map = &environ,
        .loop_id = "loop-1",
        .loop_dir = absolute_loop_dir,
        .prompt = try allocator.alloc(u8, 12000),
        .event_context = &events,
        .event_handler = RunnerEventCapture.handle,
        .session_context = &callbacks,
        .on_session_id = RunnerCallbackCapture.session,
        .child_context = &callbacks,
        .on_child_id = RunnerCallbackCapture.child,
        .log_pair = &pair,
        .log_context = .{ .turn = 1, .role = "worker", .backend = "codex", .attempt = 1 },
    };
    @memset(@constCast(request.prompt), 'p');
    defer allocator.free(@constCast(request.prompt));

    var result = try runner_impl.runner().runTurn(request);
    defer result.deinit();
    try std.testing.expectEqual(@as(i32, 7), result.exit_code);
    try std.testing.expect(!result.was_interrupted);
    try std.testing.expectEqualStrings("sid-early", callbacks.session_id.?);
    try std.testing.expect(callbacks.child_started and callbacks.child_cleared and callbacks.session_arrived_while_running);
    try std.testing.expectEqualStrings("answer", result.last_assistant_text.?);
    try std.testing.expectEqual(@as(u64, 6), result.tokens_used);
    try std.testing.expect(events.session_count == 1 and events.assistant_count == 1);
    try std.testing.expect(result.stderr_tail.len <= stderr_tail_capacity);
    try std.testing.expect(std.mem.endsWith(u8, result.stderr_tail, "-stderr-tail-marker\n"));
    const log_path = try std.fmt.allocPrint(allocator, "{s}/{s}.log", .{ absolute_loop_dir, pair.invocation_id });
    defer allocator.free(log_path);
    const readable = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, log_path, allocator, .unlimited);
    defer allocator.free(readable);
    try std.testing.expect(std.mem.indexOf(u8, readable, "assistant: answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, readable, "-stderr-tail-marker") != null);
    const jsonl_path = try std.fmt.allocPrint(allocator, "{s}/{s}.jsonl", .{ absolute_loop_dir, pair.invocation_id });
    defer allocator.free(jsonl_path);
    const jsonl = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, jsonl_path, allocator, .unlimited);
    defer allocator.free(jsonl);
    var stdout_bytes: std.ArrayList(u8) = .empty;
    defer stdout_bytes.deinit(allocator);
    var stderr_bytes: std.ArrayList(u8) = .empty;
    defer stderr_bytes.deinit(allocator);
    var lines = std.mem.tokenizeScalar(u8, jsonl, '\n');
    while (lines.next()) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const value = parsed.value;
        if (!std.mem.eql(u8, value.object.get("kind").?.string, "raw")) continue;
        const encoded = value.object.get("payload").?.string;
        const decoded = try allocator.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
        defer allocator.free(decoded);
        try std.base64.standard.Decoder.decode(decoded, encoded);
        const target = if (std.mem.eql(u8, value.object.get("stream").?.string, "stdout")) &stdout_bytes else &stderr_bytes;
        try target.appendSlice(allocator, decoded);
        try std.testing.expectEqual(@as(i64, 1), value.object.get("attempt").?.integer);
    }
    try std.testing.expect(std.mem.startsWith(u8, stdout_bytes.items, "{\"type\":\"thread.started\""));
    try std.testing.expect(std.mem.endsWith(u8, stdout_bytes.items, "begin-" ++ ("x" ** 9000)));
    try std.testing.expectEqual(@as(usize, 9000 + "-stderr-tail-marker\n".len), stderr_bytes.items.len);
    try std.testing.expect(std.mem.startsWith(u8, stderr_bytes.items, "y" ** 9000));
    const prompt_path = try std.fmt.allocPrint(allocator, "{s}/current_prompt.md", .{absolute_loop_dir});
    defer allocator.free(prompt_path);
    const saved_prompt = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, prompt_path, allocator, .limited(20000));
    defer allocator.free(saved_prompt);
    try std.testing.expect(saved_prompt.len == 12000);

    const success_script = "cat >/dev/null; printf '{\"type\":\"turn.completed\"}\\n'; exit 0";
    const success_argv = [_][]const u8{ "/bin/sh", "-c", success_script };
    var success_request = request;
    success_request.argv = &success_argv;
    success_request.prompt = "short prompt";
    success_request.event_context = null;
    success_request.event_handler = null;
    success_request.session_context = null;
    success_request.on_session_id = null;
    success_request.child_context = null;
    success_request.on_child_id = null;
    var success = try runner_impl.runner().runTurn(success_request);
    defer success.deinit();
    try std.testing.expectEqual(@as(i32, 0), success.exit_code);
    try std.testing.expect(!success.was_interrupted);
}

test "audit stream failure kills child before blocked stdin and stderr joins" {
    const Fault = struct {
        phase: loop_log.Pair.FaultPhase,
        fn check(context: *anyopaque, phase: loop_log.Pair.FaultPhase) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.phase == phase) return error.InjectedStreamFailure;
        }
    };
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const loop_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(loop_dir);
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("PATH", "/bin:/usr/bin");
    const prompt = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(prompt);
    @memset(prompt, 'p');
    for ([_]loop_log.Pair.FaultPhase{ .stdout_write, .stderr_write }) |phase| {
        var fault = Fault{ .phase = phase };
        var pair = try loop_log.openWithFault(allocator, std.testing.io, loop_dir, "stream-fault", .{ .context = &fault, .check = Fault.check });
        defer pair.deinit(std.testing.io);
        const script = if (phase == .stdout_write)
            "i=0; while [ $i -lt 100000 ]; do printf x; i=$((i+1)); done; cat >/dev/null"
        else
            "i=0; while [ $i -lt 100000 ]; do printf x >&2; i=$((i+1)); done; cat >/dev/null";
        const argv = [_][]const u8{ "/bin/sh", "-c", script };
        try std.testing.expectError(error.AuditLogFailure, executeTurn(.{
            .allocator = allocator,
            .io = std.testing.io,
            .backend = .codex,
            .argv = &argv,
            .environ_map = &environ,
            .loop_id = "stream-fault",
            .loop_dir = loop_dir,
            .prompt = prompt,
            .log_pair = &pair,
        }));
        try std.testing.expectEqual(error.InjectedStreamFailure, pair.failure.?.cause);
    }
}

test "real runner diagnoses a missing backend executable" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const loop_dir = try std.fs.path.resolve(allocator, &.{ cwd, ".zig-cache/tmp", &tmp.sub_path });
    defer allocator.free(loop_dir);
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("PATH", "/bin:/usr/bin");
    const argv = [_][]const u8{"/does/not/exist/matcha-test-backend"};
    var diagnostic = std.Io.Writer.Allocating.init(allocator);
    defer diagnostic.deinit();
    const request = TurnRequest{
        .allocator = allocator,
        .io = std.testing.io,
        .backend = .agy,
        .argv = &argv,
        .environ_map = &environ,
        .loop_id = "loop-1",
        .loop_dir = loop_dir,
        .prompt = "prompt",
        .diagnostics = &diagnostic.writer,
    };
    var runner_impl: RealBackendRunner = .{};
    try std.testing.expectError(error.BackendNotFound, runner_impl.runner().runTurn(request));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.written(), argv[0]) != null);
}

const RunnerEventCapture = struct {
    session_count: usize = 0,
    assistant_count: usize = 0,

    fn handle(context: ?*anyopaque, event: stream.NormalizedEvent) void {
        const self: *RunnerEventCapture = @ptrCast(@alignCast(context.?));
        switch (event) {
            .session_id => self.session_count += 1,
            .assistant_text => self.assistant_count += 1,
            else => {},
        }
    }
};

const RunnerCallbackCapture = struct {
    allocator: std.mem.Allocator,
    session_id: ?[]const u8 = null,
    child_started: bool = false,
    child_cleared: bool = false,
    session_arrived_while_running: bool = false,

    fn session(context: ?*anyopaque, id: []const u8) anyerror!void {
        const self: *RunnerCallbackCapture = @ptrCast(@alignCast(context.?));
        self.session_id = try self.allocator.dupe(u8, id);
        self.session_arrived_while_running = self.child_started and !self.child_cleared;
    }

    fn child(context: ?*anyopaque, id: ?std.process.Child.Id) void {
        const self: *RunnerCallbackCapture = @ptrCast(@alignCast(context.?));
        if (id == null) self.child_cleared = true else self.child_started = true;
    }
};

fn expectArgv(actual: *const Argv, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.items.len);
    for (expected, actual.items) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "custom executable changes only argv zero for every adapter and session form" {
    const a = std.testing.allocator;
    const bins = [_][]const u8{ "custom-wrapper", "./relative-wrapper", "/tmp/path with spaces/agent" };
    for ([_]BackendKind{ .codex, .droid, .agy }) |backend| {
        for ([_]?[]const u8{ null, "saved-session" }) |session| {
            var standard = try buildArgv(a, .{ .backend = backend }, "/loops/id", session, "/loops/id/prompt.md");
            defer standard.deinit();
            for (bins) |bin| {
                var custom = try buildArgv(a, .{ .backend = backend, .backend_bin = bin }, "/loops/id", session, "/loops/id/prompt.md");
                defer custom.deinit();
                try std.testing.expectEqualStrings(bin, custom.items[0]);
                try std.testing.expectEqual(standard.items.len, custom.items.len);
                for (standard.items[1..], custom.items[1..]) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
            }
        }
    }
}

test "native attach quotes executable and session as single literal shell words" {
    const a = std.testing.allocator;
    const command = try formatNativeResumeCommand(a, .codex, "/tmp/agent's $(literal)", "session; echo unsafe");
    defer a.free(command);
    try std.testing.expectEqualStrings("'/tmp/agent'\\''s $(literal)' resume 'session; echo unsafe'", command);
}

test "custom wrapper launches literally through effective child PATH and reports permission errors" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(io, a);
    defer a.free(cwd);
    const dir = try std.fs.path.resolve(a, &.{ cwd, ".zig-cache/tmp", &tmp.sub_path });
    defer a.free(dir);
    const filename = "custom wrapper $(literal)";
    {
        const file = try tmp.dir.createFile(io, filename, .{ .permissions = .executable_file });
        defer file.close(io);
        try file.writeStreamingAll(io,
            \\#!/bin/sh
            \\cat >/dev/null
            \\printf '%s\n' "$0" "$@" > "$RECORD_PATH"
            \\printf '{"type":"item.completed","item":{"type":"agent_message","text":"custom wrapper ran"}}\n'
            \\printf '{"type":"turn.completed"}\n'
        );
    }
    const binary = try std.fs.path.join(a, &.{ dir, filename });
    defer a.free(binary);
    const record = try std.fs.path.join(a, &.{ dir, "record" });
    defer a.free(record);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const search_path = try std.fmt.allocPrint(a, "{s}:/bin:/usr/bin", .{dir});
    defer a.free(search_path);
    try env.put("PATH", search_path);
    try env.put("RECORD_PATH", record);
    var diag: std.Io.Writer.Allocating = .init(a);
    defer diag.deinit();
    for ([_][]const u8{ filename, binary }) |selection| {
        var argv = try buildArgv(a, .{ .backend = .codex, .backend_bin = selection }, dir, null, "prompt.md");
        defer argv.deinit();
        var result = try executeTurn(.{ .allocator = a, .io = io, .backend = .codex, .argv = argv.items, .environ_map = &env, .loop_id = "fixture", .loop_dir = dir, .prompt = "literal prompt", .diagnostics = &diag.writer });
        defer result.deinit();
        try std.testing.expectEqual(@as(i32, 0), result.exit_code);
        try std.testing.expectEqualStrings("custom wrapper ran", result.last_assistant_text.?);
        const recorded = try std.Io.Dir.cwd().readFileAlloc(io, record, a, .limited(4096));
        defer a.free(recorded);
        try std.testing.expect(std.mem.startsWith(u8, recorded, binary));
        try std.testing.expect(std.mem.indexOf(u8, recorded, "\nexec\n") != null);
    }
    // Resolve relative child PATH entries after changing to the saved worker cwd.
    try tmp.dir.createDir(io, "saved-cwd", .default_dir);
    const saved_cwd = try std.fs.path.join(a, &.{ dir, "saved-cwd" });
    defer a.free(saved_cwd);
    try env.put("PATH", "..:/bin:/usr/bin");
    var relative_argv = try buildArgv(a, .{ .backend = .codex, .backend_bin = filename }, dir, "saved-session", "prompt.md");
    defer relative_argv.deinit();
    const relative_request: TurnRequest = .{ .allocator = a, .io = io, .backend = .codex, .argv = relative_argv.items, .environ_map = &env, .loop_id = "fixture", .loop_dir = dir, .prompt = "resumed prompt", .cwd = .{ .path = saved_cwd }, .diagnostics = &diag.writer };
    var relative_result = try executeTurn(relative_request);
    defer relative_result.deinit();
    try std.testing.expectEqual(@as(i32, 0), relative_result.exit_code);
    const relative_record = try std.Io.Dir.cwd().readFileAlloc(io, record, a, .limited(4096));
    defer a.free(relative_record);
    const relative_prefix = try std.fmt.allocPrint(a, "../{s}\n", .{filename});
    defer a.free(relative_prefix);
    try std.testing.expect(std.mem.startsWith(u8, relative_record, relative_prefix));
    try std.testing.expect(std.mem.indexOf(u8, relative_record, "\nresume\n--json\nsaved-session\n") != null);
    // A changed PATH must be consulted on the next invocation, with no cached fallback.
    try env.put("PATH", "/bin:/usr/bin");
    try std.testing.expectError(error.BackendNotFound, executeTurn(relative_request));
    try tmp.dir.writeFile(io, .{ .sub_path = "not executable", .data = "#!/bin/sh\nexit 0\n" });
    const denied = try std.fs.path.join(a, &.{ dir, "not executable" });
    defer a.free(denied);
    const denied_argv = [_][]const u8{denied};
    try std.testing.expectError(error.AccessDenied, executeTurn(.{ .allocator = a, .io = io, .backend = .codex, .argv = &denied_argv, .environ_map = &env, .loop_id = "fixture", .loop_dir = dir, .prompt = "prompt", .diagnostics = &diag.writer }));
    try std.testing.expect(std.mem.indexOf(u8, diag.written(), denied) != null);
    // Parent PATH contains sh, but child PATH deliberately does not. Never fall back.
    try env.put("PATH", dir);
    const missing_argv = [_][]const u8{"sh"};
    try std.testing.expectError(error.BackendNotFound, executeTurn(.{ .allocator = a, .io = io, .backend = .codex, .argv = &missing_argv, .environ_map = &env, .loop_id = "fixture", .loop_dir = dir, .prompt = "prompt", .diagnostics = &diag.writer }));
}

test "preflight checks selected executable without running it" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(io, a);
    defer a.free(cwd);
    const root = try std.fs.path.resolve(a, &.{ cwd, ".zig-cache/tmp", &tmp.sub_path });
    defer a.free(root);
    const file = try tmp.dir.createFile(io, "verifier wrapper", .{ .permissions = .executable_file });
    try file.writeStreamingAll(io, "#!/bin/sh\ntouch should-not-run\n");
    file.close(io);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("PATH", ".");
    var diagnostics: std.Io.Writer.Allocating = .init(a);
    defer diagnostics.deinit();
    var real: RealBackendRunner = .{};
    var request: PreflightRequest = .{ .allocator = a, .io = io, .config = .{ .backend = .codex, .backend_bin = "verifier wrapper" }, .environ_map = &env, .cwd = root, .diagnostics = &diagnostics.writer };
    try real.runner().preflight(request);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "should-not-run", .{}));
    request.config.backend_bin = "missing verifier";
    try std.testing.expectError(error.FileNotFound, real.runner().preflight(request));
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.written(), "missing verifier") != null);
    try tmp.dir.writeFile(io, .{ .sub_path = "no-execute", .data = "#!/bin/sh\n" });
    request.config.backend_bin = "./no-execute";
    try std.testing.expectError(error.AccessDenied, real.runner().preflight(request));
}

test "sandbox capability table covers initial and resumed argv without approval bypass" {
    const a = std.testing.allocator;
    const policies = [_]options.SandboxPolicy{ .@"read-only", .@"workspace-write", .@"danger-full-access", .@"backend-default" };
    for ([_]BackendKind{ .codex, .droid, .agy }) |kind| {
        for (policies) |policy| {
            for ([_]?[]const u8{ null, "saved-session" }) |session| {
                const config: BackendOptions = .{ .backend = kind, .sandbox = policy };
                if (policy == .@"read-only") {
                    try std.testing.expectError(error.ReadOnlyPreventsCallbacks, buildArgv(a, config, "/loop/store", session, "prompt.md"));
                } else if (kind != .codex and policy != .@"backend-default") {
                    try std.testing.expectError(error.UnsupportedSandboxPolicy, buildArgv(a, config, "/loop/store", session, "prompt.md"));
                } else {
                    var argv = try buildArgv(a, config, "/loop/store", session, "prompt.md");
                    defer argv.deinit();
                    for (argv.items) |arg| {
                        try std.testing.expect(!std.mem.eql(u8, arg, "--dangerously-bypass-approvals-and-sandbox"));
                        try std.testing.expect(!std.mem.eql(u8, arg, "--skip-permissions-unsafe"));
                        try std.testing.expect(!std.mem.eql(u8, arg, "--dangerously-skip-permissions"));
                        try std.testing.expect(!std.mem.eql(u8, arg, "--auto"));
                        try std.testing.expect(!std.mem.eql(u8, arg, "--mode"));
                    }
                    if (policy == .@"backend-default") {
                        for (argv.items) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--sandbox"));
                    } else {
                        try std.testing.expectEqualStrings("--sandbox", argv.items[2]);
                        try std.testing.expectEqualStrings(@tagName(policy), argv.items[3]);
                        if (session != null) {
                            const resume_index = for (argv.items, 0..) |arg, index| {
                                if (std.mem.eql(u8, arg, "resume")) break index;
                            } else unreachable;
                            try std.testing.expect(resume_index > 3);
                        }
                    }
                }
            }
        }
    }
}

test "structured permission choices reject known native conflicts and preserve unrelated flags" {
    const a = std.testing.allocator;
    const cases = [_]struct { kind: BackendKind, args: []const []const u8 }{
        .{ .kind = .codex, .args = &.{ "-s", "danger-full-access" } },
        .{ .kind = .codex, .args = &.{"--sandbox=workspace-write"} },
        .{ .kind = .codex, .args = &.{ "-c", "sandbox_mode=\"danger-full-access\"" } },
        .{ .kind = .codex, .args = &.{"--config=approval_policy=\"never\""} },
        .{ .kind = .codex, .args = &.{"-csandbox_workspace_write.network_access=true"} },
        .{ .kind = .codex, .args = &.{"-c=sandbox_mode=workspace-write"} },
        .{ .kind = .codex, .args = &.{ "-c", "sandbox_workspace_write={network_access=true}" } },
        .{ .kind = .codex, .args = &.{"--full-auto"} },
        .{ .kind = .codex, .args = &.{ "--add-dir", "/extra" } },
        .{ .kind = .droid, .args = &.{"--auto=high"} },
        .{ .kind = .droid, .args = &.{"--skip-permissions-unsafe"} },
        .{ .kind = .agy, .args = &.{"--sandbox"} },
        .{ .kind = .agy, .args = &.{"--mode=auto"} },
        .{ .kind = .agy, .args = &.{"--dangerously-skip-permissions"} },
    };
    for (cases) |case| {
        try std.testing.expectError(error.ConflictingNativePolicy, validatePolicy(.{ .backend = case.kind, .sandbox = .@"backend-default", .extra_args = case.args }, null));
        try std.testing.expectError(error.ConflictingNativePolicy, validatePolicy(.{ .backend = case.kind, .yolo = true, .extra_args = case.args }, null));
        try validatePolicy(.{ .backend = case.kind, .extra_args = case.args }, null);
    }
    try std.testing.expectError(error.ConflictingPolicy, validatePolicy(.{ .backend = .codex, .yolo = true, .sandbox = .@"workspace-write" }, null));
    var safe = try buildArgv(a, .{ .backend = .codex, .sandbox = .@"workspace-write", .extra_args = &.{ "-c", "model_reasoning_effort=\"high\"" } }, "/loop", null, "prompt");
    defer safe.deinit();
    var diagnostic: std.Io.Writer.Allocating = .init(a);
    defer diagnostic.deinit();
    try std.testing.expectError(error.ReadOnlyPreventsCallbacks, validatePolicy(.{ .backend = .codex, .sandbox = .@"read-only" }, &diagnostic.writer));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.written(), "callbacks") != null);
    try std.testing.expectError(error.UnsupportedSandboxPolicy, validatePolicy(.{ .backend = .droid, .sandbox = .@"danger-full-access" }, &diagnostic.writer));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.written(), "Supported sandbox choices: backend-default") != null);
}

test "legacy yolo passthrough remains unchanged until an explicit policy override" {
    const a = std.testing.allocator;
    var legacy = try buildArgv(a, .{ .backend = .codex, .yolo = true, .legacy_policy_passthrough = true, .extra_args = &.{ "-s", "workspace-write" } }, "/loop", "saved", "prompt");
    defer legacy.deinit();
    try expectArgv(&legacy, &.{ "codex", "exec", "--dangerously-bypass-approvals-and-sandbox", "-s", "workspace-write", "resume", "--json", "saved", "-" });
    try std.testing.expectError(error.ConflictingNativePolicy, buildArgv(a, .{ .backend = .codex, .yolo = true, .extra_args = &.{ "-s", "workspace-write" } }, "/loop", "saved", "prompt"));
    try std.testing.expectError(error.ConflictingNativePolicy, buildArgv(a, .{ .backend = .codex, .sandbox = .@"workspace-write", .legacy_policy_passthrough = true, .extra_args = &.{ "-s", "workspace-write" } }, "/loop", "saved", "prompt"));
}
