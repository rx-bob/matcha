const std = @import("std");
const toon = @import("src/render_toon.zig");
const prompts = @import("src/loop_prompts.zig");
const routes = @import("src/serve_routes.zig");
const path = @import("src/path.zig");
const backend = @import("src/loop_backend.zig");
const loop_options = @import("src/loop_options.zig");
const json_input = @import("src/json_input.zig");
const plan_read = @import("src/plan_read.zig");
const catalog = @import("src/serve_catalog.zig");
const stream = @import("src/loop_stream.zig");
const loop_config = @import("src/loop_config.zig");
const loop_summary = @import("src/loop_summary.zig");
const loop_store = @import("src/loop_store.zig");

fn ignoreStreamEvent(_: ?*anyopaque, _: stream.NormalizedEvent) void {}

test "toon rendering releases partial allocations at every OOM point" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        "{\"title\":\"Leak audit\",\"metadata\":{\"nested\":{\"a\":[1,\"x\"]}}," ++
            "\"sections\":[{\"title\":\"Items\",\"items\":[{\"title\":\"one\",\"text\":\"two\"}]}]," ++
            "\"rows\":[" ++
            "{\"id\":1,\"customer\":{\"name\":\"Ada\",\"country\":\"DK\"},\"total\":99}," ++
            "{\"id\":2,\"customer\":{\"name\":\"Bob\",\"country\":\"UK\"},\"total\":149}]," ++
            "\"servers\":{\"alpha\":{\"host\":\"a\",\"port\":1},\"beta\":{\"host\":\"b\",\"port\":2}}," ++
            "\"mixed\":[1,[2,3],{\"a\":1},{\"t\":[{\"x\":1},{\"x\":2}]}]}",
        .{},
    );
    defer parsed.deinit();

    var saw_success = false;
    for (0..1024) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (toon.renderPlanToon(failing.allocator(), parsed.value)) |output| {
            failing.allocator().free(output);
            saw_success = true;
        } else |_| {}
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (saw_success and !failing.has_induced_failure) break;
    }
    try std.testing.expect(saw_success);
}

test "prompt rendering releases allocations at every OOM point" {
    const context: prompts.PromptContext = .{
        .objective = "check allocation cleanup",
        .loop_id = "audit-1",
        .turn_number = 2,
        .tokens_used = 100,
        .token_budget = 1000,
        .max_turns = 5,
        .elapsed_seconds = 3,
        .timeout_seconds = 60,
        .blocked_strikes = 0,
        .last_verifier_feedback = "retry with evidence",
    };

    var saw_success = false;
    for (0..8) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (prompts.renderVerifierPrompt(failing.allocator(), context)) |output| {
            failing.allocator().free(output);
            saw_success = true;
        } else |_| {}
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (saw_success and !failing.has_induced_failure) break;
    }
    try std.testing.expect(saw_success);
}

test "route encoding and parsing release allocations at every OOM point" {
    var saw_encode_success = false;
    for (0..16) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (routes.encodeArtifactPath(failing.allocator(), "project/plan one.html")) |value| {
            failing.allocator().free(value);
            saw_encode_success = true;
        } else |_| {}
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (saw_encode_success and !failing.has_induced_failure) break;
    }
    try std.testing.expect(saw_encode_success);

    var saw_parse_success = false;
    for (0..16) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (routes.parseArtifactRoute(failing.allocator(), "/artifacts/project/plan%20one.html")) |value| {
            failing.allocator().free(value);
            saw_parse_success = true;
        } else |_| {}
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (saw_parse_success and !failing.has_induced_failure) break;
    }
    try std.testing.expect(saw_parse_success);
}

test "home path expansion releases allocations at every OOM point" {
    var saw_success = false;
    for (0..8) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (path.expandHomePath(failing.allocator(), "~/matcha/a.json")) |value| {
            if (path.isHomeRelative("~/matcha/a.json")) failing.allocator().free(value);
            saw_success = true;
        } else |_| {}
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (saw_success and !failing.has_induced_failure) break;
    }
    try std.testing.expect(saw_success);
}

test "backend argument construction releases partial allocations at every OOM point" {
    var saw_success = false;
    for (0..64) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (backend.buildArgv(failing.allocator(), .{
            .backend = .codex,
            .model = "audit-model",
            .extra_args = &.{ "--flag-a", "value-a" },
        }, "loop-dir", null, "prompt.md")) |result| {
            var owned = result;
            owned.deinit();
            saw_success = true;
        } else |_| {}
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (saw_success and !failing.has_induced_failure) break;
    }
    try std.testing.expect(saw_success);
}

test "loop option parsing releases partial prompt allocations at every OOM point" {
    const args = [_][]const u8{ "first", "second", "third" };
    var saw_success = false;
    for (0..16) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const result = loop_options.parseLoopCommand(failing.allocator(), &args, true, "");
        switch (result) {
            .ok => |command| switch (command) {
                .run => |run_options| {
                    failing.allocator().free(run_options.prompt);
                    saw_success = true;
                },
                else => {},
            },
            .err => {},
        }
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (saw_success and !failing.has_induced_failure) break;
    }
    try std.testing.expect(saw_success);
}

