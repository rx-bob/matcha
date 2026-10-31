const std = @import("std");
const errors = @import("errors.zig");

pub const BackendKind = enum { codex, droid, agy };
pub const OutputMode = enum { live, quiet, json };
pub const LoopStatus = enum { complete, blocked };

pub const RunOptions = struct {
    backend: BackendKind,
    backend_explicit: bool = false,
    verifier: ?BackendKind = null,
    verify_enabled: bool = true,
    model: ?[]const u8 = null,
    yolo: bool = false,
    max_turns: ?u32 = null,
    turn_limit_explicit: bool = false,
    token_budget: ?u64 = null,
    timeout_seconds: ?u64 = null,
    output_mode: OutputMode = .live,
    prompt: []const u8,
    extra_backend_args: []const []const u8 = &.{},
};

pub const ResumeOptions = struct { id: ?[]const u8 = null, last: bool = false, objective: ?[]const u8 = null };
pub const ShowOptions = struct { id: ?[]const u8 = null };
pub const UpdateOptions = struct { id: ?[]const u8 = null, status: LoopStatus, summary: ?[]const u8 = null };
pub const VerifyOptions = struct { id: ?[]const u8 = null, passed: bool, reason: ?[]const u8 = null };

pub const LoopCommand = union(enum) {
    run: RunOptions,
    @"resume": ResumeOptions,
    list,
    show: ShowOptions,
    update: UpdateOptions,
    verify: VerifyOptions,
    config,
    help,
};

pub const LoopCommandResult = union(enum) { ok: LoopCommand, err: errors.CliError };

pub fn parseLoopCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdin_is_tty: bool,
    stdin_bytes: []const u8,
) LoopCommandResult {
    if (args.len > 0 and isReserved(args[0])) return parseSubcommand(args);
    return parseRun(allocator, args, stdin_is_tty, stdin_bytes);
}

fn isReserved(arg: []const u8) bool {
    const names = [_][]const u8{ "resume", "list", "show", "update", "verify", "config", "help", "--help", "-h" };
    for (names) |name| if (std.mem.eql(u8, arg, name)) return true;
    return false;
}

fn parseBackend(value: []const u8) ?BackendKind {
    if (std.mem.eql(u8, value, "codex")) return .codex;
    if (std.mem.eql(u8, value, "droid")) return .droid;
    if (std.mem.eql(u8, value, "agy")) return .agy;
    return null;
}

