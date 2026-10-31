const std = @import("std");
const backend = @import("loop_backend.zig");
const options = @import("loop_options.zig");
const prompts = @import("loop_prompts.zig");
const store_mod = @import("loop_store.zig");
const stream = @import("loop_stream.zig");
const loop_summary = @import("loop_summary.zig");

pub const ExitCode = enum { ok, failure };

pub const Services = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *store_mod.Store,
    parent_environment: *const std.process.Environ.Map,
    runner: backend.BackendRunner,
    stdout: *std.Io.Writer,
    stderr: ?*std.Io.Writer = null,
    clock: ?Clock = null,
    sleeper: ?Sleeper = null,
};

pub const Clock = struct {
    context: *anyopaque,
    nowMillisecondsFn: *const fn (context: *anyopaque) u64,

    fn nowMilliseconds(self: Clock) u64 {
        return self.nowMillisecondsFn(self.context);
    }
};

pub const Sleeper = struct {
    context: *anyopaque,
    sleepFn: *const fn (context: *anyopaque, io: std.Io, milliseconds: u64) anyerror!void,

    fn sleep(self: Sleeper, io: std.Io, milliseconds: u64) anyerror!void {
        return self.sleepFn(self.context, io, milliseconds);
    }
};

var active_child_pid: std.atomic.Value(std.posix.pid_t) = .init(-1);
var caught_signal: std.atomic.Value(c_int) = .init(0);
extern "c" fn kill(pid: std.posix.pid_t, signal_number: c_int) c_int;

fn loopSignalHandler(signal: std.posix.SIG) callconv(.c) void {
    caught_signal.store(@intCast(@intFromEnum(signal)), .release);
    const pid = active_child_pid.load(.acquire);
    if (pid > 0) _ = kill(pid, @intCast(@intFromEnum(signal)));
}

