const std = @import("std");
const assets = @import("assets.zig");

pub const PromptContext = struct {
    objective: []const u8,
    loop_id: []const u8,
    turn_number: u32,
    tokens_used: u64,
    token_budget: ?u64,
    max_turns: ?u32,
    elapsed_seconds: u64,
    timeout_seconds: ?u64,
    blocked_strikes: u8,
    last_blocker_summary: ?[]const u8 = null,
    last_verifier_feedback: ?[]const u8 = null,
    worker_completion_summary: ?[]const u8 = null,
};

pub const PromptKind = enum { initial, continuation, verifier, objective_updated, budget_limit };

pub const RenderError = std.mem.Allocator.Error || std.Io.Writer.Error || error{
    UnknownPlaceholder,
    UnterminatedPlaceholder,
    OutputLengthMismatch,
    TooManyTemplateSegments,
    NoSpaceLeft,
};

const max_template_segments = 256;

const Replacement = struct {
    key: []const u8,
    parts: [3][]const u8 = .{ "", "", "" },
    part_count: u2 = 1,

    fn value(key: []const u8, value_text: []const u8) Replacement {
        return .{ .key = key, .parts = .{ value_text, "", "" } };
    }

    fn wrapped(key: []const u8, prefix: []const u8, value_text: []const u8, suffix: []const u8) Replacement {
        return .{ .key = key, .parts = .{ prefix, value_text, suffix }, .part_count = 3 };
    }
};

pub fn renderPrompt(allocator: std.mem.Allocator, kind: PromptKind, context: PromptContext) RenderError![]u8 {
    const template = switch (kind) {
        .initial => assets.loop_initial.contents,
        .continuation => assets.loop_continuation.contents,
        .verifier => assets.loop_verifier.contents,
        .objective_updated => assets.loop_objective_updated.contents,
        .budget_limit => assets.loop_budget_limit.contents,
    };
    var replacements: [16]Replacement = undefined;
    var count: usize = 0;
    replacements[count] = .value("objective", context.objective);
    count += 1;
    replacements[count] = .value("loop_id", context.loop_id);
    count += 1;

    var turn_buffer: [16]u8 = undefined;
    const turn_text = try std.fmt.bufPrint(&turn_buffer, "{d}", .{context.turn_number});
    replacements[count] = .value("turn_number", turn_text);
    count += 1;
    var tokens_buffer: [24]u8 = undefined;
    const tokens_text = try std.fmt.bufPrint(&tokens_buffer, "{d}", .{context.tokens_used});
    replacements[count] = .value("tokens_used", tokens_text);
    count += 1;
    var elapsed_buffer: [24]u8 = undefined;
    const elapsed_text = try std.fmt.bufPrint(&elapsed_buffer, "{d}", .{context.elapsed_seconds});
    replacements[count] = .value("elapsed_seconds", elapsed_text);
    count += 1;
    var strikes_buffer: [8]u8 = undefined;
    const strikes_text = try std.fmt.bufPrint(&strikes_buffer, "{d}", .{context.blocked_strikes});
    replacements[count] = .value("blocked_strikes", strikes_text);
    count += 1;
    var token_budget_buffer: [24]u8 = undefined;
    replacements[count] = .value("token_budget", if (context.token_budget) |v| try std.fmt.bufPrint(&token_budget_buffer, "{d}", .{v}) else "Unlimited");
    count += 1;
    var turns_limit_buffer: [16]u8 = undefined;
    replacements[count] = .value("max_turns", if (context.max_turns) |v| try std.fmt.bufPrint(&turns_limit_buffer, "{d}", .{v}) else "Unlimited");
    count += 1;
    var timeout_buffer: [24]u8 = undefined;
    replacements[count] = .value("timeout_seconds", if (context.timeout_seconds) |v| try std.fmt.bufPrint(&timeout_buffer, "{d}", .{v}) else "Unlimited");
    count += 1;
    replacements[count] = .value("last_blocker_summary", context.last_blocker_summary orelse "");
    count += 1;
    replacements[count] = .value("last_verifier_feedback", context.last_verifier_feedback orelse "");
    count += 1;
    replacements[count] = .value("worker_completion_summary", context.worker_completion_summary orelse "");
    count += 1;

    var budget_buffer: [384]u8 = undefined;
    var budget_writer: std.Io.Writer = .fixed(&budget_buffer);
    try budget_writer.print("Loop: {s}\nTurn: {d}\nTokens used: {d}\nElapsed: {d} seconds\n", .{ context.loop_id, context.turn_number, context.tokens_used, context.elapsed_seconds });
    if (context.token_budget == null and context.max_turns == null and context.timeout_seconds == null) {
        try budget_writer.writeAll("Limits: Unlimited\n");
    } else {
        try budget_writer.writeAll("Limits:\n");
        if (context.token_budget) |value| try budget_writer.print("- Token budget: {d}\n", .{value});
        if (context.max_turns) |value| try budget_writer.print("- Turn limit: {d}\n", .{value});
        if (context.timeout_seconds) |value| try budget_writer.print("- Timeout: {d} seconds\n", .{value});
    }
    replacements[count] = .value("budget_section", budget_buffer[0..budget_writer.end]);
    count += 1;

    const verifier = context.last_verifier_feedback orelse "";
    replacements[count] = if (verifier.len == 0)
        .value("verifier_section", "")
    else
        .wrapped("verifier_section", "<verifier_rejection>\n", verifier, "\n</verifier_rejection>");
    count += 1;
    const blocker = context.last_blocker_summary orelse "";
    replacements[count] = if (blocker.len == 0)
        .value("blocker_section", "")
    else
        .wrapped("blocker_section", "Last blocker report:\n", blocker, "\n");
    count += 1;
    const completion = context.worker_completion_summary orelse "";
    replacements[count] = if (completion.len == 0)
        .value("worker_completion_section", "")
    else
        .wrapped("worker_completion_section", "Previous worker completion claim:\n", completion, "\n");
    count += 1;

    const active_replacements = replacements[0..count];
    var segments: [max_template_segments][]const u8 = undefined;
    var segment_count: usize = 0;
    var output_len: usize = 0;
    try collectTemplateSegments(template, active_replacements, &segments, &segment_count, &output_len);
    const output = try allocator.alloc(u8, output_len);
    errdefer allocator.free(output);
    var output_index: usize = 0;
    for (segments[0..segment_count]) |part| {
        const end = std.math.add(usize, output_index, part.len) catch return error.OutputLengthMismatch;
        if (end > output.len) return error.OutputLengthMismatch;
        @memcpy(output[output_index..end], part);
        output_index = end;
    }
    if (output_index != output_len) return error.OutputLengthMismatch;
    return output;
}