fn parseRun(allocator: std.mem.Allocator, args: []const []const u8, stdin_is_tty: bool, stdin_bytes: []const u8) LoopCommandResult {
    var backend: BackendKind = .codex;
    var backend_explicit = false;
    var verifier: ?BackendKind = null;
    var no_verify = false;
    var model: ?[]const u8 = null;
    var yolo = false;
    var max_turns: ?u32 = null;
    var turn_limit_explicit = false;
    var token_budget: ?u64 = null;
    var timeout_seconds: ?u64 = null;
    var output_mode: OutputMode = .live;
    var quiet_set = false;
    var json_set = false;
    var prompt_parts: std.ArrayList([]const u8) = .empty;
    defer prompt_parts.deinit(allocator);
    var positional = false;
    var extra_args: []const []const u8 = &.{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            extra_args = args[i + 1 ..];
            break;
        }
        if (positional) {
            prompt_parts.append(allocator, arg) catch return .{ .err = .{ .invalid_loop_arguments = "out of memory" } };
            continue;
        }
        if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--backend")) {
            i += 1;
            const value = if (i < args.len) args[i] else return .{ .err = .{ .missing_value = arg } };
            backend = parseBackend(value) orelse return .{ .err = .{ .unknown_backend = value } };
            backend_explicit = true;
        } else if (std.mem.startsWith(u8, arg, "--backend=")) {
            const value = arg["--backend=".len..];
            backend = parseBackend(value) orelse return .{ .err = .{ .unknown_backend = value } };
            backend_explicit = true;
        } else if (std.mem.eql(u8, arg, "--verifier")) {
            i += 1;
            const value = if (i < args.len) args[i] else return .{ .err = .{ .missing_value = arg } };
            verifier = parseBackend(value) orelse return .{ .err = .{ .unknown_backend = value } };
        } else if (std.mem.startsWith(u8, arg, "--verifier=")) {
            const value = arg["--verifier=".len..];
            verifier = parseBackend(value) orelse return .{ .err = .{ .unknown_backend = value } };
        } else if (std.mem.eql(u8, arg, "--no-verify")) {
            no_verify = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--model")) {
            i += 1;
            model = if (i < args.len) args[i] else return .{ .err = .{ .missing_value = arg } };
        } else if (std.mem.startsWith(u8, arg, "--model=")) {
            model = arg["--model=".len..];
        } else if (std.mem.eql(u8, arg, "--yolo")) {
            yolo = true;
        } else if (std.mem.eql(u8, arg, "--max-turns")) {
            i += 1;
            const value = if (i < args.len) args[i] else return .{ .err = .{ .missing_value = arg } };
            max_turns = parseInteger(u32, value) orelse return .{ .err = .{ .invalid_number = value } };
            turn_limit_explicit = true;
        } else if (std.mem.startsWith(u8, arg, "--max-turns=")) {
            const value = arg["--max-turns=".len..];
            max_turns = parseInteger(u32, value) orelse return .{ .err = .{ .invalid_number = value } };
            turn_limit_explicit = true;
        } else if (std.mem.eql(u8, arg, "--unlimited")) {
            max_turns = null;
            turn_limit_explicit = true;
        } else if (std.mem.eql(u8, arg, "--token-budget")) {
            i += 1;
            const value = if (i < args.len) args[i] else return .{ .err = .{ .missing_value = arg } };
            token_budget = parseInteger(u64, value) orelse return .{ .err = .{ .invalid_number = value } };
        } else if (std.mem.startsWith(u8, arg, "--token-budget=")) {
            const value = arg["--token-budget=".len..];
            token_budget = parseInteger(u64, value) orelse return .{ .err = .{ .invalid_number = value } };
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            i += 1;
            const value = if (i < args.len) args[i] else return .{ .err = .{ .missing_value = arg } };
            timeout_seconds = parseDuration(value) orelse return .{ .err = .{ .invalid_duration = value } };
        } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
            const value = arg["--timeout=".len..];
            timeout_seconds = parseDuration(value) orelse return .{ .err = .{ .invalid_duration = value } };
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            output_mode = .quiet;
            quiet_set = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            output_mode = .json;
            json_set = true;
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            return .{ .err = .{ .unknown_option = arg } };
        } else {
            positional = true;
            prompt_parts.append(allocator, arg) catch return .{ .err = .{ .invalid_loop_arguments = "out of memory" } };
        }
    }

    if (no_verify and verifier != null) return .{ .err = .{ .invalid_loop_arguments = "--verifier cannot be combined with --no-verify" } };
    if (quiet_set and json_set) return .{ .err = .{ .invalid_loop_arguments = "--quiet cannot be combined with --json" } };

    var prompt: []const u8 = undefined;
    if (prompt_parts.items.len > 0) {
        prompt = std.mem.join(allocator, " ", prompt_parts.items) catch return .{ .err = .{ .invalid_loop_arguments = "out of memory" } };
    } else if (!stdin_is_tty and stdin_bytes.len > 0) {
        const trimmed = std.mem.trim(u8, stdin_bytes, " \t\r\n");
        if (trimmed.len == 0) return .{ .err = .missing_prompt };
        prompt = allocator.dupe(u8, trimmed) catch return .{ .err = .{ .invalid_loop_arguments = "out of memory" } };
    } else return .{ .err = .missing_prompt };

    return .{ .ok = .{ .run = .{
        .backend = backend,
        .backend_explicit = backend_explicit,
        .verifier = verifier,
        .verify_enabled = !no_verify,
        .model = model,
        .yolo = yolo,
        .max_turns = max_turns,
        .turn_limit_explicit = turn_limit_explicit,
        .token_budget = token_budget,
        .timeout_seconds = timeout_seconds,
        .output_mode = output_mode,
        .prompt = prompt,
        .extra_backend_args = extra_args,
    } } };
}