const SignalGuard = struct {
    old_interrupt: std.posix.Sigaction,
    old_terminate: std.posix.Sigaction,

    fn install() SignalGuard {
        caught_signal.store(0, .release);
        active_child_pid.store(-1, .release);
        const handler: std.posix.Sigaction = .{
            .handler = .{ .handler = loopSignalHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var old_interrupt: std.posix.Sigaction = undefined;
        var old_terminate: std.posix.Sigaction = undefined;
        std.posix.sigaction(std.posix.SIG.INT, &handler, &old_interrupt);
        std.posix.sigaction(std.posix.SIG.TERM, &handler, &old_terminate);
        return .{ .old_interrupt = old_interrupt, .old_terminate = old_terminate };
    }

    fn deinit(self: *SignalGuard) void {
        active_child_pid.store(-1, .release);
        std.posix.sigaction(std.posix.SIG.INT, &self.old_interrupt, null);
        std.posix.sigaction(std.posix.SIG.TERM, &self.old_terminate, null);
    }
};

fn childIdChanged(_: ?*anyopaque, child_id: ?std.process.Child.Id) void {
    if (child_id) |pid| active_child_pid.store(@intCast(pid), .release) else active_child_pid.store(-1, .release);
}

fn signalWasCaught() bool {
    return caught_signal.load(.acquire) != 0;
}

pub fn run(services: Services, run_options: options.RunOptions) !ExitCode {
    const allocator = services.allocator;
    const cwd = try std.process.currentPathAlloc(services.io, allocator);
    defer allocator.free(cwd);
    const id = try services.store.generateLoopId();
    defer allocator.free(id);
    const now = nowMilliseconds(services);
    const state: store_mod.LoopState = .{
        .schema_version = 2,
        .id = id,
        .status = .active,
        .backend = run_options.backend,
        .backend_bin = run_options.backend_bin,
        .verifier_backend = run_options.verifier,
        .verifier_override_present = run_options.verifier_explicit,
        .verifier_options = run_options.verifier_options,
        .separate_verifier_settings = true,
        .verify_enabled = run_options.verify_enabled,
        .model = run_options.model,
        .output_mode = run_options.output_mode,
        .yolo = run_options.yolo,
        .sandbox = run_options.sandbox,
        .policy_validation_enabled = true,
        .cwd = cwd,
        .objective = run_options.prompt,
        .started_at_ms = now,
        .updated_at_ms = now,
        .max_turns = run_options.max_turns,
        .token_budget = run_options.token_budget,
        .timeout_seconds = run_options.timeout_seconds,
        .extra_args = run_options.extra_backend_args,
    };
    preflightRoles(services, state) catch return .failure;
    try services.store.createLoop(state);

    return runExisting(services, run_options, id);
}

pub fn resumeLoop(services: Services, id: []const u8, objective: ?[]const u8) !ExitCode {
    return resumeLoopWithPolicy(services, id, objective, null, false);
}

pub fn resumeLoopWithPolicy(services: Services, id: []const u8, objective: ?[]const u8, sandbox: ?options.SandboxPolicy, yolo: bool) !ExitCode {
    const allocator = services.allocator;
    var loaded = try services.store.loadState(id);
    defer loaded.deinit();
    var state = loaded.value;
    if (state.status == .complete or state.status == .blocked) return error.LoopCannotResume;
    if (sandbox != null and yolo) {
        if (services.stderr) |writer| try writer.writeAll("Sandbox and yolo cannot be selected together.\n");
        return .failure;
    }
    if (sandbox != null or yolo) state.policy_validation_enabled = true;
    if (sandbox) |policy| {
        state.sandbox = policy;
        state.yolo = false;
    } else if (yolo) {
        state.sandbox = null;
        state.yolo = true;
    }

    const cwd = try std.process.currentPathAlloc(services.io, allocator);
    defer allocator.free(cwd);
    if (!std.mem.eql(u8, cwd, state.cwd)) {
        if (services.stderr) |stderr| {
            try stderr.print("Warning: resuming loop {s} from {s}; backend will restore saved working directory {s}.\n", .{ id, cwd, state.cwd });
            try stderr.flush();
        }
    }
    preflightRoles(services, state) catch return .failure;
    state.status = .active;
    // Upgrade only on resume, when state is already being changed and saved.
    // Listing and inspection leave legacy files byte-for-byte untouched.
    if (state.schema_version < 2) state.schema_version = 2;
    if (objective) |new_objective| {
        state.objective = new_objective;
        state.blocked_strikes = 0;
        state.objective_update_pending = true;
    }
    state.updated_at_ms = nowMilliseconds(services);
    try services.store.saveState(state);
    const run_options = runOptionsFromState(state);
    return runExisting(services, run_options, id);
}

fn runOptionsFromState(state: store_mod.LoopState) options.RunOptions {
    return .{
        .backend = state.backend,
        .backend_bin = state.backend_bin,
        .verifier = state.verifier_backend,
        .verifier_explicit = state.verifier_override_present or state.verifier_backend != null,
        .verifier_options = state.verifier_options,
        .verify_enabled = state.verify_enabled,
        .model = state.model,
        .yolo = state.yolo,
        .sandbox = state.sandbox,
        .max_turns = state.max_turns,
        .token_budget = state.token_budget,
        .timeout_seconds = state.timeout_seconds,
        .output_mode = state.output_mode,
        .prompt = state.objective,
        .extra_backend_args = state.extra_args,
    };
}

/// Resolve role settings from the current snapshot; inherited values track worker edits.
pub fn roleSettings(state: store_mod.LoopState, role: store_mod.TurnRole) backend.BackendOptions {
    const selected = if (role == .verifier) state.verifier_backend orelse state.backend else state.backend;
    const same_backend = selected == state.backend;
    const worker: backend.BackendOptions = .{ .backend = selected, .backend_bin = if (same_backend) state.backend_bin else null, .model = state.model, .yolo = state.yolo, .sandbox = state.sandbox, .legacy_policy_passthrough = !state.policy_validation_enabled, .extra_args = state.extra_args };
    if (role == .worker) return worker;
    const verifier = state.verifier_options;
    return .{
        .backend = selected,
        .backend_bin = if (verifier.backend_bin_explicit) verifier.backend_bin else if (same_backend) state.backend_bin else null,
        .model = if (verifier.model_explicit) verifier.model else if (same_backend or !state.separate_verifier_settings) state.model else null,
        .yolo = state.yolo,
        .sandbox = state.sandbox,
        .legacy_policy_passthrough = !state.policy_validation_enabled,
        .extra_args = if (verifier.args_explicit or state.separate_verifier_settings) verifier.args else state.extra_args,
    };
}

fn preflightRoles(services: Services, state: store_mod.LoopState) !void {
    // Reject incompatible settings for either role before probing any executable.
    for ([_]store_mod.TurnRole{ .worker, .verifier }) |role| {
        if (role == .verifier and !state.verify_enabled) continue;
        backend.validatePolicy(roleSettings(state, role), services.stderr) catch |err| {
            if (services.stderr) |writer| try writer.print("Cannot start {s}: {s}\n", .{ @tagName(role), @errorName(err) });
            return err;
        };
    }
    var environment = try backend.buildChildEnvironment(services.allocator, services.io, services.parent_environment, state.id);
    defer environment.deinit();
    for ([_]store_mod.TurnRole{ .worker, .verifier }) |role| {
        if (role == .verifier and !state.verify_enabled) continue;
        services.runner.preflight(.{
            .allocator = services.allocator,
            .io = services.io,
            .config = roleSettings(state, role),
            .environ_map = &environment.map,
            .cwd = state.cwd,
            .diagnostics = services.stderr,
        }) catch |err| {
            if (services.stderr) |writer| try writer.print("Cannot start {s}: {s}\n", .{ @tagName(role), @errorName(err) });
            return err;
        };
    }
}

test "resume options come only from captured snapshot, including legacy shared verifier settings" {
    const state: store_mod.LoopState = .{
        .schema_version = 1,
        .id = "legacy-0001",
        .backend = .codex,
        .verifier_backend = .agy,
        .model = "captured-model",
        .cwd = "/saved/project",
        .objective = "captured objective",
        .started_at_ms = 1,
        .updated_at_ms = 2,
        .max_turns = 7,
        .token_budget = 900,
        .timeout_seconds = 60,
        .extra_args = &.{ "--legacy", "value" },
    };
    const options_from_state = runOptionsFromState(state);
    try std.testing.expectEqual(options.BackendKind.codex, options_from_state.backend);
    try std.testing.expectEqual(options.BackendKind.agy, options_from_state.verifier.?);
    try std.testing.expectEqualStrings("captured-model", options_from_state.model.?);
    try std.testing.expectEqualStrings("captured objective", options_from_state.prompt);
    try std.testing.expectEqual(@as(u32, 7), options_from_state.max_turns.?);
    try std.testing.expectEqual(@as(u64, 900), options_from_state.token_budget.?);
    try std.testing.expectEqual(@as(u64, 60), options_from_state.timeout_seconds.?);
    try std.testing.expectEqualStrings("--legacy", options_from_state.extra_backend_args[0]);
}

fn runExisting(services: Services, run_options: options.RunOptions, id: []const u8) !ExitCode {
    const allocator = services.allocator;
    var signal_guard = SignalGuard.install();
    defer signal_guard.deinit();
    var initial_state = try services.store.loadState(id);
    defer initial_state.deinit();
    const elapsed_base_seconds = (nowMilliseconds(services) -| initial_state.value.started_at_ms) / 1000;
    var presenter = stream.Presenter.init(allocator, services.stdout, run_options.output_mode, id, run_options.backend);
    presenter.configureStatus(services.io, run_options.model, run_options.max_turns, elapsed_base_seconds);
    defer presenter.deinit();
    try presenter.loopStarted();

    var verifier_unconfirmed_attempts: u8 = 0;
    var budget_wrapup_done = false;
    while (true) {
        var loaded = try services.store.loadState(id);
        const current = loaded.value;
        defer loaded.deinit();

        switch (current.status) {
            .complete => {
                if (budget_wrapup_done and !current.verify_enabled) {
                    var limited = current;
                    return finishBudgetLimited(services, &presenter, &limited, .unverified_completion);
                }
                const outcome = current.completion_summary orelse "Loop completed and verification passed.";
                try finishLoop(services, &presenter, current.status, current.turns_completed, current.tokens_used, outcome);
                return .ok;
            },
            .blocked => {
                const outcome = current.last_blocker_summary orelse "Loop reached the blocker limit.";
                try finishLoop(services, &presenter, current.status, current.turns_completed, current.tokens_used, outcome);
                return .failure;
            },
            .paused, .budget_limited => {
                try finishLoop(services, &presenter, current.status, current.turns_completed, current.tokens_used, "Loop is not active.");
                return .failure;
            },
            .active, .verifying => {},
        }

        if (current.status == .active and current.turns_completed > 0 and budget_wrapup_done) {
            var limited = current;
            return finishBudgetLimited(services, &presenter, &limited, .wrapup_recorded);
        }
        if (signalWasCaught()) return pauseLoop(services, &presenter, id, "Loop paused by SIGINT or SIGTERM.");
        const budget_reason = if (current.status == .active and current.turns_completed > 0)
            reachedBudget(services, current)
        else
            null;
        const is_budget_wrapup = budget_reason != null and !budget_wrapup_done;
        if (is_budget_wrapup) budget_wrapup_done = true;

        const role: store_mod.TurnRole = if (current.status == .verifying) .verifier else .worker;
        const turn_number = current.turns_completed +| 1;
        const execution = roleSettings(current, role);
        const turn_backend = execution.backend;
        const session_id: ?[]const u8 = if (role == .verifier) null else current.worker_session_id;
        if (role == .worker and current.turns_completed > 0 and session_id == null) {
            try services.stdout.print("Loop {s} cannot continue: backend did not provide a worker session ID.\n", .{id});
            try services.stdout.flush();
            return .failure;
        }

        const prompt_kind: prompts.PromptKind = if (role == .verifier)
            .verifier
        else if (current.objective_update_pending)
            .objective_updated
        else if (is_budget_wrapup)
            .budget_limit
        else if (current.turns_completed == 0)
            .initial
        else
            .continuation;
        const prompt = try prompts.renderPrompt(allocator, prompt_kind, promptContext(services, current, turn_number));
        defer allocator.free(prompt);

        // A verifier rejection is injected once into the next worker continuation.
        if (role == .worker and current.last_verifier_feedback != null) {
            var updated = current;
            updated.last_verifier_feedback = null;
            updated.updated_at_ms = nowMilliseconds(services);
            try services.store.saveState(updated);
        }

        const loop_dir = try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ services.store.root, std.Io.Dir.path.sep, id });
        defer allocator.free(loop_dir);
        const prompt_file = try std.fmt.allocPrint(allocator, "{s}{c}current_prompt.md", .{ loop_dir, std.Io.Dir.path.sep });
        defer allocator.free(prompt_file);
        var argv = try backend.buildArgv(allocator, execution, loop_dir, session_id, prompt_file);
        defer argv.deinit();
        var child_environment = try backend.buildChildEnvironment(allocator, services.io, services.parent_environment, id);
        defer child_environment.deinit();

        const started_ms = nowMilliseconds(services);
        try presenter.configureExecution(role, execution.backend, execution.model);
        try presenter.turnStarted(turn_number, role, current.tokens_used);
        var persist_context = PersistSessionContext{ .store = services.store, .loop_id = id };
        var request = backend.TurnRequest{
            .allocator = allocator,
            .io = services.io,
            .backend = turn_backend,
            .argv = argv.items,
            .environ_map = &child_environment.map,
            .loop_id = id,
            .loop_dir = loop_dir,
            .prompt = prompt,
            .cwd = .{ .path = current.cwd },
            .event_context = &presenter,
            .event_handler = stream.Presenter.eventHandler,
            .child_context = null,
            .on_child_id = childIdChanged,
            .diagnostics = services.stderr,
        };
        if (role == .worker) {
            request.session_context = &persist_context;
            request.on_session_id = PersistSessionContext.persist;
        }
        const retry_result = runWithRetries(services, request) catch |err| {
            if (signalWasCaught()) return pauseLoop(services, &presenter, id, "Loop paused by SIGINT or SIGTERM.");
            if (is_budget_wrapup) {
                var limited = current;
                return finishBudgetLimited(services, &presenter, &limited, .wrapup_failed);
            }
            try services.stdout.print("Loop {s} backend turn failed: {s}\n", .{ id, @errorName(err) });
            try services.stdout.flush();
            return .failure;
        };
        if (retry_result.interrupted and retry_result.result == null) {
            return pauseLoop(services, &presenter, id, "Loop paused by SIGINT or SIGTERM during retry backoff.");
        }
        var result = retry_result.result.?;
        defer result.deinit();
        try presenter.checkError();
        const elapsed_ms = nowMilliseconds(services) -| started_ms;

        var after_turn_parsed = try services.store.loadState(id);
        defer after_turn_parsed.deinit();
        var after_turn = after_turn_parsed.value;
        const previous_status = current.status;
        const blocked_strikes_before = current.blocked_strikes;
        after_turn.turns_completed +|= 1;
        after_turn.tokens_used +|= result.tokens_used;
        after_turn.updated_at_ms = nowMilliseconds(services);
        if (role == .worker) after_turn.objective_update_pending = false;

        if (role == .worker and after_turn.status == .active) {
            if (after_turn.blocked_strikes == blocked_strikes_before) {
                after_turn.blocked_strikes = 0;
                after_turn.last_blocker_summary = null;
            }
        }
        const wrapup_claimed_unverified_completion = is_budget_wrapup and role == .worker and after_turn.status == .complete and !after_turn.verify_enabled;
        if (is_budget_wrapup and role == .worker and after_turn.status != .verifying and
            !(after_turn.status == .complete and after_turn.verify_enabled))
        {
            after_turn.status = .budget_limited;
        }

        const verifier_exited_without_verdict = role == .verifier and after_turn.status == .verifying and result.exit_code != 0 and !result.was_interrupted;
        const interrupted = retry_result.interrupted or result.was_interrupted;
        if ((result.exit_code != 0 or interrupted or retry_result.exhausted) and !verifier_exited_without_verdict) {
            const summary = if (interrupted)
                "Loop paused by SIGINT or SIGTERM."
            else if (after_turn.status == .blocked)
                after_turn.last_blocker_summary orelse "Loop reached the blocker limit."
            else if (result.stderr_tail.len > 0)
                result.stderr_tail
            else
                "backend exited unsuccessfully";
            if (interrupted or retry_result.exhausted) after_turn.status = .paused;
            try services.store.appendTurnLog(id, .{
                .turn = turn_number,
                .role = role,
                .backend = turn_backend,
                .session_id = if (role == .worker) after_turn.worker_session_id else result.session_id,
                .tokens_delta = result.tokens_used,
                .duration_ms = elapsed_ms,
                .outcome = .@"error",
                .summary = summary,
            });
            try services.store.saveState(after_turn);
            if (after_turn.status != previous_status) try presenter.statusChanged(previous_status, after_turn.status);
            try presenter.turnCompleted(after_turn.status, result.tokens_used, elapsed_ms);
            if (interrupted or retry_result.exhausted) return pauseLoop(services, &presenter, id, summary);
            if (is_budget_wrapup and role == .worker and after_turn.status != .blocked) {
                return finishBudgetLimited(services, &presenter, &after_turn, .wrapup_failed);
            }
            try finishLoop(services, &presenter, after_turn.status, after_turn.turns_completed, after_turn.tokens_used, summary);
            return .failure;
        }

        const outcome = if (role == .worker and after_turn.blocked_strikes > blocked_strikes_before)
            store_mod.TurnOutcome.blocked
        else
            turnOutcome(role, after_turn.status);
        try services.store.appendTurnLog(id, .{
            .turn = turn_number,
            .role = role,
            .backend = turn_backend,
            .session_id = if (role == .worker) after_turn.worker_session_id else result.session_id,
            .tokens_delta = result.tokens_used,
            .duration_ms = elapsed_ms,
            .outcome = outcome,
            .summary = result.last_assistant_text orelse "",
        });
        try services.store.saveState(after_turn);
        if (after_turn.status != previous_status) try presenter.statusChanged(previous_status, after_turn.status);
        try presenter.turnCompleted(after_turn.status, result.tokens_used, elapsed_ms);
        if (is_budget_wrapup and after_turn.status == .budget_limited) {
            const reason: BudgetFinish = if (wrapup_claimed_unverified_completion) .unverified_completion else .wrapup_recorded;
            return finishBudgetLimited(services, &presenter, &after_turn, reason);
        }
        if (role == .verifier) {
            if (after_turn.status == .complete) continue;
            if (after_turn.status == .active) {
                verifier_unconfirmed_attempts = 0;
                continue;
            }
            if (after_turn.status == .verifying) {
                verifier_unconfirmed_attempts += 1;
                if (verifier_unconfirmed_attempts < 2) continue;
                var retry_state_parsed = try services.store.loadState(id);
                defer retry_state_parsed.deinit();
                var retry_state = retry_state_parsed.value;
                retry_state.status = .active;
                retry_state.blocked_strikes = 0;
                retry_state.last_verifier_feedback = "Verifier exited without calling 'matcha loop verify'. Retry the verifier or address its findings, then report completion again.";
                retry_state.updated_at_ms = nowMilliseconds(services);
                try services.store.saveState(retry_state);
                try presenter.statusChanged(.verifying, .active);
                verifier_unconfirmed_attempts = 0;
                continue;
            }
        } else if (after_turn.status == .verifying) {
            verifier_unconfirmed_attempts = 0;
        }
    }
}