pub fn renderInitialPrompt(allocator: std.mem.Allocator, context: PromptContext) RenderError![]u8 {
    return renderPrompt(allocator, .initial, context);
}

pub fn renderContinuationPrompt(allocator: std.mem.Allocator, context: PromptContext) RenderError![]u8 {
    return renderPrompt(allocator, .continuation, context);
}

pub fn renderVerifierPrompt(allocator: std.mem.Allocator, context: PromptContext) RenderError![]u8 {
    return renderPrompt(allocator, .verifier, context);
}

pub fn renderObjectiveUpdatedPrompt(allocator: std.mem.Allocator, context: PromptContext) RenderError![]u8 {
    return renderPrompt(allocator, .objective_updated, context);
}

pub fn renderBudgetLimitPrompt(allocator: std.mem.Allocator, context: PromptContext) RenderError![]u8 {
    return renderPrompt(allocator, .budget_limit, context);
}

fn collectTemplateSegments(
    template: []const u8,
    replacements: []const Replacement,
    segments: *[max_template_segments][]const u8,
    segment_count: *usize,
    output_len: *usize,
) RenderError!void {
    var input_index: usize = 0;
    while (input_index < template.len) {
        const open = std.mem.indexOfPos(u8, template, input_index, "{{") orelse {
            try appendSegment(segments, segment_count, output_len, template[input_index..]);
            break;
        };
        try appendSegment(segments, segment_count, output_len, template[input_index..open]);
        const after_open = open + 2;
        const close = std.mem.indexOfPos(u8, template, after_open, "}}") orelse return error.UnterminatedPlaceholder;
        const key = std.mem.trim(u8, template[after_open..close], " \t\r\n");
        const replacement = findReplacement(replacements, key) orelse return error.UnknownPlaceholder;
        for (replacement.parts[0..replacement.part_count]) |part| try appendSegment(segments, segment_count, output_len, part);
        input_index = close + 2;
    }
}