fn parseSubcommand(args: []const []const u8) LoopCommandResult {
    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        if (args.len != 1) return extra(args[1]);
        return .{ .ok = .help };
    }
    if (std.mem.eql(u8, cmd, "list")) {
        if (args.len != 1) return extra(args[1]);
        return .{ .ok = .list };
    }
    if (std.mem.eql(u8, cmd, "config")) {
        if (args.len != 1) return extra(args[1]);
        return .{ .ok = .config };
    }
    if (std.mem.eql(u8, cmd, "show")) {
        if (args.len > 2 or (args.len == 2 and std.mem.startsWith(u8, args[1], "-"))) return .{ .err = .{ .invalid_loop_arguments = "show accepts at most one loop id" } };
        return .{ .ok = .{ .show = .{ .id = if (args.len == 2) args[1] else null } } };
    }
    if (std.mem.eql(u8, cmd, "resume")) return parseResume(args);
    if (std.mem.eql(u8, cmd, "update")) return parseUpdate(args);
    return parseVerify(args);
}

fn parseResume(args: []const []const u8) LoopCommandResult {
    var o: ResumeOptions = .{};
    var i: usize = 1;
    if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
        o.id = args[i];
        i += 1;
    }
    if (i < args.len and std.mem.eql(u8, args[i], "--last")) {
        if (o.id != null) return .{ .err = .{ .invalid_loop_arguments = "resume accepts id or --last" } };
        o.last = true;
        i += 1;
    }
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--objective")) {
            i += 1;
            if (i >= args.len or o.objective != null) return .{ .err = .{ .invalid_loop_arguments = "--objective requires one value" } };
            o.objective = args[i];
        } else return .{ .err = .{ .unknown_option = args[i] } };
    }
    return .{ .ok = .{ .@"resume" = o } };
}

fn parseUpdate(args: []const []const u8) LoopCommandResult {
    var id: ?[]const u8 = null;
    var status: ?LoopStatus = null;
    var summary: ?[]const u8 = null;
    var i: usize = 1;
    if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
        id = args[i];
        i += 1;
    }
    while (i < args.len) {
        const flag = args[i];
        i += 1;
        if (std.mem.eql(u8, flag, "--status")) {
            if (i >= args.len or status != null) return .{ .err = .{ .invalid_loop_arguments = "--status requires one value" } };
            const value = args[i];
            i += 1;
            if (std.mem.eql(u8, value, "complete")) status = .complete else if (std.mem.eql(u8, value, "blocked")) status = .blocked else return .{ .err = .{ .invalid_loop_arguments = "status must be complete or blocked" } };
        } else if (std.mem.eql(u8, flag, "--summary")) {
            if (i >= args.len or summary != null) return .{ .err = .{ .invalid_loop_arguments = "--summary requires one value" } };
            summary = args[i];
            i += 1;
        } else return .{ .err = .{ .unknown_option = flag } };
    }
    if (status == null) return .{ .err = .{ .invalid_loop_arguments = "update requires --status" } };
    return .{ .ok = .{ .update = .{ .id = id, .status = status.?, .summary = summary } } };
}

fn parseVerify(args: []const []const u8) LoopCommandResult {
    var id: ?[]const u8 = null;
    var passed: ?bool = null;
    var reason: ?[]const u8 = null;
    var i: usize = 1;
    if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
        id = args[i];
        i += 1;
    }
    while (i < args.len) {
        const flag = args[i];
        i += 1;
        if (std.mem.eql(u8, flag, "--pass") or std.mem.eql(u8, flag, "--fail")) {
            if (passed != null) return .{ .err = .{ .invalid_loop_arguments = "choose exactly one of --pass or --fail" } };
            passed = std.mem.eql(u8, flag, "--pass");
        } else if (std.mem.eql(u8, flag, "--reason")) {
            if (i >= args.len or reason != null) return .{ .err = .{ .invalid_loop_arguments = "--reason requires one value" } };
            reason = args[i];
            i += 1;
        } else return .{ .err = .{ .unknown_option = flag } };
    }
    if (passed == null or (passed.? and reason != null) or (!passed.? and reason == null)) return .{ .err = .{ .invalid_loop_arguments = "verify requires --pass or --fail --reason <text>" } };
    return .{ .ok = .{ .verify = .{ .id = id, .passed = passed.?, .reason = reason } } };
}