const RetryRun = struct {
    result: ?backend.TurnExecutionResult = null,
    exhausted: bool = false,
    interrupted: bool = false,
};

fn runWithRetries(services: Services, request: backend.TurnRequest) !RetryRun {
    const delays_ms = [_]u64{ 5000, 15000, 45000 };
    var retry_index: usize = 0;
    while (true) {
        if (signalWasCaught()) return .{ .interrupted = true };
        var result = try services.runner.runTurn(request);
        if (result.exit_code == 0 and !result.was_interrupted) return .{ .result = result };
        if (result.was_interrupted or signalWasCaught()) return .{ .result = result, .interrupted = true };
        if (retry_index == delays_ms.len) return .{ .result = result, .exhausted = true };

        result.deinit();
        const delay_ms = delays_ms[retry_index];
        retry_index += 1;
        if (services.sleeper) |sleeper| {
            sleeper.sleep(services.io, delay_ms) catch |err| {
                if (signalWasCaught()) return .{ .interrupted = true };
                return err;
            };
        } else {
            var remaining_ms = delay_ms;
            while (remaining_ms > 0 and !signalWasCaught()) {
                const slice_ms = @min(remaining_ms, 100);
                const duration: std.Io.Clock.Duration = .{
                    .raw = .{ .nanoseconds = @as(i96, @intCast(slice_ms)) * std.time.ns_per_ms },
                    .clock = .awake,
                };
                duration.sleep(services.io) catch |err| {
                    if (signalWasCaught()) return .{ .interrupted = true };
                    return err;
                };
                remaining_ms -= slice_ms;
            }
        }
        if (signalWasCaught()) return .{ .interrupted = true };
    }
}

fn pauseLoop(services: Services, presenter: *stream.Presenter, id: []const u8, reason: []const u8) !ExitCode {
    var parsed = try services.store.loadState(id);
    defer parsed.deinit();
    var state = parsed.value;
    if (state.status == .complete) {
        try finishLoop(services, presenter, state.status, state.turns_completed, state.tokens_used, state.completion_summary orelse "Loop completed.");
        return .ok;
    }
    const previous = state.status;
    state.status = .paused;
    state.updated_at_ms = nowMilliseconds(services);
    try services.store.saveState(state);
    if (previous != .paused) try presenter.statusChanged(previous, .paused);

    const resume_hint = try std.fmt.allocPrint(services.allocator, "Resume: matcha loop resume {s}", .{id});
    defer services.allocator.free(resume_hint);
    try services.stdout.writeAll(reason);
    try services.stdout.writeByte('\n');
    try services.stdout.print("{s}\n", .{resume_hint});
    var outcome = std.Io.Writer.Allocating.init(services.allocator);
    defer outcome.deinit();
    try outcome.writer.print("{s}. {s}", .{ reason, resume_hint });
    if (state.worker_session_id) |session_id| {
        const native = try backend.formatNativeResumeCommand(services.allocator, state.backend, state.backend_bin, session_id);
        defer services.allocator.free(native);
        try services.stdout.print("Attach: {s}\n", .{native});
        try outcome.writer.print(". Attach: {s}", .{native});
    }
    try services.stdout.flush();
    try finishLoop(services, presenter, .paused, state.turns_completed, state.tokens_used, outcome.written());
    return .failure;
}

fn finishLoop(services: Services, presenter: *stream.Presenter, status: store_mod.LoopStatus, turns: u32, tokens: u64, outcome: []const u8) !void {
    var state = try services.store.loadState(presenter.loop_id);
    defer state.deinit();
    const history = services.store.readRecentTurnLog(presenter.loop_id, 100) catch try services.allocator.dupe(u8, "");
    defer services.allocator.free(history);
    const summary = try loop_summary.render(services.allocator, state.value, history);
    defer services.allocator.free(summary);
    presenter.final_summary = summary;
    defer presenter.final_summary = null;
    try presenter.loopFinished(status, turns, tokens, outcome);
}

fn nowMilliseconds(services: Services) u64 {
    if (services.clock) |clock| return clock.nowMilliseconds();
    return @intCast(@max(0, std.Io.Clock.real.now(services.io).toMilliseconds()));
}

fn reachedBudget(services: Services, state: store_mod.LoopState) ?BudgetReason {
    if (state.max_turns) |limit| if (state.turns_completed >= limit) return .max_turns;
    if (state.token_budget) |limit| if (state.tokens_used >= limit) return .token_budget;
    if (state.timeout_seconds) |limit| {
        const elapsed_ms = nowMilliseconds(services) -| state.started_at_ms;
        if (elapsed_ms / 1000 >= limit) return .timeout;
    }
    return null;
}

fn promptContext(services: Services, state: store_mod.LoopState, turn_number: u32) prompts.PromptContext {
    const current_ms = nowMilliseconds(services);
    return .{
        .objective = state.objective,
        .loop_id = state.id,
        .turn_number = turn_number,
        .tokens_used = state.tokens_used,
        .token_budget = state.token_budget,
        .max_turns = state.max_turns,
        .elapsed_seconds = (current_ms -| state.started_at_ms) / 1000,
        .timeout_seconds = state.timeout_seconds,
        .blocked_strikes = state.blocked_strikes,
        .last_blocker_summary = state.last_blocker_summary,
        .last_verifier_feedback = state.last_verifier_feedback,
        .worker_completion_summary = state.completion_summary,
    };
}

const BudgetReason = enum { max_turns, token_budget, timeout };
const BudgetFinish = enum { wrapup_recorded, wrapup_failed, unverified_completion };

fn finishBudgetLimited(
    services: Services,
    presenter: *stream.Presenter,
    state: *store_mod.LoopState,
    reason: BudgetFinish,
) !ExitCode {
    const previous = state.status;
    state.status = .budget_limited;
    state.updated_at_ms = nowMilliseconds(services);
    try services.store.saveState(state.*);
    if (previous != state.status) try presenter.statusChanged(previous, state.status);
    const outcome = switch (reason) {
        .wrapup_recorded => "Budget reached; wrap-up recorded.",
        .wrapup_failed => "Budget reached; wrap-up turn failed.",
        .unverified_completion => "Budget reached; completion was not independently verified.",
    };
    const elapsed_seconds = (nowMilliseconds(services) -| state.started_at_ms) / 1000;
    const summary = try std.fmt.allocPrint(services.allocator, "{s} Turns: {d}. Tokens: {d}. Elapsed: {d}s. Resume with: matcha loop resume {s}", .{
        outcome,
        state.turns_completed,
        state.tokens_used,
        elapsed_seconds,
        state.id,
    });
    defer services.allocator.free(summary);
    try finishLoop(services, presenter, state.status, state.turns_completed, state.tokens_used, summary);
    return .failure;
}