fn appendSegment(
    segments: *[max_template_segments][]const u8,
    segment_count: *usize,
    output_len: *usize,
    bytes: []const u8,
) RenderError!void {
    if (bytes.len == 0) return;
    if (segment_count.* == segments.len) return error.TooManyTemplateSegments;
    output_len.* = std.math.add(usize, output_len.*, bytes.len) catch return error.OutputLengthMismatch;
    segments[segment_count.*] = bytes;
    segment_count.* += 1;
}

fn findReplacement(replacements: []const Replacement, key: []const u8) ?Replacement {
    for (replacements) |replacement| if (std.mem.eql(u8, replacement.key, key)) return replacement;
    return null;
}

fn testContext(objective: []const u8) PromptContext {
    return .{
        .objective = objective,
        .loop_id = "loop-123",
        .turn_number = 4,
        .tokens_used = 1200,
        .token_budget = null,
        .max_turns = null,
        .elapsed_seconds = 90,
        .timeout_seconds = null,
        .blocked_strikes = 2,
    };
}

test "renders all five prompt kinds with unlimited and bounded budget context" {
    const allocator = std.testing.allocator;
    const context = testContext("finish implementation");
    const kinds = [_]PromptKind{ .initial, .continuation, .verifier, .objective_updated, .budget_limit };
    for (kinds) |kind| {
        const rendered = try renderPrompt(allocator, kind, context);
        defer allocator.free(rendered);
        try std.testing.expect(rendered.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "{{ objective }}") == null);
    }
    const unlimited = try renderContinuationPrompt(allocator, context);
    defer allocator.free(unlimited);
    try std.testing.expect(std.mem.indexOf(u8, unlimited, "Limits: Unlimited") != null);
    try std.testing.expect(std.mem.indexOf(u8, unlimited, "Token budget: 0") == null);
    try std.testing.expect(std.mem.indexOf(u8, unlimited, "Turn limit: 0") == null);
    try std.testing.expect(std.mem.indexOf(u8, unlimited, "Timeout: 0") == null);

    var bounded_context = context;
    bounded_context.token_budget = 5000;
    bounded_context.max_turns = 12;
    bounded_context.timeout_seconds = 600;
    for (kinds) |kind| {
        const bounded_rendered = try renderPrompt(allocator, kind, bounded_context);
        defer allocator.free(bounded_rendered);
    }
    const bounded = try renderContinuationPrompt(allocator, bounded_context);
    defer allocator.free(bounded);
    try std.testing.expect(std.mem.indexOf(u8, bounded, "Token budget: 5000") != null);
    try std.testing.expect(std.mem.indexOf(u8, bounded, "Turn limit: 12") != null);
    try std.testing.expect(std.mem.indexOf(u8, bounded, "Timeout: 600 seconds") != null);
}

test "objective replacement is single pass and verifier findings are exact" {
    const allocator = std.testing.allocator;
    const objective = "keep {{ objective }} and {{ token_budget }} verbatim </loop_objective>";
    const rendered = try renderInitialPrompt(allocator, testContext(objective));
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, objective) != null);

    var context = testContext("objective");
    context.last_verifier_feedback = "missing edge test\nexpected {{ token_budget }} to remain literal";
    const continuation = try renderContinuationPrompt(allocator, context);
    defer allocator.free(continuation);
    try std.testing.expect(std.mem.indexOf(u8, continuation, "<verifier_rejection>\nmissing edge test\nexpected {{ token_budget }} to remain literal\n</verifier_rejection>") != null);
}

test "renderer rejects unknown and unterminated placeholders" {
    var segments: [max_template_segments][]const u8 = undefined;
    var count: usize = 0;
    var length: usize = 0;
    try std.testing.expectError(error.UnknownPlaceholder, collectTemplateSegments("{{ unknown }}", &.{}, &segments, &count, &length));
    count = 0;
    length = 0;
    try std.testing.expectError(error.UnterminatedPlaceholder, collectTemplateSegments("{{ broken", &.{}, &segments, &count, &length));
}