test "JSON document reading releases allocations at every OOM point" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const input_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.zig-cache/tmp/{s}/input.json", .{ cwd, tmp.sub_path });
    defer std.testing.allocator.free(input_path);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "input.json",
        .data = "{\"title\":\"audit\",\"items\":[1,2,3]}\n",
    });

    var saw_success = false;
    for (0..64) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (json_input.readJsonDocument(std.testing.io, failing.allocator(), input_path)) |document| {
            var owned = document;
            owned.deinit();
            saw_success = true;
        } else |_| {}
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (saw_success and !failing.has_induced_failure) break;
    }
    try std.testing.expect(saw_success);
}

test "plan read parsing releases allocations at every OOM point" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const input_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.zig-cache/tmp/{s}/plan.json", .{ cwd, tmp.sub_path });
    defer std.testing.allocator.free(input_path);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "plan.json",
        .data = "{\"title\":\"audit\",\"sections\":[{\"name\":\"one\"}]}\n",
    });
    const args = [_][]const u8{input_path};

    var saw_success = false;
    for (0..64) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (plan_read.parsePlanReadInput(std.testing.io, failing.allocator(), &args)) |document| {
            var owned = document;
            owned.deinit();
            saw_success = true;
        } else |_| {}
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (saw_success and !failing.has_induced_failure) break;
    }
    try std.testing.expect(saw_success);
}

test "catalog scanning releases partial allocations at every OOM point" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(std.testing.allocator);
    try html.appendSlice(std.testing.allocator, "<html><script type=\"application/json\" id=\"plan-data\">{\"title\":\"");
    try html.appendNTimes(std.testing.allocator, 'x', 2048);
    try html.appendSlice(std.testing.allocator, "\",\"project\":\"demo\"}</script></html>");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "plan.html",
        .data = html.items,
    });
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const root = try std.fmt.allocPrint(std.testing.allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd, tmp.sub_path });
    defer std.testing.allocator.free(root);

    var saw_success = false;
    for (0..128) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (catalog.scan(std.testing.io, failing.allocator(), root)) |result| {
            catalog.freeScanResult(failing.allocator(), result);
            saw_success = true;
        } else |_| {}
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (saw_success and !failing.has_induced_failure) break;
    }
    try std.testing.expect(saw_success);
}

test "catalog JSON rendering releases the transferred buffer on OOM" {
    var entries = [_]catalog.CatalogEntry{
        .{ .rel_path = "project/plan.html", .kind = .plan, .size = 2048, .mtime = .zero },
    };
    const built = catalog.Catalog{ .entries = entries[0..], .warnings = &.{} };
    var saw_success = false;
    var saw_induced_failure = false;
    for (0..256) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (catalog.catalogJsonAlloc(failing.allocator(), &built)) |json| {
            failing.allocator().free(json);
            saw_success = true;
        } else |_| {
            saw_induced_failure = saw_induced_failure or failing.has_induced_failure;
        }
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
    try std.testing.expect(saw_success);
    try std.testing.expect(saw_induced_failure);
}

test "JSONL stream processing releases partial allocations at every OOM point" {
    const input = "{\"type\":\"thread.started\",\"thread_id\":\"audit-session\"}\n" ++
        "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"some progress\"}}\n";
    var saw_success = false;
    for (0..64) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var reader: std.Io.Reader = .fixed(input);
        var accumulator: stream.TurnAccumulator = .{};
        stream.readStream(failing.allocator(), &reader, .codex, &accumulator, null, ignoreStreamEvent) catch {};
        accumulator.deinit(failing.allocator());
        if (!failing.has_induced_failure) saw_success = true;
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (saw_success) break;
    }
    try std.testing.expect(saw_success);
}

test "loop config path allocation releases partial allocations" {
    var saw_success = false;
    for (0..16) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (loop_config.configPathAlloc(failing.allocator())) |path_value| {
            failing.allocator().free(path_value);
            saw_success = true;
        } else |_| {}
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (saw_success and !failing.has_induced_failure) break;
    }
    try std.testing.expect(saw_success);
}

test "loop summary rendering releases partial allocations" {
    const loop_state = loop_store.LoopState{
        .id = "audit",
        .backend = .codex,
        .cwd = ".",
        .objective = "audit",
        .started_at_ms = 0,
        .updated_at_ms = 0,
    };
    const history = "{\"turn\":1,\"role\":\"worker\",\"backend\":\"codex\",\"outcome\":\"continued\",\"summary\":\"first report\"}\n" ++
        "{\"turn\":2,\"role\":\"worker\",\"backend\":\"codex\",\"outcome\":\"complete\",\"summary\":\"final report passed\"}\n";
    var saw_success = false;
    for (0..64) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (loop_summary.render(failing.allocator(), loop_state, history)) |summary| {
            failing.allocator().free(summary);
            saw_success = true;
        } else |_| {}
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (saw_success and !failing.has_induced_failure) break;
    }
    try std.testing.expect(saw_success);
}