fn turnOutcome(role: store_mod.TurnRole, status: store_mod.LoopStatus) store_mod.TurnOutcome {
    if (role == .verifier) return if (status == .complete) .verifier_pass else if (status == .active) .verifier_fail else .@"error";
    return switch (status) {
        .active => .continued,
        .verifying, .complete => .complete,
        .blocked => .blocked,
        .paused, .budget_limited => .@"error",
    };
}

const PersistSessionContext = struct {
    store: *store_mod.Store,
    loop_id: []const u8,

    fn persist(context: ?*anyopaque, session_id: []const u8) anyerror!void {
        const self: *PersistSessionContext = @ptrCast(@alignCast(context.?));
        var parsed = try self.store.loadState(self.loop_id);
        defer parsed.deinit();
        var state = parsed.value;
        state.worker_session_id = session_id;
        state.updated_at_ms = @intCast(@max(0, std.Io.Clock.real.now(self.store.io).toMilliseconds()));
        try self.store.saveState(state);
    }
};

test "worker continuation, independent verifier rejection, repair, and pass" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    var store = try store_mod.Store.init(allocator, std.testing.io, root);
    defer store.deinit();
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("PATH", "/bin:/usr/bin");
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var fake = FakeRunner{ .store = &store, .script = &.{
        .worker_progress,
        .worker_complete,
        .verifier_reject,
        .worker_repaired,
        .verifier_pass,
    } };
    defer fake.deinit(allocator);
    const exit_code = try run(.{
        .allocator = allocator,
        .io = std.testing.io,
        .store = &store,
        .parent_environment = &environment,
        .runner = fake.runner(),
        .stdout = &output.writer,
    }, .{
        .backend = .codex,
        .verifier = .agy,
        .prompt = "Implement the feature and verify it.",
    });
    try std.testing.expectEqual(ExitCode.ok, exit_code);
    try std.testing.expectEqual(@as(usize, 5), fake.calls.items.len);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\nSummary\nfake progress\n") != null);
    for (fake.calls.items) |call| try std.testing.expect(std.mem.indexOf(u8, call.prompt, "soft wrap-up turn") == null);
    try expectFakeCall(&fake.calls.items[0], .codex, false, "Implement the feature");
    try expectFakeCall(&fake.calls.items[1], .codex, true, "Implement the feature");
    try expectFakeCall(&fake.calls.items[2], .agy, false, "Implement the feature");
    try expectFakeCall(&fake.calls.items[3], .codex, true, "missing edge test");
    try expectFakeCall(&fake.calls.items[4], .agy, false, "Implement the feature");
    try std.testing.expect(fake.calls.items[2].session_id_absent);
    try std.testing.expect(fake.calls.items[4].session_id_absent);
    const final_id = try store.resolveLatestLoopId();
    defer allocator.free(final_id.?);
    var final_state = try store.loadState(final_id.?);
    defer final_state.deinit();
    try std.testing.expectEqual(store_mod.LoopStatus.complete, final_state.value.status);
    try std.testing.expectEqualStrings("All requested checks pass.", final_state.value.completion_summary.?);
    try std.testing.expectEqualStrings("worker-session", final_state.value.worker_session_id.?);
    try std.testing.expectEqual(@as(u32, 5), final_state.value.turns_completed);
    try std.testing.expectEqual(@as(u64, 50), final_state.value.tokens_used);
    const log = try store.readRecentTurnLog(final_id.?, 5);
    defer allocator.free(log);
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, log, "\"role\""));
}

test "no-verify completes immediately after worker update" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    var store = try store_mod.Store.init(allocator, std.testing.io, root);
    defer store.deinit();
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var fake = FakeRunner{ .store = &store, .script = &.{.worker_complete} };
    defer fake.deinit(allocator);
    const exit_code = try run(.{
        .allocator = allocator,
        .io = std.testing.io,
        .store = &store,
        .parent_environment = &environment,
        .runner = fake.runner(),
        .stdout = &output.writer,
    }, .{ .backend = .codex, .verify_enabled = false, .prompt = "Do it." });
    try std.testing.expectEqual(ExitCode.ok, exit_code);
    try std.testing.expectEqual(@as(usize, 1), fake.calls.items.len);
    try std.testing.expect(!fake.calls.items[0].is_verifier);
    const id = try store.resolveLatestLoopId();
    defer allocator.free(id.?);
    var state = try store.loadState(id.?);
    defer state.deinit();
    try std.testing.expectEqual(store_mod.LoopStatus.complete, state.value.status);
}

test "verifier without a verdict retries once then feeds worker" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    var store = try store_mod.Store.init(allocator, std.testing.io, root);
    defer store.deinit();
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var fake = FakeRunner{ .store = &store, .script = &.{
        .worker_complete,
        .verifier_no_verdict,
        .verifier_no_verdict,
        .worker_repaired,
        .verifier_pass,
    } };
    defer fake.deinit(allocator);
    const exit_code = try run(.{
        .allocator = allocator,
        .io = std.testing.io,
        .store = &store,
        .parent_environment = &environment,
        .runner = fake.runner(),
        .stdout = &output.writer,
    }, .{ .backend = .codex, .verifier = .agy, .prompt = "Prove the change." });
    try std.testing.expectEqual(ExitCode.ok, exit_code);
    try std.testing.expectEqual(@as(usize, 5), fake.calls.items.len);
    try std.testing.expect(fake.calls.items[1].session_id_absent);
    try std.testing.expect(fake.calls.items[2].session_id_absent);
    try std.testing.expect(std.mem.indexOf(u8, fake.calls.items[3].prompt, "without calling 'matcha loop verify'") != null);
}

test "blocker strikes count only consecutive reports" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    var store = try store_mod.Store.init(allocator, std.testing.io, root);
    defer store.deinit();
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var fake = FakeRunner{ .store = &store, .script = &.{
        .worker_blocked,
        .worker_progress,
        .worker_blocked,
        .worker_blocked,
        .worker_progress,
        .worker_complete,
    } };
    defer fake.deinit(allocator);
    const exit_code = try run(.{
        .allocator = allocator,
        .io = std.testing.io,
        .store = &store,
        .parent_environment = &environment,
        .runner = fake.runner(),
        .stdout = &output.writer,
    }, .{ .backend = .codex, .verify_enabled = false, .prompt = "Do it." });
    try std.testing.expectEqual(ExitCode.ok, exit_code);
    try std.testing.expectEqual(@as(usize, 6), fake.calls.items.len);
    const id = try store.resolveLatestLoopId();
    defer allocator.free(id.?);
    var state = try store.loadState(id.?);
    defer state.deinit();
    try std.testing.expectEqual(store_mod.LoopStatus.complete, state.value.status);
    try std.testing.expectEqual(@as(u8, 0), state.value.blocked_strikes);
}

test "three consecutive blocker reports stop the loop" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    var store = try store_mod.Store.init(allocator, std.testing.io, root);
    defer store.deinit();
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var fake = FakeRunner{ .store = &store, .script = &.{ .worker_blocked, .worker_blocked, .worker_blocked } };
    defer fake.deinit(allocator);
    const exit_code = try run(.{
        .allocator = allocator,
        .io = std.testing.io,
        .store = &store,
        .parent_environment = &environment,
        .runner = fake.runner(),
        .stdout = &output.writer,
    }, .{ .backend = .codex, .verify_enabled = false, .prompt = "Do it." });
    try std.testing.expectEqual(ExitCode.failure, exit_code);
    try std.testing.expectEqual(@as(usize, 3), fake.calls.items.len);
    const id = try store.resolveLatestLoopId();
    defer allocator.free(id.?);
    var state = try store.loadState(id.?);
    defer state.deinit();
    try std.testing.expectEqual(store_mod.LoopStatus.blocked, state.value.status);
    try std.testing.expectEqual(@as(u8, 3), state.value.blocked_strikes);
}

test "max turns runs one budget wrap-up and ends budget-limited" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    var store = try store_mod.Store.init(allocator, std.testing.io, root);
    defer store.deinit();
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var fake = FakeRunner{ .store = &store, .script = &.{ .worker_progress, .worker_progress, .worker_budget_wrapup } };
    defer fake.deinit(allocator);
    const exit_code = try run(.{
        .allocator = allocator,
        .io = std.testing.io,
        .store = &store,
        .parent_environment = &environment,
        .runner = fake.runner(),
        .stdout = &output.writer,
    }, .{ .backend = .codex, .verify_enabled = false, .max_turns = 2, .prompt = "Finish the work." });
    try expectBudgetRun(&store, &fake, output.written(), allocator, exit_code, 3, 30);
}

