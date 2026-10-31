const std = @import("std");
const matcha = @import("matcha");
const cli = matcha.cli;
const loop_backend = matcha.loop_backend;
const loop_store = matcha.loop_store;
const ExitCode = cli.ExitCode;
const runArgsRuntime = cli.runArgsRuntime;
const runLoopCommandWithInputs = cli.runLoopCommandWithInputs;

test "loop help documents project configuration and resume controls" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try cli.writeLoopHelp(&output.writer);
    const help = output.written();
    for ([_][]const u8{
        "piped stdin",
        "--prompt-file",
        "--config",
        "--verifier-arg",
        "--reasoning-effort",
        "--env-file",
        "--path-prepend",
        "--log-dir",
        "--sandbox",
        "--yolo",
        "current ambient env",
        "logging failures",
    }) |fragment| {
        try std.testing.expect(std.mem.indexOf(u8, help, fragment) != null);
    }
}

const ProjectWorkflowRunner = struct {
    store: *loop_store.Store,
    project: []const u8,
    worker: []const u8,
    verifier: []const u8,
    repaired_worker: []const u8,
    repaired_verifier: []const u8,
    old_toolchain: []const u8,
    new_toolchain: []const u8,
    calls: usize = 0,
    preflights: usize = 0,
    failed_initial_attempt: bool = false,
    real: loop_backend.RealBackendRunner = .{},

    fn runner(self: *ProjectWorkflowRunner) loop_backend.BackendRunner {
        return .{ .context = self, .runTurnFn = runTurn, .preflightFn = preflight };
    }

    fn preflight(context: *anyopaque, request: loop_backend.PreflightRequest) !void {
        const self: *ProjectWorkflowRunner = @ptrCast(@alignCast(context));
        self.preflights += 1;
        try self.real.runner().preflight(request);
    }

    fn runTurn(context: *anyopaque, request: loop_backend.TurnRequest) !loop_backend.TurnExecutionResult {
        const self: *ProjectWorkflowRunner = @ptrCast(@alignCast(context));
        const call = self.calls;
        const retry_fail = call == 0 and !self.failed_initial_attempt;
        try std.testing.expectEqual(@as(u32, if (retry_fail) 1 else if (call == 0) 2 else 1), request.log_context.attempt.?);
        const verifying = call == 1 or call == 6;
        const repaired = call >= 4;
        try std.testing.expectEqualStrings(self.project, request.cwd.path);
        try std.testing.expectEqualStrings(if (verifying) (if (repaired) self.repaired_verifier else self.verifier) else (if (repaired) self.repaired_worker else self.worker), request.argv[0]);
        try std.testing.expectEqualStrings(if (repaired) "replacement" else "original", request.environ_map.get("FIXTURE_TOKEN").?);
        try std.testing.expectEqualStrings(if (repaired) "repair-model" else if (verifying) "verifier-model" else "worker-model", argumentAfter(request.argv, "--model").?);
        try std.testing.expectEqualStrings(if (repaired) "xhigh" else if (verifying) "medium" else "high", codexEffort(request.argv).?);
        try std.testing.expect(containsArgument(request.argv, "--sandbox"));
        try std.testing.expect(containsArgument(request.argv, "workspace-write"));
        try std.testing.expectEqual(!verifying, containsArgument(request.argv, "--worker-only"));
        try std.testing.expectEqual(verifying, containsArgument(request.argv, "--verifier-only"));
        try std.testing.expectEqualStrings(request.loop_id, request.environ_map.get("MATCHA_LOOP_ID").?);
        const path_value = request.environ_map.get("PATH").?;
        try std.testing.expect(std.mem.indexOf(u8, path_value, if (repaired) self.new_toolchain else self.old_toolchain) != null);
        try std.testing.expectEqualStrings(if (call >= 3) "changed-ambient" else "initial-ambient", request.environ_map.get("UNRELATED_AMBIENT").?);

        var env = try request.environ_map.clone(request.allocator);
        defer env.deinit();
        const call_text = try std.fmt.allocPrint(request.allocator, "{d}", .{call});
        defer request.allocator.free(call_text);
        try env.put("FIXTURE_CALL", call_text);
        try env.put("FIXTURE_RETRY_FAIL", if (retry_fail) "1" else "0");
        var actual = request;
        actual.environ_map = &env;
        var result = try self.real.runner().runTurn(actual);
        errdefer result.deinit();
        if (retry_fail) {
            try std.testing.expectEqual(@as(i32, 23), result.exit_code);
            self.failed_initial_attempt = true;
            return result;
        }
        try std.testing.expectEqual(@as(i32, 0), result.exit_code);
        if (call == 0 or call == 5) {
            try std.testing.expectEqual(ExitCode.ok, try runArgsRuntime(&.{ "loop", "update", request.loop_id, "--status", "complete", "--summary", "fixture ready" }, request.io, request.diagnostics.?, request.diagnostics.?, self.store.root, request.environ_map, null));
        } else if (call == 1 or call == 6) {
            const args: []const []const u8 = if (call == 6) &.{ "loop", "verify", request.loop_id, "--pass" } else &.{ "loop", "verify", request.loop_id, "--fail", "--reason", "needs repair" };
            try std.testing.expectEqual(ExitCode.ok, try runArgsRuntime(args, request.io, request.diagnostics.?, request.diagnostics.?, self.store.root, request.environ_map, null));
        } else {
            result.was_interrupted = true;
        }
        self.calls += 1;
        return result;
    }
};