fn parseInteger(comptime T: type, value: []const u8) ?T {
    return std.fmt.parseInt(T, value, 10) catch null;
}
fn parseDuration(value: []const u8) ?u64 {
    if (value.len < 2) return null;
    const suffix = value[value.len - 1];
    const factor: u64 = switch (suffix) {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        else => return null,
    };
    const n = parseInteger(u64, value[0 .. value.len - 1]) orelse return null;
    return std.math.mul(u64, n, factor) catch null;
}
fn extra(value: []const u8) LoopCommandResult {
    return .{ .err = .{ .extra_arguments = value } };
}

test "loop run parses backend, limits, prompt, and passthrough" {
    const r = parseLoopCommand(std.testing.allocator, &.{ "--backend=agy", "--verifier", "codex", "--model=x", "--yolo", "--max-turns=2", "--token-budget", "42", "--timeout=45m", "--json", "fix", "the bug", "--", "--danger", "x" }, true, "");
    const o = switch (r) {
        .ok => |c| c.run,
        .err => unreachable,
    };
    defer std.testing.allocator.free(o.prompt);
    try std.testing.expectEqual(BackendKind.agy, o.backend);
    try std.testing.expectEqual(@as(u32, 2), o.max_turns.?);
    try std.testing.expectEqual(@as(u64, 2700), o.timeout_seconds.?);
    try std.testing.expectEqualStrings("fix the bug", o.prompt);
    try std.testing.expectEqualStrings("--danger", o.extra_backend_args[0]);
}

test "loop run defaults to Codex and still rejects invalid backends and conflicting modes" {
    const default_result = parseLoopCommand(std.testing.allocator, &.{"fix"}, true, "");
    const default_options = switch (default_result) {
        .ok => |command| command.run,
        .err => unreachable,
    };
    defer std.testing.allocator.free(default_options.prompt);
    try std.testing.expectEqual(BackendKind.codex, default_options.backend);

    try std.testing.expect(switch (parseLoopCommand(std.testing.allocator, &.{ "-b", "nope", "fix" }, true, "")) {
        .err => |e| e == .unknown_backend,
        else => false,
    });
    try std.testing.expect(switch (parseLoopCommand(std.testing.allocator, &.{ "-b", "codex", "--quiet", "--json", "fix" }, true, "")) {
        .err => |e| e == .invalid_loop_arguments,
        else => false,
    });
}

test "loop run accepts piped prompt and parses duration suffixes" {
    const r = parseLoopCommand(std.testing.allocator, &.{ "-b", "droid", "--timeout", "8h" }, false, " piped prompt \n");
    const o = switch (r) {
        .ok => |c| c.run,
        .err => unreachable,
    };
    defer std.testing.allocator.free(o.prompt);
    try std.testing.expectEqual(@as(u64, 28800), o.timeout_seconds.?);
    try std.testing.expectEqualStrings("piped prompt", o.prompt);
}

test "loop subcommands validate update and verify combinations" {
    try std.testing.expect(switch (parseLoopCommand(std.testing.allocator, &.{ "update", "--status", "blocked" }, true, "")) {
        .ok => |c| c == .update,
        else => false,
    });
    try std.testing.expect(switch (parseLoopCommand(std.testing.allocator, &.{ "verify", "--pass", "--fail" }, true, "")) {
        .err => |e| e == .invalid_loop_arguments,
        else => false,
    });
    try std.testing.expect(switch (parseLoopCommand(std.testing.allocator, &.{ "verify", "--fail", "--reason", "bad" }, true, "")) {
        .ok => |c| c == .verify,
        else => false,
    });
}