test "token budget runs one budget wrap-up and ends budget-limited" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    var store = try store_mod.Store.init(allocator, std.testing.io, root);
    defer store.deinit();
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var fake = FakeRunner{ .store = &store, .script = &.{ .worker_progress, .worker_progress, .worker_budget_wrapup }, .tokens_per_turn = 25000 };
    defer fake.deinit(allocator);
    const exit_code = try run(.{
        .allocator = allocator,
        .io = std.testing.io,
        .store = &store,
        .parent_environment = &environment,
        .runner = fake.runner(),
        .stdout = &output.writer,
    }, .{ .backend = .codex, .verify_enabled = false, .token_budget = 50000, .prompt = "Finish the work." });
    try expectBudgetRun(&store, &fake, output.written(), allocator, exit_code, 3, 75000);
}

test "timeout uses the injected clock and runs one budget wrap-up" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    var store = try store_mod.Store.init(allocator, std.testing.io, root);
    defer store.deinit();
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var fake_clock = FakeClock{ .now_ms = 1000 };
    var fake = FakeRunner{
        .store = &store,
        .script = &.{ .worker_progress, .worker_budget_wrapup },
        .clock = &fake_clock,
        .advance_clock_ms = 2000,
    };
    defer fake.deinit(allocator);
    const exit_code = try run(.{
        .allocator = allocator,
        .io = std.testing.io,
        .store = &store,
        .parent_environment = &environment,
        .runner = fake.runner(),
        .stdout = &output.writer,
        .clock = fake_clock.reader(),
    }, .{ .backend = .codex, .verify_enabled = false, .timeout_seconds = 1, .prompt = "Finish the work." });
    try expectBudgetRun(&store, &fake, output.written(), allocator, exit_code, 2, 20);
}

test "budget wrap-up completion must pass the independent verifier" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    var store = try store_mod.Store.init(allocator, std.testing.io, root);
    defer store.deinit();
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var fake = FakeRunner{ .store = &store, .script = &.{ .worker_progress, .worker_complete, .verifier_pass } };
    defer fake.deinit(allocator);
    const exit_code = try run(.{
        .allocator = allocator,
        .io = std.testing.io,
        .store = &store,
        .parent_environment = &environment,
        .runner = fake.runner(),
        .stdout = &output.writer,
    }, .{ .backend = .codex, .max_turns = 1, .prompt = "Finish the work." });
    try std.testing.expectEqual(ExitCode.ok, exit_code);
    try std.testing.expectEqual(@as(usize, 3), fake.calls.items.len);
    try std.testing.expect(std.mem.indexOf(u8, fake.calls.items[1].prompt, "soft wrap-up turn") != null);
    try std.testing.expect(fake.calls.items[2].session_id_absent);
    const id = try store.resolveLatestLoopId();
    defer allocator.free(id.?);
    var state = try store.loadState(id.?);
    defer state.deinit();
    try std.testing.expectEqual(store_mod.LoopStatus.complete, state.value.status);
}

test "budget wrap-up cannot claim unverified completion when verification is disabled" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    var store = try store_mod.Store.init(allocator, std.testing.io, root);
    defer store.deinit();
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var fake = FakeRunner{ .store = &store, .script = &.{ .worker_progress, .worker_complete } };
    defer fake.deinit(allocator);
    const exit_code = try run(.{
        .allocator = allocator,
        .io = std.testing.io,
        .store = &store,
        .parent_environment = &environment,
        .runner = fake.runner(),
        .stdout = &output.writer,
    }, .{ .backend = .codex, .verify_enabled = false, .max_turns = 1, .prompt = "Finish the work." });
    try std.testing.expectEqual(ExitCode.failure, exit_code);
    const id = try store.resolveLatestLoopId();
    defer allocator.free(id.?);
    var state = try store.loadState(id.?);
    defer state.deinit();
    try std.testing.expectEqual(store_mod.LoopStatus.budget_limited, state.value.status);
}

test "transient backend failure recovers on retry after injectable backoff" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    var store = try store_mod.Store.init(allocator, std.testing.io, root);
    defer store.deinit();
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var sleeper = FakeSleeper{ .allocator = allocator };
    defer sleeper.deinit();
    var fake = FakeRunner{ .store = &store, .script = &.{ .worker_retry_fail, .worker_progress, .worker_complete } };
    defer fake.deinit(allocator);
    const exit_code = try run(.{
        .allocator = allocator,
        .io = std.testing.io,
        .store = &store,
        .parent_environment = &environment,
        .runner = fake.runner(),
        .stdout = &output.writer,
        .sleeper = sleeper.sleeper(),
    }, .{ .backend = .codex, .verify_enabled = false, .prompt = "Recover from a transient error." });
    try std.testing.expectEqual(ExitCode.ok, exit_code);
    try std.testing.expectEqual(@as(usize, 3), fake.calls.items.len);
    try std.testing.expectEqual(@as(usize, 1), sleeper.delays.items.len);
    try std.testing.expectEqual(@as(u64, 5000), sleeper.delays.items[0]);
}

test "three retry delays run before exhausted backend turn pauses with diagnostics" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    var store = try store_mod.Store.init(allocator, std.testing.io, root);
    defer store.deinit();
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var sleeper = FakeSleeper{ .allocator = allocator };
    defer sleeper.deinit();
    var fake = FakeRunner{ .store = &store, .script = &.{ .worker_retry_fail, .worker_retry_fail, .worker_retry_fail, .worker_retry_fail } };
    defer fake.deinit(allocator);
    const exit_code = try run(.{
        .allocator = allocator,
        .io = std.testing.io,
        .store = &store,
        .parent_environment = &environment,
        .runner = fake.runner(),
        .stdout = &output.writer,
        .sleeper = sleeper.sleeper(),
    }, .{ .backend = .codex, .verify_enabled = false, .prompt = "Recover from a transient error." });
    try std.testing.expectEqual(ExitCode.failure, exit_code);
    try std.testing.expectEqual(@as(usize, 4), fake.calls.items.len);
    try std.testing.expectEqualSlices(u64, &.{ 5000, 15000, 45000 }, sleeper.delays.items);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "matcha loop resume") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "codex resume worker-session") != null);
    const id = try store.resolveLatestLoopId();
    defer allocator.free(id.?);
    var state = try store.loadState(id.?);
    defer state.deinit();
    try std.testing.expectEqual(store_mod.LoopStatus.paused, state.value.status);
    const log = try store.readRecentTurnLog(id.?, 1);
    defer allocator.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "transient backend outage") != null);
}

test "interrupted turn pauses and prints both resume commands" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    var store = try store_mod.Store.init(allocator, std.testing.io, root);
    defer store.deinit();
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var sleeper = FakeSleeper{ .allocator = allocator };
    defer sleeper.deinit();
    var fake = FakeRunner{ .store = &store, .script = &.{.worker_interrupted} };
    defer fake.deinit(allocator);
    const exit_code = try run(.{
        .allocator = allocator,
        .io = std.testing.io,
        .store = &store,
        .parent_environment = &environment,
        .runner = fake.runner(),
        .stdout = &output.writer,
        .sleeper = sleeper.sleeper(),
    }, .{ .backend = .droid, .verify_enabled = false, .prompt = "Handle an interrupt." });
    try std.testing.expectEqual(ExitCode.failure, exit_code);
    try std.testing.expectEqual(@as(usize, 0), sleeper.delays.items.len);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Loop paused by SIGINT or SIGTERM.") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "matcha loop resume") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "droid -r worker-session") != null);
    const id = try store.resolveLatestLoopId();
    defer allocator.free(id.?);
    var state = try store.loadState(id.?);
    defer state.deinit();
    try std.testing.expectEqual(store_mod.LoopStatus.paused, state.value.status);
}

fn expectBudgetRun(
    store: *store_mod.Store,
    fake: *const FakeRunner,
    output: []const u8,
    allocator: std.mem.Allocator,
    exit_code: ExitCode,
    expected_turns: u32,
    expected_tokens: u64,
) !void {
    try std.testing.expectEqual(ExitCode.failure, exit_code);
    try std.testing.expectEqual(@as(usize, if (expected_turns == 3) 3 else 2), fake.calls.items.len);
    for (fake.calls.items, 0..) |call, index| {
        const is_wrapup = index + 1 == fake.calls.items.len;
        try std.testing.expectEqual(is_wrapup, std.mem.indexOf(u8, call.prompt, "soft wrap-up turn") != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, output, "matcha loop resume") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Turns:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Tokens:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Elapsed:") != null);
    const id = try store.resolveLatestLoopId();
    defer allocator.free(id.?);
    var state = try store.loadState(id.?);
    defer state.deinit();
    try std.testing.expectEqual(store_mod.LoopStatus.budget_limited, state.value.status);
    try std.testing.expectEqual(expected_turns, state.value.turns_completed);
    try std.testing.expectEqual(expected_tokens, state.value.tokens_used);
}

const FakeStep = enum { worker_progress, worker_complete, verifier_reject, verifier_no_verdict, worker_repaired, verifier_pass, worker_blocked, worker_budget_wrapup, worker_retry_fail, worker_interrupted };

const FakeSleeper = struct {
    allocator: std.mem.Allocator,
    delays: std.ArrayList(u64) = .empty,

    fn sleeper(self: *FakeSleeper) Sleeper {
        return .{ .context = @ptrCast(self), .sleepFn = FakeSleeper.sleep };
    }

    fn deinit(self: *FakeSleeper) void {
        self.delays.deinit(self.allocator);
    }

    fn sleep(context: *anyopaque, _: std.Io, milliseconds: u64) anyerror!void {
        const self: *FakeSleeper = @ptrCast(@alignCast(context));
        try self.delays.append(self.allocator, milliseconds);
    }
};

const FakeClock = struct {
    now_ms: u64,

    fn reader(self: *FakeClock) Clock {
        return .{ .context = @ptrCast(self), .nowMillisecondsFn = FakeClock.now };
    }

    fn now(context: *anyopaque) u64 {
        const self: *FakeClock = @ptrCast(@alignCast(context));
        return self.now_ms;
    }
};

const FakeCall = struct {
    argv_json: []u8,
    executable: []u8,
    backend: backend.BackendKind,
    is_verifier: bool,
    session_id_absent: bool,
    prompt: []u8,

    fn deinit(self: *FakeCall, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt);
        allocator.free(self.executable);
        allocator.free(self.argv_json);
    }
};