fn containsArgument(args: []const []const u8, wanted: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, wanted)) return true;
    return false;
}

fn argumentAfter(args: []const []const u8, flag: []const u8) ?[]const u8 {
    for (args, 0..) |arg, index| if (std.mem.eql(u8, arg, flag) and index + 1 < args.len) return args[index + 1];
    return null;
}

fn codexEffort(args: []const []const u8) ?[]const u8 {
    const raw = argumentAfter(args, "-c") orelse return null;
    const prefix = "model_reasoning_effort=\"";
    if (!std.mem.startsWith(u8, raw, prefix) or raw.len <= prefix.len or raw[raw.len - 1] != '"') return null;
    return raw[prefix.len .. raw.len - 1];
}

fn hasRawPayload(allocator: std.mem.Allocator, events: []const u8, stream_name: []const u8, needle: []const u8) !bool {
    var lines = std.mem.tokenizeScalar(u8, events, '\n');
    while (lines.next()) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const value = parsed.value;
        if (!std.mem.eql(u8, value.object.get("kind").?.string, "raw")) continue;
        if (!std.mem.eql(u8, value.object.get("stream").?.string, stream_name)) continue;
        const encoded = value.object.get("payload").?.string;
        const decoded = try allocator.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
        defer allocator.free(decoded);
        try std.base64.standard.Decoder.decode(decoded, encoded);
        if (std.mem.indexOf(u8, decoded, needle) != null) return true;
    }
    return false;
}

fn writeExecutable(dir: std.Io.Dir, io: std.Io, name: []const u8, role: []const u8) !void {
    const script = try std.fmt.allocPrint(
        std.testing.allocator,
        "#!/bin/sh\n" ++
            "{{ printf 'cwd=%s\\n' \"$PWD\"; printf 'token=%s\\n' \"$FIXTURE_TOKEN\"; printf 'ambient=%s\\n' \"$UNRELATED_AMBIENT\"; printf 'tool=%s\\n' \"$(toolchain-probe)\"; for arg do printf 'arg=%s\\n' \"$arg\"; done; }} > \"$FIXTURE_RECORD/{s}-$FIXTURE_CALL\"\n" ++
            "if [ \"$FIXTURE_RETRY_FAIL\" = 1 ]; then printf 'transient fixture stderr\\n' >&2; exit 23; fi\n" ++
            "printf '{{\"type\":\"thread.started\",\"thread_id\":\"fixture-session\"}}\\n'\n" ++
            "printf '{{\"type\":\"fixture.unknown\",\"value\":7}}\\n'\n" ++
            "printf '{{\"type\":\"turn.completed\",\"usage\":{{\"input_tokens\":2,\"output_tokens\":1}}}}\\n'\n" ++
            "printf 'fixture stderr\\n' >&2\n",
        .{role},
    );
    defer std.testing.allocator.free(script);
    const file = try dir.createFile(io, name, .{ .permissions = .executable_file });
    defer file.close(io);
    try file.writeStreamingAll(io, script);
}

