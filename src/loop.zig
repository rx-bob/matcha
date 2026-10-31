const std = @import("std");
const backend = @import("loop_backend.zig");
const options = @import("loop_options.zig");
const prompts = @import("loop_prompts.zig");
const store_mod = @import("loop_store.zig");
const stream = @import("loop_stream.zig");

pub const ExitCode = enum { ok, failure };

pub const Services = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *store_mod.Store,
    parent_environment: *const std.process.Environ.Map,
    runner: backend.BackendRunner,
    stdout: *std.Io.Writer,
};

pub fn run(services: Services, run_options: options.RunOptions) !ExitCode {
    const allocator = services.allocator;
    const cwd = try std.process.currentPathAlloc(services.io, allocator);
    defer allocator.free(cwd);
    const id = try services.store.generateLoopId();
    defer allocator.free(id);
    const now = nowMilliseconds(services.io);
    const state: store_mod.LoopState = .{
        .id = id,
        .status = .active,
        .backend = run_options.backend,
        .verifier_backend = run_options.verifier,
        .verify_enabled = run_options.verify_enabled,
        .model = run_options.model,
        .yolo = run_options.yolo,
        .cwd = cwd,
        .objective = run_options.prompt,
        .started_at_ms = now,
        .updated_at_ms = now,
        .max_turns = run_options.max_turns,
        .token_budget = run_options.token_budget,
        .timeout_seconds = run_options.timeout_seconds,
        .extra_args = run_options.extra_backend_args,
    };
    try services.store.createLoop(state);

    var presenter = stream.Presenter.init(allocator, services.stdout, run_options.output_mode, id, run_options.backend);
    defer presenter.deinit();
    try presenter.loopStarted();

    var verifier_unconfirmed_attempts: u8 = 0;
    while (true) {
        var loaded = try services.store.loadState(id);
        const current = loaded.value;
        defer loaded.deinit();

        switch (current.status) {
            .complete => {
                const outcome = current.completion_summary orelse "Loop completed and verification passed.";
                try presenter.loopFinished(current.status, current.turns_completed, current.tokens_used, outcome);
                return .ok;
            },
            .blocked => {
                const outcome = current.last_blocker_summary orelse "Loop reached the blocker limit.";
                try presenter.loopFinished(current.status, current.turns_completed, current.tokens_used, outcome);
                return .failure;
            },
            .paused, .budget_limited => {
                try presenter.loopFinished(current.status, current.turns_completed, current.tokens_used, "Loop is not active.");
                return .failure;
            },
            .active, .verifying => {},
        }

        const role: store_mod.TurnRole = if (current.status == .verifying) .verifier else .worker;
        const turn_number = current.turns_completed +| 1;
        const turn_backend: backend.BackendKind = if (role == .verifier) current.verifier_backend orelse current.backend else current.backend;
        const session_id: ?[]const u8 = if (role == .verifier) null else current.worker_session_id;
        if (role == .worker and current.turns_completed > 0 and session_id == null) {
            try services.stdout.print("Loop {s} cannot continue: backend did not provide a worker session ID.\n", .{id});
            try services.stdout.flush();
            return .failure;
        }

        const prompt_kind: prompts.PromptKind = if (role == .verifier)
            .verifier
        else if (current.turns_completed == 0)
            .initial
        else
            .continuation;
        const prompt = try prompts.renderPrompt(allocator, prompt_kind, promptContext(services.io, current, turn_number));
        defer allocator.free(prompt);

        // A verifier rejection is injected once into the next worker continuation.
        if (role == .worker and current.last_verifier_feedback != null) {
            var updated = current;
            updated.last_verifier_feedback = null;
            updated.updated_at_ms = nowMilliseconds(services.io);
            try services.store.saveState(updated);
        }

        const loop_dir = try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ services.store.root, std.Io.Dir.path.sep, id });
        defer allocator.free(loop_dir);
        const prompt_file = try std.fmt.allocPrint(allocator, "{s}{c}current_prompt.md", .{ loop_dir, std.Io.Dir.path.sep });
        defer allocator.free(prompt_file);
        var argv = try backend.buildArgv(allocator, .{
            .backend = turn_backend,
            .model = current.model,
            .yolo = current.yolo,
            .extra_args = current.extra_args,
        }, loop_dir, session_id, prompt_file);
        defer argv.deinit();
        var child_environment = try backend.buildChildEnvironment(allocator, services.io, services.parent_environment, id);
        defer child_environment.deinit();

        const started_ms = nowMilliseconds(services.io);
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
        };
        if (role == .worker) {
            request.session_context = &persist_context;
            request.on_session_id = PersistSessionContext.persist;
        }
        var result = services.runner.runTurn(request) catch |err| {
            try services.stdout.print("Loop {s} backend turn failed: {s}\n", .{ id, @errorName(err) });
            try services.stdout.flush();
            return .failure;
        };
        defer result.deinit();
        try presenter.checkError();
        const elapsed_ms = nowMilliseconds(services.io) -| started_ms;

        var after_turn_parsed = try services.store.loadState(id);
        defer after_turn_parsed.deinit();
        var after_turn = after_turn_parsed.value;
        const previous_status = current.status;
        const blocked_strikes_before = current.blocked_strikes;
        after_turn.turns_completed +|= 1;
        after_turn.tokens_used +|= result.tokens_used;
        after_turn.updated_at_ms = nowMilliseconds(services.io);

        if (role == .worker and after_turn.status == .active) {
            if (after_turn.blocked_strikes == blocked_strikes_before) {
                after_turn.blocked_strikes = 0;
                after_turn.last_blocker_summary = null;
            }
        }

        const verifier_exited_without_verdict = role == .verifier and after_turn.status == .verifying and result.exit_code != 0 and !result.was_interrupted;
        if ((result.exit_code != 0 or result.was_interrupted) and !verifier_exited_without_verdict) {
            const summary = if (after_turn.status == .blocked)
                after_turn.last_blocker_summary orelse "Loop reached the blocker limit."
            else if (result.stderr_tail.len > 0)
                result.stderr_tail
            else
                "backend exited unsuccessfully";
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
            try presenter.loopFinished(after_turn.status, after_turn.turns_completed, after_turn.tokens_used, summary);
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
                retry_state.updated_at_ms = nowMilliseconds(services.io);
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

fn promptContext(io: std.Io, state: store_mod.LoopState, turn_number: u32) prompts.PromptContext {
    const current_ms = nowMilliseconds(io);
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

fn nowMilliseconds(io: std.Io) u64 {
    return @intCast(@max(0, std.Io.Clock.real.now(io).toMilliseconds()));
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
        state.updated_at_ms = nowMilliseconds(self.store.io);
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

const FakeStep = enum { worker_progress, worker_complete, verifier_reject, verifier_no_verdict, worker_repaired, verifier_pass, worker_blocked };

const FakeCall = struct {
    backend: backend.BackendKind,
    is_verifier: bool,
    session_id_absent: bool,
    prompt: []u8,

    fn deinit(self: *FakeCall, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt);
    }
};

const FakeRunner = struct {
    store: *store_mod.Store,
    script: []const FakeStep,
    calls: std.ArrayList(FakeCall) = .empty,
    next_step: usize = 0,

    fn runner(self: *FakeRunner) backend.BackendRunner {
        return .{ .context = @ptrCast(self), .runTurnFn = FakeRunner.runTurn };
    }

    fn deinit(self: *FakeRunner, allocator: std.mem.Allocator) void {
        for (self.calls.items) |*call| call.deinit(allocator);
        self.calls.deinit(allocator);
    }

    fn runTurn(context: *anyopaque, request: backend.TurnRequest) anyerror!backend.TurnExecutionResult {
        const self: *FakeRunner = @ptrCast(@alignCast(context));
        if (self.next_step >= self.script.len) return error.UnexpectedFakeTurn;
        const step = self.script[self.next_step];
        self.next_step += 1;
        const is_verifier = step == .verifier_reject or step == .verifier_no_verdict or step == .verifier_pass;
        const has_session_flag = switch (request.backend) {
            .codex => argvHas(request.argv, "resume"),
            .droid => argvHas(request.argv, "-s"),
            .agy => argvHas(request.argv, "--conversation"),
        };
        try self.calls.append(self.store.allocator, .{
            .backend = request.backend,
            .is_verifier = is_verifier,
            .session_id_absent = !has_session_flag,
            .prompt = try self.store.allocator.dupe(u8, request.prompt),
        });
        const call_index = self.calls.items.len - 1;
        errdefer self.calls.items[call_index].deinit(self.store.allocator);

        if (!is_verifier and request.on_session_id != null) {
            const state_parsed = try self.store.loadState(request.loop_id);
            const has_existing_session = state_parsed.value.worker_session_id != null;
            state_parsed.deinit();
            if (!has_existing_session) try request.on_session_id.?(request.session_context, "worker-session");
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
        }
        try self.store.saveState(state);
        if (request.event_handler) |handler| handler(request.event_context, .{ .assistant_text = "fake progress" });
        return .{
            .allocator = self.store.allocator,
            .exit_code = 0,
            .session_id = if (is_verifier) try self.store.allocator.dupe(u8, "verifier-session") else try self.store.allocator.dupe(u8, "worker-session"),
            .tokens_used = 10,
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