const FakeRunner = struct {
    store: *store_mod.Store,
    script: []const FakeStep,
    calls: std.ArrayList(FakeCall) = .empty,
    next_step: usize = 0,
    preflight_calls: std.ArrayList(backend.BackendKind) = .empty,
    fail_second_preflight: bool = false,
    tokens_per_turn: u64 = 10,
    clock: ?*FakeClock = null,
    advance_clock_ms: u64 = 0,

    fn runner(self: *FakeRunner) backend.BackendRunner {
        return .{ .context = @ptrCast(self), .runTurnFn = FakeRunner.runTurn, .preflightFn = FakeRunner.preflight };
    }

    fn preflight(context: *anyopaque, request: backend.PreflightRequest) anyerror!void {
        const self: *FakeRunner = @ptrCast(@alignCast(context));
        try self.preflight_calls.append(self.store.allocator, request.config.backend);
        if (self.fail_second_preflight and self.preflight_calls.items.len == 2) return error.FakeVerifierUnavailable;
    }

    fn deinit(self: *FakeRunner, allocator: std.mem.Allocator) void {
        self.preflight_calls.deinit(allocator);
        for (self.calls.items) |*call| call.deinit(allocator);
        self.calls.deinit(allocator);
    }

    fn runTurn(context: *anyopaque, request: backend.TurnRequest) anyerror!backend.TurnExecutionResult {
        const self: *FakeRunner = @ptrCast(@alignCast(context));
        if (self.next_step >= self.script.len) return error.UnexpectedFakeTurn;
        const step = self.script[self.next_step];
        self.next_step += 1;
        const is_verifier = step == .verifier_reject or step == .verifier_no_verdict or step == .verifier_pass;
        try std.testing.expectEqual(!is_verifier, request.on_session_id != null);
        try std.testing.expectEqualStrings(request.loop_id, request.environ_map.get("MATCHA_LOOP_ID").?);
        if (request.environ_map.get("ROLE_TEST")) |value| try std.testing.expectEqualStrings("shared-value", value);
        const has_session_flag = switch (request.backend) {
            .codex => argvHas(request.argv, "resume"),
            .droid => argvHas(request.argv, "-s"),
            .agy => argvHas(request.argv, "--conversation"),
        };
        {
            const executable = try self.store.allocator.dupe(u8, request.argv[0]);
            errdefer self.store.allocator.free(executable);
            const prompt = try self.store.allocator.dupe(u8, request.prompt);
            errdefer self.store.allocator.free(prompt);
            const argv_json = try std.json.Stringify.valueAlloc(self.store.allocator, request.argv, .{});
            errdefer self.store.allocator.free(argv_json);
            try self.calls.append(self.store.allocator, .{
                .argv_json = argv_json,
                .executable = executable,
                .backend = request.backend,
                .is_verifier = is_verifier,
                .session_id_absent = !has_session_flag,
                .prompt = prompt,
            });
        }

        if (!is_verifier and request.on_session_id != null) {
            const state_parsed = try self.store.loadState(request.loop_id);
            const has_existing_session = state_parsed.value.worker_session_id != null;
            state_parsed.deinit();
            if (!has_existing_session) try request.on_session_id.?(request.session_context, "worker-session");
        }

        if (step == .worker_retry_fail or step == .worker_interrupted) {
            return .{
                .allocator = self.store.allocator,
                .exit_code = if (step == .worker_interrupted) -1 else 7,
                .session_id = try self.store.allocator.dupe(u8, "worker-session"),
                .tokens_used = 0,
                .last_assistant_text = null,
                .stderr_tail = try self.store.allocator.dupe(u8, if (step == .worker_interrupted) "" else "transient backend outage"),
                .was_interrupted = step == .worker_interrupted,
            };
        }

        var loaded = try self.store.loadState(request.loop_id);
        defer loaded.deinit();
        var state = loaded.value;
        switch (step) {
            .worker_progress => {},
            .worker_complete, .worker_repaired => {
                state.status = if (state.verify_enabled) .verifying else .complete;
                state.completion_summary = if (step == .worker_repaired) "Fixed the verifier finding." else "Ready for verification.";
            },
            .verifier_reject => {
                state.status = .active;
                state.blocked_strikes = 0;
                state.last_verifier_feedback = "missing edge test";
            },
            .verifier_no_verdict => {},
            .verifier_pass => {
                state.status = .complete;
                state.completion_summary = "All requested checks pass.";
            },
            .worker_blocked => {
                state.blocked_strikes = @min(state.blocked_strikes +| 1, 3);
                state.last_blocker_summary = "Need another path.";
                state.status = if (state.blocked_strikes >= 3) .blocked else .active;
            },
            .worker_budget_wrapup => {},
            .worker_retry_fail, .worker_interrupted => unreachable,
        }
        try self.store.saveState(state);
        if (self.clock) |clock| clock.now_ms +|= self.advance_clock_ms;
        if (request.event_handler) |handler| handler(request.event_context, .{ .assistant_text = "fake progress" });
        return .{
            .allocator = self.store.allocator,
            .exit_code = 0,
            .session_id = if (is_verifier) try self.store.allocator.dupe(u8, "verifier-session") else try self.store.allocator.dupe(u8, "worker-session"),
            .tokens_used = self.tokens_per_turn,
            .last_assistant_text = try self.store.allocator.dupe(u8, "fake progress"),
            .stderr_tail = try self.store.allocator.dupe(u8, ""),
            .was_interrupted = false,
        };
    }
};

fn argvHas(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |arg| if (std.mem.eql(u8, arg, needle)) return true;
    return false;
}

fn expectFakeCall(call: *const FakeCall, expected_backend: backend.BackendKind, expected_resume: bool, expected_prompt_fragment: []const u8) !void {
    try std.testing.expectEqual(expected_backend, call.backend);
    try std.testing.expectEqual(expected_backend == .agy, call.is_verifier);
    try std.testing.expectEqual(expected_resume, !call.session_id_absent);
    try std.testing.expect(std.mem.indexOf(u8, call.prompt, expected_prompt_fragment) != null);
}

test "captured inputs survive deletion and legacy resume preserves shared execution choices" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    var store = try store_mod.Store.init(allocator, std.testing.io, root);
    defer store.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "task.md", .data = "  captured\nmultiline objective\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".matcha.json", .data = "{\"schema_version\":1,\"loop\":{\"prompt_file\":\"task.md\"}}" });
    const objective = try tmp.dir.readFileAlloc(std.testing.io, "task.md", allocator, .limited(1024));
    defer allocator.free(objective);
    const prompt_path = try std.fs.path.join(allocator, &.{ root, "task.md" });
    defer allocator.free(prompt_path);
    const config_path = try std.fs.path.join(allocator, &.{ root, ".matcha.json" });
    defer allocator.free(config_path);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var fake = FakeRunner{ .store = &store, .script = &.{ .worker_interrupted, .worker_complete, .verifier_pass } };
    defer fake.deinit(allocator);
    const services: Services = .{
        .allocator = allocator,
        .io = std.testing.io,
        .store = &store,
        .parent_environment = &environment,
        .runner = fake.runner(),
        .stdout = &output.writer,
    };
    try std.testing.expectEqual(ExitCode.failure, try run(services, .{
        .backend = .codex,
        .verifier = .agy,
        .backend_bin = "/captured/tool with spaces",
        .model = "captured-model",
        .yolo = true,
        .output_mode = .quiet,
        .max_turns = 12,
        .token_budget = 10000,
        .prompt = objective,
        .prompt_file = prompt_path,
        .config_path = config_path,
        .extra_backend_args = &.{"--captured-arg"},
    }));
    const id = (try store.resolveLatestLoopId()).?;
    defer allocator.free(id);
    var paused = try store.loadState(id);
    defer paused.deinit();
    try std.testing.expectEqual(@as(u32, 2), paused.value.schema_version);
    try std.testing.expectEqual(store_mod.LoopStatus.paused, paused.value.status);
    // Simulate a historical saved loop, with a different verifier but shared model/args.
    var legacy = paused.value;
    legacy.schema_version = 1;
    legacy.turns_completed = 4;
    legacy.tokens_used = 123;
    try store.saveState(legacy);
    try tmp.dir.deleteFile(std.testing.io, "task.md");
    try tmp.dir.deleteFile(std.testing.io, ".matcha.json");
    try std.testing.expectEqual(ExitCode.ok, try resumeLoop(services, id, null));
    var completed = try store.loadState(id);
    defer completed.deinit();
    try std.testing.expectEqual(@as(u32, 2), completed.value.schema_version);
    try std.testing.expectEqualStrings(objective, completed.value.objective);
    try std.testing.expectEqualStrings(paused.value.cwd, completed.value.cwd);
    try std.testing.expectEqualStrings("captured-model", completed.value.model.?);
    try std.testing.expectEqualStrings("/captured/tool with spaces", completed.value.backend_bin.?);
    try std.testing.expectEqualStrings("/captured/tool with spaces", fake.calls.items[1].executable);
    try std.testing.expectEqualStrings("agy", fake.calls.items[2].executable);
    try std.testing.expectEqual(options.OutputMode.quiet, completed.value.output_mode);
    try std.testing.expectEqualStrings("--captured-arg", completed.value.extra_args[0]);
    try std.testing.expect(completed.value.yolo);
    try std.testing.expectEqual(@as(u32, 12), completed.value.max_turns.?);
    try std.testing.expectEqual(@as(u64, 10000), completed.value.token_budget.?);
    try std.testing.expectEqual(@as(u32, 6), completed.value.turns_completed);
    try std.testing.expectEqual(@as(u64, 143), completed.value.tokens_used);
    try std.testing.expectEqualStrings("worker-session", completed.value.worker_session_id.?);
    try expectFakeCall(&fake.calls.items[1], .codex, true, "captured\nmultiline objective");
    try expectFakeCall(&fake.calls.items[2], .agy, false, "captured\nmultiline objective");
}