test "offline project config drives real worker verifier logs and durable resume repairs" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const original_cwd = try std.process.currentPathAlloc(io, a);
    defer a.free(original_cwd);
    defer std.Io.Threaded.chdir(original_cwd) catch {};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fs.path.resolve(a, &.{ original_cwd, ".zig-cache/tmp", tmp.sub_path[0..] });
    defer a.free(root);
    const project = try std.fs.path.join(a, &.{ root, "project" });
    defer a.free(project);
    const elsewhere = try std.fs.path.join(a, &.{ root, "elsewhere" });
    defer a.free(elsewhere);
    const old_toolchain = try std.fs.path.join(a, &.{ project, "toolchain-bin" });
    defer a.free(old_toolchain);
    const new_toolchain = try std.fs.path.join(a, &.{ elsewhere, "repair-bin" });
    defer a.free(new_toolchain);
    const log_dir = try std.fs.path.join(a, &.{ project, "logs" });
    defer a.free(log_dir);
    const new_log_dir = try std.fs.path.join(a, &.{ elsewhere, "repair-logs" });
    defer a.free(new_log_dir);
    const worker = try std.fs.path.join(a, &.{ project, "worker.sh" });
    defer a.free(worker);
    const verifier = try std.fs.path.join(a, &.{ project, "verifier.sh" });
    defer a.free(verifier);
    const repaired_worker = try std.fs.path.join(a, &.{ elsewhere, "worker-repair.sh" });
    defer a.free(repaired_worker);
    const repaired_verifier = try std.fs.path.join(a, &.{ elsewhere, "verifier-repair.sh" });
    defer a.free(repaired_verifier);
    const store_root = try std.fs.path.join(a, &.{ root, "store" });
    defer a.free(store_root);
    try std.Io.Dir.cwd().createDirPath(io, old_toolchain);
    try std.Io.Dir.cwd().createDirPath(io, new_toolchain);
    const project_dir = try std.Io.Dir.cwd().openDir(io, project, .{});
    defer project_dir.close(io);
    const elsewhere_dir = try std.Io.Dir.cwd().openDir(io, elsewhere, .{});
    defer elsewhere_dir.close(io);
    const old_bin = try std.Io.Dir.cwd().openDir(io, old_toolchain, .{});
    defer old_bin.close(io);
    const new_bin = try std.Io.Dir.cwd().openDir(io, new_toolchain, .{});
    defer new_bin.close(io);
    try writeExecutable(project_dir, io, "worker.sh", "worker");
    try writeExecutable(project_dir, io, "verifier.sh", "verifier");
    try writeExecutable(elsewhere_dir, io, "worker-repair.sh", "worker");
    try writeExecutable(elsewhere_dir, io, "verifier-repair.sh", "verifier");
    for ([_]std.Io.Dir{ old_bin, new_bin }, [_][]const u8{ "original-toolchain", "repair-toolchain" }) |dir, label| {
        const file = try dir.createFile(io, "toolchain-probe", .{ .permissions = .executable_file });
        defer file.close(io);
        const script = try std.fmt.allocPrint(a, "#!/bin/sh\nprintf '%s\\n' '{s}'\n", .{label});
        defer a.free(script);
        try file.writeStreamingAll(io, script);
    }
    const task_file = try project_dir.createFile(io, "task.md", .{});
    try task_file.writeStreamingAll(io, "first objective line\n\nsecond objective line\n");
    task_file.close(io);
    const env_text = try std.fmt.allocPrint(a, "FIXTURE_TOKEN=original\nFIXTURE_RECORD={s}\n", .{project});
    defer a.free(env_text);
    const env_file = try project_dir.createFile(io, "project.env", .{});
    try env_file.writeStreamingAll(io, env_text);
    env_file.close(io);
    const config =
        \\{"schema_version":1,"loop":{"backend":"codex","backend_bin":"./worker.sh","model":"worker-model","reasoning_effort":"high","prompt_file":"task.md","env_files":["project.env"],"path_prepend":["toolchain-bin"],"log_dir":"logs","sandbox":"workspace-write","extra_backend_args":["--worker-only"],"verifier":{"backend":"codex","backend_bin":"./verifier.sh","model":"verifier-model","reasoning_effort":"medium","args":["--verifier-only"]}}}
    ;
    const config_file = try project_dir.createFile(io, ".matcha.json", .{});
    try config_file.writeStreamingAll(io, config);
    config_file.close(io);

    var store = try loop_store.Store.init(a, io, store_root);
    defer store.deinit();
    var parent = std.process.Environ.Map.init(a);
    defer parent.deinit();
    try parent.put("PATH", "/bin:/usr/bin");
    try parent.put("UNRELATED_AMBIENT", "initial-ambient");
    var runner = ProjectWorkflowRunner{ .store = &store, .project = project, .worker = worker, .verifier = verifier, .repaired_worker = repaired_worker, .repaired_verifier = repaired_verifier, .old_toolchain = old_toolchain, .new_toolchain = new_toolchain };
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(a);
    defer err.deinit();
    try std.Io.Threaded.chdir(project);
    try std.testing.expectEqual(ExitCode.failure, try runLoopCommandWithInputs(io, &.{}, &out.writer, &err.writer, store_root, &parent, runner.runner(), .{ .project_path = ".matcha.json" }));
    try std.testing.expectEqual(@as(usize, 3), runner.calls);
    const id = (try store.resolveLatestLoopId()).?;
    defer a.free(id);
    var paused = try store.loadState(id);
    defer paused.deinit();
    try std.testing.expectEqual(loop_store.LoopStatus.paused, paused.value.status);
    try std.testing.expectEqualStrings("first objective line\n\nsecond objective line\n", paused.value.objective);
    try std.testing.expectEqualStrings(project, paused.value.cwd);
    try std.testing.expectEqualStrings("original", paused.value.env[0].value);
    const first_invocation = try a.dupe(u8, paused.value.last_invocation_id.?);
    defer a.free(first_invocation);
    const first_events_path = try std.fmt.allocPrint(a, "{s}/{s}.jsonl", .{ log_dir, first_invocation });
    defer a.free(first_events_path);
    const first_log_path = try std.fmt.allocPrint(a, "{s}/{s}.log", .{ log_dir, first_invocation });
    defer a.free(first_log_path);
    const first_events = try std.Io.Dir.cwd().readFileAlloc(io, first_events_path, a, .unlimited);
    defer a.free(first_events);
    const first_log = try std.Io.Dir.cwd().readFileAlloc(io, first_log_path, a, .unlimited);
    defer a.free(first_log);
    try std.testing.expect(try hasRawPayload(a, first_events, "stdout", "fixture.unknown"));
    try std.testing.expect(try hasRawPayload(a, first_events, "stderr", "fixture stderr"));
    try std.testing.expect(try hasRawPayload(a, first_events, "stderr", "transient fixture stderr"));
    try std.testing.expect(std.mem.indexOf(u8, first_events, "\"attempt\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_log, "fixture stderr") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_events, "\"role\":\"verifier\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_events, "\"kind\":\"status\"") != null);
    const record_path = try std.fmt.allocPrint(a, "{s}/worker-0", .{project});
    defer a.free(record_path);
    const record = try std.Io.Dir.cwd().readFileAlloc(io, record_path, a, .unlimited);
    defer a.free(record);
    const expected_cwd = try std.fmt.allocPrint(a, "cwd={s}", .{project});
    defer a.free(expected_cwd);
    try std.testing.expect(std.mem.indexOf(u8, record, expected_cwd) != null);
    try std.testing.expect(std.mem.indexOf(u8, record, "token=original") != null);
    try std.testing.expect(std.mem.indexOf(u8, record, "tool=original-toolchain") != null);
    try std.testing.expect(std.mem.indexOf(u8, record, "arg=worker-model") != null);
    const verifier_record_path = try std.fmt.allocPrint(a, "{s}/verifier-1", .{project});
    defer a.free(verifier_record_path);
    const verifier_record = try std.Io.Dir.cwd().readFileAlloc(io, verifier_record_path, a, .unlimited);
    defer a.free(verifier_record);
    try std.testing.expect(std.mem.indexOf(u8, verifier_record, "arg=verifier-model") != null);
    try std.testing.expect(std.mem.indexOf(u8, verifier_record, "arg=--verifier-only") != null);

    try project_dir.deleteFile(io, ".matcha.json");
    try project_dir.deleteFile(io, "task.md");
    try project_dir.deleteFile(io, "project.env");
    try parent.put("UNRELATED_AMBIENT", "changed-ambient");
    try std.Io.Threaded.chdir(elsewhere);
    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    try std.testing.expectEqual(ExitCode.failure, try runArgsRuntime(&.{ "loop", "resume", id }, io, &out.writer, &err.writer, store_root, &parent, runner.runner()));
    try std.testing.expectEqual(@as(usize, 4), runner.calls);
    var ordinary = try store.loadState(id);
    defer ordinary.deinit();
    try std.testing.expectEqualStrings(first_invocation, paused.value.last_invocation_id.?);
    try std.testing.expect(!std.mem.eql(u8, first_invocation, ordinary.value.last_invocation_id.?));
    try std.testing.expectEqualStrings(project, ordinary.value.cwd);
    try std.testing.expectEqualStrings(paused.value.objective, ordinary.value.objective);
    try std.testing.expectEqualStrings("original", ordinary.value.env[0].value);
    const first_events_after = try std.Io.Dir.cwd().readFileAlloc(io, first_events_path, a, .unlimited);
    defer a.free(first_events_after);
    try std.testing.expectEqualStrings(first_events, first_events_after);

    const repair_env = try elsewhere_dir.createFile(io, "repair.env", .{});
    try repair_env.writeStreamingAll(io, "FIXTURE_TOKEN=replacement\n");
    repair_env.close(io);
    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    try std.testing.expectEqual(ExitCode.failure, try runArgsRuntime(&.{ "loop", "resume", id, "--env-file=repair.env", "--path-prepend=repair-bin", "--backend-bin=./worker-repair.sh", "--verifier-bin=./verifier-repair.sh", "--model=repair-model", "--verifier-model=repair-model", "--reasoning-effort=xhigh", "--verifier-reasoning-effort=xhigh", "--sandbox=workspace-write", "--log-dir=repair-logs" }, io, &out.writer, &err.writer, store_root, &parent, runner.runner()));
    try std.testing.expectEqual(@as(usize, 5), runner.calls);
    var repaired = try store.loadState(id);
    defer repaired.deinit();
    try std.testing.expectEqualStrings(repaired_worker, repaired.value.backend_bin.?);
    try std.testing.expectEqualStrings(new_log_dir, repaired.value.log_dir.?);
    try std.testing.expectEqualStrings(new_toolchain, repaired.value.path_prepend[0]);
    const repair_invocation = try a.dupe(u8, repaired.value.last_invocation_id.?);
    defer a.free(repair_invocation);
    const repair_events_path = try std.fmt.allocPrint(a, "{s}/{s}.jsonl", .{ new_log_dir, repair_invocation });
    defer a.free(repair_events_path);
    const repair_events = try std.Io.Dir.cwd().readFileAlloc(io, repair_events_path, a, .unlimited);
    defer a.free(repair_events);
    try std.testing.expect(try hasRawPayload(a, repair_events, "stdout", "fixture.unknown"));
    const state_path = try std.fmt.allocPrint(a, "{s}/{s}/state.json", .{ store_root, id });
    defer a.free(state_path);
    const accepted_state = try std.Io.Dir.cwd().readFileAlloc(io, state_path, a, .unlimited);
    defer a.free(accepted_state);
    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    try std.testing.expectEqual(ExitCode.failure, try runArgsRuntime(&.{ "loop", "resume", id, "--verifier-reasoning-effort=unsupported" }, io, &out.writer, &err.writer, store_root, &parent, runner.runner()));
    const state_after_invalid = try std.Io.Dir.cwd().readFileAlloc(io, state_path, a, .unlimited);
    defer a.free(state_after_invalid);
    try std.testing.expectEqualStrings(accepted_state, state_after_invalid);
    try std.testing.expectEqual(@as(usize, 5), runner.calls);
    try elsewhere_dir.deleteFile(io, "repair.env");
    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    try std.testing.expectEqual(ExitCode.ok, try runArgsRuntime(&.{ "loop", "resume", id }, io, &out.writer, &err.writer, store_root, &parent, runner.runner()));
    try std.testing.expectEqual(@as(usize, 7), runner.calls);
    var completed = try store.loadState(id);
    defer completed.deinit();
    try std.testing.expectEqual(loop_store.LoopStatus.complete, completed.value.status);
    try std.testing.expectEqualStrings("replacement", completed.value.env[0].value);
    try std.testing.expectEqualStrings(project, completed.value.cwd);
    try std.testing.expectEqualStrings(paused.value.objective, completed.value.objective);
    try std.testing.expect(!std.mem.eql(u8, repair_invocation, completed.value.last_invocation_id.?));
    const final_events_path = try std.fmt.allocPrint(a, "{s}/{s}.jsonl", .{ new_log_dir, completed.value.last_invocation_id.? });
    defer a.free(final_events_path);
    const final_events = try std.Io.Dir.cwd().readFileAlloc(io, final_events_path, a, .unlimited);
    defer a.free(final_events);
    try std.testing.expect(std.mem.indexOf(u8, final_events, "\"kind\":\"final\"") != null);
    const repaired_record_path = try std.fmt.allocPrint(a, "{s}/worker-5", .{project});
    defer a.free(repaired_record_path);
    const repaired_record = try std.Io.Dir.cwd().readFileAlloc(io, repaired_record_path, a, .unlimited);
    defer a.free(repaired_record);
    try std.testing.expect(std.mem.indexOf(u8, repaired_record, "token=replacement") != null);
    try std.testing.expect(std.mem.indexOf(u8, repaired_record, "tool=repair-toolchain") != null);
    try std.testing.expect(std.mem.indexOf(u8, repaired_record, "ambient=changed-ambient") != null);
    try std.testing.expect(runner.preflights >= 8);
}