test "custom executable survives retries continuation and resume with role isolation" {
    const a = std.testing.allocator;
    for ([_]options.BackendKind{ .codex, .droid, .agy }) |kind| {
        for ([_]bool{ false, true }) |different_verifier| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
            defer a.free(root);
            var store = try store_mod.Store.init(a, std.testing.io, root);
            defer store.deinit();
            var env = std.process.Environ.Map.init(a);
            defer env.deinit();
            var output: std.Io.Writer.Allocating = .init(a);
            defer output.deinit();
            var fake = FakeRunner{ .store = &store, .script = &.{ .worker_retry_fail, .worker_progress, .worker_interrupted, .worker_complete, .verifier_pass } };
            defer fake.deinit(a);
            var sleeper = FakeSleeper{ .allocator = a };
            defer sleeper.deinit();
            const verifier: options.BackendKind = if (!different_verifier) kind else if (kind == .codex) .agy else .codex;
            const services: Services = .{ .allocator = a, .io = std.testing.io, .store = &store, .parent_environment = &env, .runner = fake.runner(), .stdout = &output.writer, .sleeper = sleeper.sleeper() };
            try std.testing.expectEqual(ExitCode.failure, try run(services, .{ .backend = kind, .backend_bin = "/custom/tool with spaces", .verifier = verifier, .prompt = "task", .output_mode = .quiet }));
            const id = (try store.resolveLatestLoopId()).?;
            defer a.free(id);
            try std.testing.expectEqual(ExitCode.ok, try resumeLoop(services, id, null));
            try std.testing.expectEqual(@as(usize, 5), fake.calls.items.len);
            for (fake.calls.items[0..4]) |call| try std.testing.expectEqualStrings("/custom/tool with spaces", call.executable);
            try std.testing.expectEqualStrings(if (different_verifier) @tagName(verifier) else "/custom/tool with spaces", fake.calls.items[4].executable);
            var state = try store.loadState(id);
            defer state.deinit();
            try std.testing.expectEqualStrings("/custom/tool with spaces", state.value.backend_bin.?);
        }
    }
}

test "role settings distinguish inherited native and explicit choices with legacy compatibility" {
    var state: store_mod.LoopState = .{ .id = "role", .backend = .codex, .backend_bin = "/worker", .model = "worker-model", .cwd = "/repo", .objective = "task", .started_at_ms = 1, .updated_at_ms = 1, .yolo = true, .extra_args = &.{"--worker-only"}, .separate_verifier_settings = true };
    const same = roleSettings(state, .verifier);
    try std.testing.expectEqualStrings("worker-model", same.model.?);
    try std.testing.expectEqualStrings("/worker", same.backend_bin.?);
    try std.testing.expectEqual(@as(usize, 0), same.extra_args.len);
    state.model = "updated-worker";
    try std.testing.expectEqualStrings("updated-worker", roleSettings(state, .verifier).model.?);
    state.verifier_options = .{ .model_explicit = true, .backend_bin_explicit = true, .args = &.{ "--verifier-only", "literal arg" }, .args_explicit = true };
    const native = roleSettings(state, .verifier);
    try std.testing.expect(native.model == null);
    try std.testing.expect(native.backend_bin == null);
    try std.testing.expectEqualStrings("literal arg", native.extra_args[1]);
    state.verifier_options.model = "verifier-model";
    state.verifier_options.backend_bin = "/verifier";
    state.model = "changed-again";
    try std.testing.expectEqualStrings("verifier-model", roleSettings(state, .verifier).model.?);
    state.verifier_backend = .agy;
    state.verifier_options = .{};
    const different = roleSettings(state, .verifier);
    try std.testing.expect(different.model == null and different.backend_bin == null);
    try std.testing.expect(different.yolo);
    state.separate_verifier_settings = false;
    const legacy = roleSettings(state, .verifier);
    try std.testing.expectEqualStrings("changed-again", legacy.model.?);
    try std.testing.expectEqualStrings("--worker-only", legacy.extra_args[0]);
    try std.testing.expect(legacy.backend_bin == null);
}

test "new worker and verifier execute isolated arguments after preflight" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |different| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        defer a.free(root);
        var store = try store_mod.Store.init(a, std.testing.io, root);
        defer store.deinit();
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try env.put("ROLE_TEST", "shared-value");
        var output: std.Io.Writer.Allocating = .init(a);
        defer output.deinit();
        var fake = FakeRunner{ .store = &store, .script = &.{ .worker_complete, .verifier_pass } };
        defer fake.deinit(a);
        const services: Services = .{ .allocator = a, .io = std.testing.io, .store = &store, .parent_environment = &env, .runner = fake.runner(), .stdout = &output.writer };
        try std.testing.expectEqual(ExitCode.ok, try run(services, .{ .backend = .codex, .backend_bin = "/worker", .model = "worker-model", .verifier = if (different) .agy else .codex, .verifier_options = .{ .model = "verifier-model", .model_explicit = true, .backend_bin = "/verifier", .backend_bin_explicit = true, .args = &.{ "--example", "literal --value" }, .args_explicit = true }, .extra_backend_args = &.{"--worker-only"}, .prompt = "task", .output_mode = .json }));
        try std.testing.expectEqual(@as(usize, 2), fake.preflight_calls.items.len);
        try std.testing.expectEqual(@as(usize, 2), fake.calls.items.len);
        const worker = try std.json.parseFromSlice([]const []const u8, a, fake.calls.items[0].argv_json, .{});
        defer worker.deinit();
        const verifier = try std.json.parseFromSlice([]const []const u8, a, fake.calls.items[1].argv_json, .{});
        defer verifier.deinit();
        try std.testing.expect(argvHas(worker.value, "--worker-only"));
        try std.testing.expect(!argvHas(worker.value, "--example"));
        try std.testing.expect(!argvHas(verifier.value, "--worker-only"));
        try std.testing.expect(argvHas(verifier.value, "--example"));
        try std.testing.expect(argvHas(verifier.value, "literal --value"));
        try std.testing.expect(argvHas(verifier.value, "verifier-model"));
        try std.testing.expectEqualStrings("/verifier", verifier.value[0]);
        try std.testing.expect(fake.calls.items[1].session_id_absent);
        try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"model\":\"verifier-model\"") != null);
    }
}

test "disabled verifier skips preflight and failing enabled preflight creates no loop" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |enabled| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        defer a.free(root);
        var store = try store_mod.Store.init(a, std.testing.io, root);
        defer store.deinit();
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        var output: std.Io.Writer.Allocating = .init(a);
        defer output.deinit();
        var fake = FakeRunner{ .store = &store, .script = &.{.worker_complete}, .fail_second_preflight = true };
        defer fake.deinit(a);
        const services: Services = .{ .allocator = a, .io = std.testing.io, .store = &store, .parent_environment = &env, .runner = fake.runner(), .stdout = &output.writer };
        try std.testing.expectEqual(if (enabled) ExitCode.failure else ExitCode.ok, try run(services, .{ .backend = .codex, .verifier = .agy, .verify_enabled = enabled, .prompt = "task", .output_mode = .quiet }));
        try std.testing.expectEqual(@as(usize, if (enabled) 2 else 1), fake.preflight_calls.items.len);
        try std.testing.expectEqual(@as(usize, if (enabled) 0 else 1), fake.calls.items.len);
        const ids = try store.listLoopIds();
        defer {
            for (ids) |id| a.free(id);
            a.free(ids);
        }
        try std.testing.expectEqual(@as(usize, if (enabled) 0 else 1), ids.len);
    }
}

test "unsupported verifier policy prevents all preflight and worker calls unless disabled" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |enabled| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        defer a.free(root);
        var store = try store_mod.Store.init(a, std.testing.io, root);
        defer store.deinit();
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        var output: std.Io.Writer.Allocating = .init(a);
        defer output.deinit();
        var fake = FakeRunner{ .store = &store, .script = &.{.worker_complete} };
        defer fake.deinit(a);
        const services: Services = .{ .allocator = a, .io = std.testing.io, .store = &store, .parent_environment = &env, .runner = fake.runner(), .stdout = &output.writer, .stderr = &output.writer };
        try std.testing.expectEqual(if (enabled) ExitCode.failure else ExitCode.ok, try run(services, .{ .backend = .codex, .verifier = .agy, .sandbox = .@"workspace-write", .verify_enabled = enabled, .prompt = "task", .output_mode = .quiet }));
        try std.testing.expectEqual(@as(usize, if (enabled) 0 else 1), fake.preflight_calls.items.len);
        try std.testing.expectEqual(@as(usize, if (enabled) 0 else 1), fake.calls.items.len);
        if (enabled) try std.testing.expect(std.mem.indexOf(u8, output.written(), "verifier") != null);
    }
}

test "resume sandbox candidate downgrades captured yolo and rejects invalid candidate without a write" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |unsupported_verifier| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        defer a.free(root);
        var store = try store_mod.Store.init(a, std.testing.io, root);
        defer store.deinit();
        const cwd = try std.process.currentPathAlloc(std.testing.io, a);
        defer a.free(cwd);
        const initial: store_mod.LoopState = .{ .id = "saved-policy", .status = .paused, .backend = .codex, .verifier_backend = .agy, .verify_enabled = unsupported_verifier, .yolo = true, .cwd = cwd, .objective = "saved objective", .worker_session_id = "saved-session", .started_at_ms = 1, .updated_at_ms = 1 };
        try store.createLoop(initial);
        const state_path = try std.fs.path.join(a, &.{ root, initial.id, "state.json" });
        defer a.free(state_path);
        const before = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, state_path, a, .limited(65536));
        defer a.free(before);
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        var output: std.Io.Writer.Allocating = .init(a);
        defer output.deinit();
        var fake = FakeRunner{ .store = &store, .script = &.{.worker_complete} };
        defer fake.deinit(a);
        const services: Services = .{ .allocator = a, .io = std.testing.io, .store = &store, .parent_environment = &env, .runner = fake.runner(), .stdout = &output.writer, .stderr = &output.writer };
        const result = try resumeLoopWithPolicy(services, initial.id, "candidate objective", .@"workspace-write", false);
        try std.testing.expectEqual(if (unsupported_verifier) ExitCode.failure else ExitCode.ok, result);
        var after = try store.loadState(initial.id);
        defer after.deinit();
        if (unsupported_verifier) {
            const durable = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, state_path, a, .limited(65536));
            defer a.free(durable);
            try std.testing.expectEqualStrings(before, durable);
            try std.testing.expectEqual(@as(usize, 0), fake.preflight_calls.items.len);
            try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
        } else {
            try std.testing.expect(!after.value.yolo);
            try std.testing.expectEqual(options.SandboxPolicy.@"workspace-write", after.value.sandbox.?);
            try std.testing.expectEqualStrings("candidate objective", after.value.objective);
            const argv = try std.json.parseFromSlice([]const []const u8, a, fake.calls.items[0].argv_json, .{});
            defer argv.deinit();
            try std.testing.expect(argvHas(argv.value, "workspace-write"));
            try std.testing.expect(!argvHas(argv.value, "--dangerously-bypass-approvals-and-sandbox"));
        }
    }
}

test "contradictory structured native policy fails before runner preflight" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);
    var store = try store_mod.Store.init(a, std.testing.io, root);
    defer store.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var fake = FakeRunner{ .store = &store, .script = &.{} };
    defer fake.deinit(a);
    const services: Services = .{ .allocator = a, .io = std.testing.io, .store = &store, .parent_environment = &env, .runner = fake.runner(), .stdout = &output.writer, .stderr = &output.writer };
    try std.testing.expectEqual(ExitCode.failure, try run(services, .{ .backend = .codex, .sandbox = .@"workspace-write", .extra_backend_args = &.{"--sandbox=danger-full-access"}, .prompt = "task" }));
    try std.testing.expectEqual(@as(usize, 0), fake.preflight_calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "resume explicit yolo replaces saved sandbox and backend default clears saved bypass" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |select_yolo| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        defer a.free(root);
        var store = try store_mod.Store.init(a, std.testing.io, root);
        defer store.deinit();
        const cwd = try std.process.currentPathAlloc(std.testing.io, a);
        defer a.free(cwd);
        const initial: store_mod.LoopState = .{ .id = "policy-reset", .status = .paused, .backend = .codex, .verify_enabled = false, .yolo = !select_yolo, .sandbox = if (select_yolo) .@"workspace-write" else null, .cwd = cwd, .objective = "task", .worker_session_id = "saved-session", .started_at_ms = 1, .updated_at_ms = 1 };
        try store.createLoop(initial);
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        var output: std.Io.Writer.Allocating = .init(a);
        defer output.deinit();
        var fake = FakeRunner{ .store = &store, .script = &.{.worker_complete} };
        defer fake.deinit(a);
        const services: Services = .{ .allocator = a, .io = std.testing.io, .store = &store, .parent_environment = &env, .runner = fake.runner(), .stdout = &output.writer };
        try std.testing.expectEqual(ExitCode.ok, try resumeLoopWithPolicy(services, initial.id, null, if (select_yolo) null else .@"backend-default", select_yolo));
        var saved = try store.loadState(initial.id);
        defer saved.deinit();
        try std.testing.expectEqual(select_yolo, saved.value.yolo);
        try std.testing.expectEqual(@as(?options.SandboxPolicy, if (select_yolo) null else .@"backend-default"), saved.value.sandbox);
        const argv = try std.json.parseFromSlice([]const []const u8, a, fake.calls.items[0].argv_json, .{});
        defer argv.deinit();
        try std.testing.expectEqual(select_yolo, argvHas(argv.value, "--dangerously-bypass-approvals-and-sandbox"));
        try std.testing.expect(!argvHas(argv.value, "workspace-write"));
    }
}

test "legacy native policy passthrough survives ordinary resume but explicit selection is strict" {
    const a = std.testing.allocator;
    const Case = enum { legacy_resume, explicit_resume, new_loop };
    for ([_]Case{ .legacy_resume, .explicit_resume, .new_loop }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        defer a.free(root);
        var store = try store_mod.Store.init(a, std.testing.io, root);
        defer store.deinit();
        const cwd = try std.process.currentPathAlloc(std.testing.io, a);
        defer a.free(cwd);
        const state: store_mod.LoopState = .{ .id = "historical-policy", .status = .paused, .backend = .codex, .verify_enabled = false, .yolo = true, .extra_args = &.{"--sandbox=workspace-write"}, .cwd = cwd, .objective = "saved", .worker_session_id = "saved-session", .started_at_ms = 1, .updated_at_ms = 1 };
        const state_path = try std.fs.path.join(a, &.{ root, state.id, "state.json" });
        defer a.free(state_path);
        var original: ?[]u8 = null;
        defer if (original) |bytes| a.free(bytes);
        if (case != .new_loop) {
            try store.createLoop(state);
            original = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, state_path, a, .limited(65536));
        }
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        var output: std.Io.Writer.Allocating = .init(a);
        defer output.deinit();
        var fake = FakeRunner{ .store = &store, .script = &.{.worker_complete} };
        defer fake.deinit(a);
        const services: Services = .{ .allocator = a, .io = std.testing.io, .store = &store, .parent_environment = &env, .runner = fake.runner(), .stdout = &output.writer, .stderr = &output.writer };
        const result = switch (case) {
            .legacy_resume => try resumeLoop(services, state.id, null),
            .explicit_resume => try resumeLoopWithPolicy(services, state.id, null, null, true),
            .new_loop => try run(services, .{ .backend = .codex, .verify_enabled = false, .yolo = true, .extra_backend_args = state.extra_args, .prompt = "task" }),
        };
        try std.testing.expectEqual(if (case == .legacy_resume) ExitCode.ok else ExitCode.failure, result);
        try std.testing.expectEqual(@as(usize, if (case == .legacy_resume) 1 else 0), fake.calls.items.len);
        try std.testing.expectEqual(@as(usize, if (case == .legacy_resume) 1 else 0), fake.preflight_calls.items.len);
        if (case == .legacy_resume) {
            var saved = try store.loadState(state.id);
            defer saved.deinit();
            try std.testing.expect(!saved.value.policy_validation_enabled);
            const argv = try std.json.parseFromSlice([]const []const u8, a, fake.calls.items[0].argv_json, .{});
            defer argv.deinit();
            try std.testing.expect(argvHas(argv.value, "--sandbox=workspace-write"));
            try std.testing.expect(argvHas(argv.value, "--dangerously-bypass-approvals-and-sandbox"));
        } else if (case == .explicit_resume) {
            const durable = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, state_path, a, .limited(65536));
            defer a.free(durable);
            try std.testing.expectEqualStrings(original.?, durable);
        }
    }
}
