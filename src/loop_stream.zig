const std = @import("std");
const options = @import("loop_options.zig");
const store = @import("loop_store.zig");

pub const BackendKind = options.BackendKind;

pub const ToolSummary = struct {
    name: []const u8,
    detail: []const u8 = "",
};

pub const TokenUsage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    total_tokens: u64 = 0,
};

pub const NormalizedEvent = union(enum) {
    session_id: []const u8,
    tool_call: ToolSummary,
    assistant_text: []const u8,
    token_usage: TokenUsage,
    error_message: []const u8,
    ignored: void,
};

pub const TurnAccumulator = struct {
    session_id: ?[]const u8 = null,
    tokens_used: u64 = 0,
    last_assistant_message: ?[]const u8 = null,
    had_error: bool = false,

    pub fn deinit(self: *TurnAccumulator, allocator: std.mem.Allocator) void {
        if (self.session_id) |value| allocator.free(value);
        if (self.last_assistant_message) |value| allocator.free(value);
        self.* = .{};
    }
};

pub const EventHandler = *const fn (?*anyopaque, NormalizedEvent) void;

pub const StreamError = std.Io.Reader.StreamError || std.mem.Allocator.Error;

pub const Presenter = struct {
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    mode: options.OutputMode,
    loop_id: []const u8,
    backend: BackendKind,
    turn_number: u32 = 0,
    role: store.TurnRole = .worker,
    pending_error: ?anyerror = null,
    last_error_message: ?[]const u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        mode: options.OutputMode,
        loop_id: []const u8,
        backend: BackendKind,
    ) Presenter {
        return .{ .allocator = allocator, .writer = writer, .mode = mode, .loop_id = loop_id, .backend = backend };
    }

    pub fn deinit(self: *Presenter) void {
        if (self.last_error_message) |message| self.allocator.free(message);
        self.last_error_message = null;
    }

    pub fn loopStarted(self: *Presenter) !void {
        switch (self.mode) {
            .live => {
                try self.writer.print("=== [loop {s} started | {s}] ===\n", .{ self.loop_id, @tagName(self.backend) });
                try self.flush();
            },
            .quiet => {},
            .json => try self.writeJson(.{ .type = "loop.started", .loop_id = self.loop_id, .backend = @tagName(self.backend) }),
        }
    }

    pub fn turnStarted(self: *Presenter, turn_number: u32, role: store.TurnRole, tokens_used: u64) !void {
        if (self.last_error_message) |message| self.allocator.free(message);
        self.last_error_message = null;
        self.turn_number = turn_number;
        self.role = role;
        switch (self.mode) {
            .live => {
                try self.writer.print("=== [loop {s} | turn {d} | {s}:{s} | {d} tok] ===\n", .{ self.loop_id, turn_number, @tagName(role), @tagName(self.backend), tokens_used });
                try self.flush();
            },
            .quiet => {
                try self.writer.print("[turn {d}]\n", .{turn_number});
                try self.flush();
            },
            .json => try self.writeJson(.{
                .type = "turn.started",
                .loop_id = self.loop_id,
                .turn = turn_number,
                .role = @tagName(role),
                .backend = @tagName(self.backend),
                .tokens_used = tokens_used,
            }),
        }
    }

    pub fn handleEvent(self: *Presenter, event: NormalizedEvent) !void {
        switch (event) {
            .session_id => |session_id| switch (self.mode) {
                .live => {
                    try self.writer.print("  session: {s}\n", .{session_id});
                    try self.flush();
                },
                .quiet => {},
                .json => try self.writeJson(.{ .type = "turn.session", .loop_id = self.loop_id, .turn = self.turn_number, .session_id = session_id }),
            },
            .tool_call => |tool| switch (self.mode) {
                .live => {
                    try self.writer.writeAll("  -> ");
                    try writeOneLine(self.writer, tool.name, 48);
                    if (tool.detail.len > 0) {
                        try self.writer.writeAll(": ");
                        try writeOneLine(self.writer, tool.detail, 144);
                    }
                    try self.writer.writeByte('\n');
                    try self.flush();
                },
                .quiet => {},
                .json => try self.writeJson(.{ .type = "turn.tool", .loop_id = self.loop_id, .turn = self.turn_number, .tool = tool.name, .detail = tool.detail }),
            },
            .assistant_text => |text| switch (self.mode) {
                .live => {
                    try self.writer.writeAll("  assistant: ");
                    try self.writer.writeAll(text);
                    if (text.len == 0 or text[text.len - 1] != '\n') try self.writer.writeByte('\n');
                    try self.flush();
                },
                .quiet => {},
                .json => try self.writeJson(.{ .type = "turn.assistant", .loop_id = self.loop_id, .turn = self.turn_number, .text = text }),
            },
            .token_usage => {},
            .error_message => |message| {
                const copy = try self.allocator.dupe(u8, message);
                if (self.last_error_message) |old| self.allocator.free(old);
                self.last_error_message = copy;
                switch (self.mode) {
                    .live => {
                        try self.writer.writeAll("  error: ");
                        try writeOneLine(self.writer, message, 240);
                        try self.writer.writeByte('\n');
                        try self.flush();
                    },
                    .quiet, .json => {},
                }
            },
            .ignored => {},
        }
    }

    pub fn eventHandler(context: ?*anyopaque, event: NormalizedEvent) void {
        const self: *Presenter = @ptrCast(@alignCast(context.?));
        if (self.pending_error != null) return;
        self.handleEvent(event) catch |err| {
            self.pending_error = err;
        };
    }

    pub fn checkError(self: *Presenter) anyerror!void {
        if (self.pending_error) |err| {
            self.pending_error = null;
            return err;
        }
    }

    pub fn turnCompleted(self: *Presenter, status: store.LoopStatus, tokens_used: u64, elapsed_ms: u64) !void {
        switch (self.mode) {
            .live => {
                try self.writer.print("=== [turn {d} completed | {s} | {d} tok | {d} ms] ===\n", .{ self.turn_number, @tagName(status), tokens_used, elapsed_ms });
                try self.flush();
            },
            .quiet => {
                try self.writer.print("[turn {d}] status={s} tokens={d} elapsed={d}ms\n", .{ self.turn_number, @tagName(status), tokens_used, elapsed_ms });
                try self.flush();
            },
            .json => try self.writeJson(.{
                .type = "turn.completed",
                .loop_id = self.loop_id,
                .turn = self.turn_number,
                .role = @tagName(self.role),
                .backend = @tagName(self.backend),
                .status = @tagName(status),
                .tokens_used = tokens_used,
                .elapsed_ms = elapsed_ms,
                .error_message = self.last_error_message,
            }),
        }
    }

    pub fn statusChanged(self: *Presenter, previous: store.LoopStatus, next: store.LoopStatus) !void {
        switch (self.mode) {
            .live => {
                try self.writer.print("  status: {s} -> {s}\n", .{ @tagName(previous), @tagName(next) });
                try self.flush();
            },
            .quiet => {
                try self.writer.print("[loop {s}] status: {s} -> {s}\n", .{ self.loop_id, @tagName(previous), @tagName(next) });
                try self.flush();
            },
            .json => try self.writeJson(.{ .type = "loop.status_changed", .loop_id = self.loop_id, .from = @tagName(previous), .to = @tagName(next) }),
        }
    }

    pub fn loopFinished(self: *Presenter, status: store.LoopStatus, turns_completed: u32, tokens_used: u64, outcome: []const u8) !void {
        switch (self.mode) {
            .live => {
                try self.writer.print("=== [loop {s} finished | {s} | {d} turns | {d} tok] ===\n{s}\n", .{ self.loop_id, @tagName(status), turns_completed, tokens_used, outcome });
                try self.flush();
            },
            .quiet => {
                try self.writer.print("[loop {s}] finished status={s} turns={d} tokens={d}: {s}\n", .{ self.loop_id, @tagName(status), turns_completed, tokens_used, outcome });
                try self.flush();
            },
            .json => try self.writeJson(.{
                .type = "loop.finished",
                .loop_id = self.loop_id,
                .status = @tagName(status),
                .turns_completed = turns_completed,
                .tokens_used = tokens_used,
                .outcome = outcome,
            }),
        }
    }

    fn writeJson(self: *Presenter, value: anytype) !void {
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(encoded);
        try self.writer.writeAll(encoded);
        try self.writer.writeByte('\n');
        try self.flush();
    }

    fn flush(self: *Presenter) !void {
        try self.writer.flush();
    }
};

fn writeOneLine(writer: *std.Io.Writer, text: []const u8, limit: usize) !void {
    const clipped = truncateUtf8(text, limit);
    for (clipped) |byte| {
        try writer.writeByte(if (byte == '\n' or byte == '\r' or byte == '\t') ' ' else byte);
    }
    if (clipped.len < text.len) try writer.writeAll("…");
}

fn truncateUtf8(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var end = limit;
    while (end > 0 and end < text.len and (text[end] & 0xc0) == 0x80) : (end -= 1) {}
    return text[0..end];
}

/// Consumes JSONL one line at a time. Callback string slices are valid only until
/// the callback returns; copy them if they must outlive this event. Accumulator
/// strings are owned by `allocator` and remain valid until `deinit`.
pub fn readStream(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    backend: BackendKind,
    accumulator: *TurnAccumulator,
    context: ?*anyopaque,
    handler: EventHandler,
) StreamError!void {
    var line_arena = std.heap.ArenaAllocator.init(allocator);
    defer line_arena.deinit();

    while (true) {
        _ = line_arena.reset(.retain_capacity);
        var line_writer = std.Io.Writer.Allocating.init(line_arena.allocator());
        const line_result = reader.streamDelimiter(&line_writer.writer, '\n');
        const at_eof = if (line_result) |_| false else |err| switch (err) {
            error.EndOfStream => true,
            error.ReadFailed, error.WriteFailed => return err,
        };
        if (!at_eof) {
            const delimiter = reader.takeByte() catch |err| switch (err) {
                error.EndOfStream => return error.ReadFailed,
                else => |e| return e,
            };
            if (delimiter != '\n') return error.ReadFailed;
        }

        const line = std.mem.trimEnd(u8, line_writer.written(), "\r");
        if (at_eof and line.len == 0) return;
        try processLine(allocator, line_arena.allocator(), line, backend, accumulator, context, handler);
        if (at_eof) return;
    }
}

fn processLine(
    accumulator_allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    line: []const u8,
    backend: BackendKind,
    accumulator: *TurnAccumulator,
    context: ?*anyopaque,
    handler: EventHandler,
) std.mem.Allocator.Error!void {
    if (line.len == 0) {
        handler(context, .ignored);
        return;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, arena, line, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            handler(context, .ignored);
            return;
        },
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        handler(context, .ignored);
        return;
    }

    var emitted = false;
    if (findSessionId(parsed.value)) |session_id| {
        if (accumulator.session_id == null or !std.mem.eql(u8, accumulator.session_id.?, session_id)) {
            const owned = try accumulator_allocator.dupe(u8, session_id);
            if (accumulator.session_id) |old| accumulator_allocator.free(old);
            accumulator.session_id = owned;
            handler(context, .{ .session_id = session_id });
            emitted = true;
        }
    }

    switch (backend) {
        .codex => try processCodex(accumulator_allocator, parsed.value, accumulator, context, handler, &emitted),
        .droid => try processDroid(accumulator_allocator, parsed.value, accumulator, context, handler, &emitted),
        .agy => try processAgy(accumulator_allocator, parsed.value, accumulator, context, handler, &emitted),
    }
    if (!emitted) handler(context, .ignored);
}

fn processCodex(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    accumulator: *TurnAccumulator,
    context: ?*anyopaque,
    handler: EventHandler,
    emitted: *bool,
) std.mem.Allocator.Error!void {
    const kind = stringField(root, "type") orelse return;
    if (std.mem.eql(u8, kind, "thread.started")) return;
    if (std.mem.startsWith(u8, kind, "item.")) {
        const item = field(root, "item") orelse return;
        const item_type = stringField(item, "type") orelse "";
        if (std.mem.eql(u8, item_type, "agent_message")) {
            if (std.mem.eql(u8, kind, "item.completed")) {
                if (stringField(item, "text")) |text| try emitAssistant(allocator, accumulator, text, false, context, handler, emitted);
            }
        } else if (std.mem.eql(u8, item_type, "error")) {
            const message = stringField(item, "message") orelse "Codex item failed";
            accumulator.had_error = true;
            handler(context, .{ .error_message = message });
            emitted.* = true;
        } else if (isCodexTool(item_type)) {
            const name = stringField(item, "tool_name") orelse item_type;
            const detail = stringField(item, "command") orelse stringField(item, "title") orelse "";
            handler(context, .{ .tool_call = .{ .name = name, .detail = detail } });
            emitted.* = true;
        }
        return;
    }
    if (std.mem.eql(u8, kind, "turn.completed")) {
        if (field(root, "usage")) |usage_value| emitUsage(usage_value, accumulator, context, handler, emitted);
        return;
    }
    if (std.mem.eql(u8, kind, "turn.failed") or std.mem.eql(u8, kind, "error")) {
        const error_value = field(root, "error") orelse root;
        const message = stringField(error_value, "message") orelse "Codex turn failed";
        accumulator.had_error = true;
        handler(context, .{ .error_message = message });
        emitted.* = true;
    }
}

fn processDroid(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    accumulator: *TurnAccumulator,
    context: ?*anyopaque,
    handler: EventHandler,
    emitted: *bool,
) std.mem.Allocator.Error!void {
    const kind = stringField(root, "type") orelse return;
    if (std.mem.eql(u8, kind, "system")) return;

    if (std.mem.eql(u8, kind, "tool_call") or std.mem.eql(u8, kind, "tool_use") or std.mem.eql(u8, kind, "tool_result")) {
        emitToolFromObject(root, context, handler, emitted);
        return;
    }
    if (std.mem.eql(u8, kind, "assistant") or std.mem.eql(u8, kind, "message")) {
        const message = field(root, "message") orelse root;
        try emitMessageContent(allocator, message, accumulator, context, handler, emitted, false);
        return;
    }
    if (std.mem.eql(u8, kind, "completion") or std.mem.eql(u8, kind, "result")) {
        const result = field(root, "result") orelse root;
        if (stringValue(result)) |text| try emitAssistant(allocator, accumulator, text, false, context, handler, emitted) else if (stringField(result, "response")) |text| try emitAssistant(allocator, accumulator, text, false, context, handler, emitted);
        if (field(root, "usage") orelse field(result, "usage")) |usage_value| emitUsage(usage_value, accumulator, context, handler, emitted);
        const is_error = boolField(root, "is_error") orelse boolField(result, "is_error") orelse false;
        if (is_error) {
            const error_value = field(result, "error") orelse field(root, "error");
            const message = stringValue(error_value orelse .null) orelse
                stringField(error_value orelse .null, "message") orelse
                stringValue(result) orelse "Droid turn failed";
            accumulator.had_error = true;
            handler(context, .{ .error_message = message });
            emitted.* = true;
        }
        return;
    }
    if (std.mem.eql(u8, kind, "usage")) {
        emitUsage(field(root, "usage") orelse root, accumulator, context, handler, emitted);
    }
}

fn processAgy(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    accumulator: *TurnAccumulator,
    context: ?*anyopaque,
    handler: EventHandler,
    emitted: *bool,
) std.mem.Allocator.Error!void {
    const kind = stringField(root, "event") orelse stringField(root, "type") orelse return;
    if (std.mem.eql(u8, kind, "init") or std.mem.eql(u8, kind, "heartbeat")) return;
    if (std.mem.eql(u8, kind, "step_update")) {
        const step = field(root, "step_update") orelse root;
        const step_type = stringField(step, "step_type") orelse "";
        if (std.mem.eql(u8, step_type, "tool") or field(step, "tool_info") != null) {
            const info = field(step, "tool_info") orelse step;
            const name = stringField(info, "name") orelse stringField(info, "tool_name") orelse "tool";
            const detail = stringField(info, "description") orelse stringField(info, "command") orelse "";
            handler(context, .{ .tool_call = .{ .name = name, .detail = detail } });
            emitted.* = true;
        }
        if (std.mem.eql(u8, step_type, "agent_response")) {
            if (stringField(step, "text_delta")) |text| try emitAssistant(allocator, accumulator, text, true, context, handler, emitted) else if (stringField(step, "text")) |text| try emitAssistant(allocator, accumulator, text, false, context, handler, emitted);
        }
        return;
    }
    if (std.mem.eql(u8, kind, "result")) {
        const result = field(root, "result") orelse root;
        if (stringField(result, "response")) |text| try emitAssistant(allocator, accumulator, text, false, context, handler, emitted);
        if (field(result, "usage")) |usage_value| emitUsage(usage_value, accumulator, context, handler, emitted);
        const status = stringField(result, "status") orelse "";
        if (std.mem.eql(u8, status, "ERROR") or field(result, "error") != null) {
            const error_value = field(result, "error");
            const message = stringValue(error_value orelse .null) orelse
                stringField(error_value orelse .null, "message") orelse "Antigravity turn failed";
            accumulator.had_error = true;
            handler(context, .{ .error_message = message });
            emitted.* = true;
        }
        return;
    }
    if (std.mem.eql(u8, kind, "usage")) {
        emitUsage(field(root, "usage") orelse root, accumulator, context, handler, emitted);
    }
}

fn emitAssistant(
    allocator: std.mem.Allocator,
    accumulator: *TurnAccumulator,
    text: []const u8,
    append: bool,
    context: ?*anyopaque,
    handler: EventHandler,
    emitted: *bool,
) std.mem.Allocator.Error!void {
    if (append and accumulator.last_assistant_message != null) {
        const old = accumulator.last_assistant_message.?;
        const joined_len = std.math.add(usize, old.len, text.len) catch return error.OutOfMemory;
        const joined = try allocator.alloc(u8, joined_len);
        @memcpy(joined[0..old.len], old);
        @memcpy(joined[old.len..], text);
        allocator.free(old);
        accumulator.last_assistant_message = joined;
    } else {
        const owned = try allocator.dupe(u8, text);
        if (accumulator.last_assistant_message) |old| allocator.free(old);
        accumulator.last_assistant_message = owned;
    }
    handler(context, .{ .assistant_text = text });
    emitted.* = true;
}

fn emitUsage(value: std.json.Value, accumulator: *TurnAccumulator, context: ?*anyopaque, handler: EventHandler, emitted: *bool) void {
    const input = numberField(value, "input_tokens") orelse numberField(value, "inputTokens") orelse numberField(value, "prompt_tokens") orelse 0;
    const output = numberField(value, "output_tokens") orelse numberField(value, "outputTokens") orelse numberField(value, "completion_tokens") orelse 0;
    const total = numberField(value, "total_tokens") orelse numberField(value, "totalTokens") orelse input +| output;
    if (input == 0 and output == 0 and total == 0) return;
    accumulator.tokens_used = @max(accumulator.tokens_used, total);
    handler(context, .{ .token_usage = .{ .input_tokens = input, .output_tokens = output, .total_tokens = total } });
    emitted.* = true;
}

fn emitToolFromObject(value: std.json.Value, context: ?*anyopaque, handler: EventHandler, emitted: *bool) void {
    const name = stringField(value, "tool_name") orelse stringField(value, "toolName") orelse stringField(value, "name") orelse stringField(value, "tool") orelse "tool";
    const detail = stringField(value, "command") orelse stringField(value, "description") orelse "";
    handler(context, .{ .tool_call = .{ .name = name, .detail = detail } });
    emitted.* = true;
}

fn emitMessageContent(
    allocator: std.mem.Allocator,
    message: std.json.Value,
    accumulator: *TurnAccumulator,
    context: ?*anyopaque,
    handler: EventHandler,
    emitted: *bool,
    append: bool,
) std.mem.Allocator.Error!void {
    if (stringValue(message)) |text| {
        try emitAssistant(allocator, accumulator, text, append, context, handler, emitted);
        return;
    }
    if (stringField(message, "text")) |text| try emitAssistant(allocator, accumulator, text, append, context, handler, emitted);
    const content = field(message, "content") orelse return;
    if (content == .array) {
        for (content.array.items) |part| {
            const part_type = stringField(part, "type") orelse "";
            if (std.mem.eql(u8, part_type, "tool_use") or std.mem.eql(u8, part_type, "tool_call")) {
                emitToolFromObject(part, context, handler, emitted);
            } else if (std.mem.eql(u8, part_type, "text")) {
                if (stringField(part, "text")) |text| try emitAssistant(allocator, accumulator, text, append, context, handler, emitted);
            }
        }
    } else if (stringValue(content)) |text| {
        try emitAssistant(allocator, accumulator, text, append, context, handler, emitted);
    }
}

fn findSessionId(root: std.json.Value) ?[]const u8 {
    const keys = [_][]const u8{ "thread_id", "session_id", "sessionId", "conversation_id", "conversationId" };
    if (stringFieldAny(root, &keys)) |id| return id;
    const nested_keys = [_][]const u8{ "system", "step_update", "result" };
    for (nested_keys) |key| if (field(root, key)) |nested| {
        if (stringFieldAny(nested, &keys)) |id| return id;
    };
    return null;
}

fn isCodexTool(item_type: []const u8) bool {
    return std.mem.eql(u8, item_type, "command_execution") or
        std.mem.eql(u8, item_type, "mcp_tool_call") or
        std.mem.eql(u8, item_type, "collab_tool_call") or
        std.mem.eql(u8, item_type, "file_change") or
        std.mem.eql(u8, item_type, "web_search") or
        std.mem.eql(u8, item_type, "tool_call");
}

fn field(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn stringValue(value: std.json.Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    const found = field(value, key) orelse return null;
    return stringValue(found);
}

fn stringFieldAny(value: std.json.Value, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| if (stringField(value, key)) |result| return result;
    return null;
}

fn numberField(value: std.json.Value, key: []const u8) ?u64 {
    const found = field(value, key) orelse return null;
    return switch (found) {
        .integer => |number| if (number >= 0) @as(u64, @intCast(number)) else null,
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch null,
        else => null,
    };
}

fn boolField(value: std.json.Value, key: []const u8) ?bool {
    const found = field(value, key) orelse return null;
    return if (found == .bool) found.bool else null;
}

test "normalizes Codex session, tool, assistant, token, and ignored events" {
    const input =
        \\{"type":"thread.started","thread_id":"thread-1"}
        \\{"type":"item.started","item":{"type":"command_execution","command":"zig test"}}
        \\{"type":"item.completed","item":{"type":"agent_message","text":"tests pass"}}
        \\{"type":"turn.completed","usage":{"input_tokens":12,"output_tokens":4}}
        \\{"type":"future.event","value":true}
        \\banner from shell
    ;
    var reader: std.Io.Reader = .fixed(input);
    var accumulator: TurnAccumulator = .{};
    defer accumulator.deinit(std.testing.allocator);
    var capture = Capture.init(std.testing.allocator);
    defer capture.deinit();
    try readStream(std.testing.allocator, &reader, .codex, &accumulator, &capture, Capture.handle);
    try std.testing.expectEqualStrings("thread-1", accumulator.session_id.?);
    try std.testing.expectEqual(@as(u64, 16), accumulator.tokens_used);
    try std.testing.expectEqualStrings("tests pass", accumulator.last_assistant_message.?);
    try std.testing.expect(capture.count(.session_id) == 1);
    try std.testing.expectEqual(@as(std.meta.Tag(NormalizedEvent), .session_id), capture.events.items[0].kind);
    try std.testing.expect(capture.count(.tool_call) == 1);
    try std.testing.expect(capture.count(.token_usage) == 1);
    try std.testing.expect(capture.count(.ignored) == 2);
}

test "normalizes Droid final response, tool activity, session, and usage" {
    const input =
        \\{"type":"system","subtype":"init","session_id":"droid-1"}
        \\{"type":"tool_call","toolName":"Read","input":{"file_path":"a"}}
        \\{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"working"}]}}
        \\{"type":"completion","result":"finished","usage":{"input_tokens":9,"output_tokens":3},"session_id":"droid-1"}
    ;
    var reader: std.Io.Reader = .fixed(input);
    var accumulator: TurnAccumulator = .{};
    defer accumulator.deinit(std.testing.allocator);
    var capture = Capture.init(std.testing.allocator);
    defer capture.deinit();
    try readStream(std.testing.allocator, &reader, .droid, &accumulator, &capture, Capture.handle);
    try std.testing.expectEqualStrings("droid-1", accumulator.session_id.?);
    try std.testing.expectEqual(@as(u64, 12), accumulator.tokens_used);
    try std.testing.expectEqualStrings("finished", accumulator.last_assistant_message.?);
    try std.testing.expect(capture.count(.tool_call) == 1);
}

test "normalizes Antigravity chunked text and cumulative terminal usage" {
    const input =
        \\{"event":"init","conversation_id":"agy-1"}
        \\{"event":"step_update","step_update":{"conversation_id":"agy-1","step_type":"tool","tool_info":{"name":"read_file"}}}
        \\{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"hello "}}
        \\{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"world"}}
        \\{"event":"result","result":{"conversation_id":"agy-1","status":"SUCCESS","response":"hello world","usage":{"input_tokens":20,"output_tokens":2,"total_tokens":22}}}
    ;
    var reader: std.Io.Reader = .fixed(input);
    var accumulator: TurnAccumulator = .{};
    defer accumulator.deinit(std.testing.allocator);
    var capture = Capture.init(std.testing.allocator);
    defer capture.deinit();
    try readStream(std.testing.allocator, &reader, .agy, &accumulator, &capture, Capture.handle);
    try std.testing.expectEqualStrings("agy-1", accumulator.session_id.?);
    try std.testing.expectEqual(@as(u64, 22), accumulator.tokens_used);
    try std.testing.expectEqualStrings("hello world", accumulator.last_assistant_message.?);
    try std.testing.expect(capture.count(.tool_call) == 1);
}

test "streams oversized JSON lines through a small reader buffer" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try input.appendSlice(std.testing.allocator, "{\"type\":\"tool_result\",\"toolName\":\"Bash\",\"result\":\"");
    try input.appendNTimes(std.testing.allocator, 'x', 128 * 1024);
    try input.appendSlice(std.testing.allocator, "\"}\nnot json\n");

    var fixed: std.Io.Reader = .fixed(input.items);
    var small_buffer: [32]u8 = undefined;
    var limited = fixed.limited(.unlimited, &small_buffer);
    var accumulator: TurnAccumulator = .{};
    defer accumulator.deinit(std.testing.allocator);
    var capture = Capture.init(std.testing.allocator);
    defer capture.deinit();
    try readStream(std.testing.allocator, &limited.interface, .droid, &accumulator, &capture, Capture.handle);
    try std.testing.expect(capture.count(.tool_call) == 1);
    try std.testing.expect(capture.count(.ignored) == 1);
}

test "live, quiet, and json presenters format same turn events" {
    const allocator = std.testing.allocator;
    const live = try renderPresenterForTest(.live);
    defer allocator.free(live);
    const quiet = try renderPresenterForTest(.quiet);
    defer allocator.free(quiet);
    const json = try renderPresenterForTest(.json);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, live, "=== [loop loop-test | turn 2 | worker:codex | 100 tok] ===") != null);
    try std.testing.expect(std.mem.indexOf(u8, live, "  -> Read: /repo/src/main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, live, "  assistant: done") != null);
    try std.testing.expect(std.mem.indexOf(u8, live, "| 112 tok | 35 ms]") != null);
    try std.testing.expect(std.mem.indexOf(u8, live, "\n  -> Read: /repo/other") == null);

    try std.testing.expect(std.mem.indexOf(u8, quiet, "[turn 2]\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "status=verifying tokens=112 elapsed=35ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "status: active -> verifying") != null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "finished status=complete") != null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "-> Read") == null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "assistant:") == null);

    const expected_types = [_][]const u8{
        "loop.started",
        "turn.started",
        "turn.session",
        "turn.tool",
        "turn.assistant",
        "turn.completed",
        "loop.status_changed",
        "loop.finished",
    };
    var lines = std.mem.tokenizeScalar(u8, json, '\n');
    for (expected_types) |expected| {
        const line = lines.next() orelse return error.MissingJsonEvent;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const actual = parsed.value.object.get("type").?.string;
        try std.testing.expectEqualStrings(expected, actual);
    }
    try std.testing.expect(lines.next() == null);
}

fn renderPresenterForTest(mode: options.OutputMode) ![]u8 {
    const allocator = std.testing.allocator;
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var presenter = Presenter.init(allocator, &output.writer, mode, "loop-test", .codex);
    defer presenter.deinit();
    var long_detail: [4096]u8 = @splat('x');
    try presenter.loopStarted();
    try presenter.turnStarted(2, .worker, 100);
    try presenter.handleEvent(.{ .session_id = "session-1" });
    try presenter.handleEvent(.{ .tool_call = .{ .name = "Read", .detail = "/repo/src/main.zig\n" ++ &long_detail } });
    try presenter.handleEvent(.{ .assistant_text = "done\n" });
    try presenter.handleEvent(.{ .token_usage = .{ .input_tokens = 100, .output_tokens = 12, .total_tokens = 112 } });
    try presenter.turnCompleted(.verifying, 112, 35);
    try presenter.statusChanged(.active, .verifying);
    try presenter.loopFinished(.complete, 2, 112, "verified");
    return allocator.dupe(u8, output.written());
}

const Capture = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(CapturedEvent) = .empty,

    const CapturedEvent = struct {
        kind: std.meta.Tag(NormalizedEvent),
        name: ?[]const u8 = null,
        text: ?[]const u8 = null,
        usage: TokenUsage = .{},
    };

    fn init(allocator: std.mem.Allocator) Capture {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Capture) void {
        for (self.events.items) |event| {
            if (event.name) |value| self.allocator.free(value);
            if (event.text) |value| self.allocator.free(value);
        }
        self.events.deinit(self.allocator);
    }

    fn handle(context: ?*anyopaque, event: NormalizedEvent) void {
        const self: *Capture = @ptrCast(@alignCast(context.?));
        var captured: CapturedEvent = .{ .kind = std.meta.activeTag(event) };
        switch (event) {
            .session_id => |id| captured.text = self.allocator.dupe(u8, id) catch unreachable,
            .tool_call => |tool| {
                captured.name = self.allocator.dupe(u8, tool.name) catch unreachable;
                captured.text = self.allocator.dupe(u8, tool.detail) catch unreachable;
            },
            .assistant_text => |text| captured.text = self.allocator.dupe(u8, text) catch unreachable,
            .token_usage => |usage| captured.usage = usage,
            .error_message => |text| captured.text = self.allocator.dupe(u8, text) catch unreachable,
            .ignored => {},
        }
        self.events.append(self.allocator, captured) catch unreachable;
    }

    fn count(self: *const Capture, kind: std.meta.Tag(NormalizedEvent)) usize {
        var result: usize = 0;
        for (self.events.items) |event| if (event.kind == kind) {
            result += 1;
        };
        return result;
    }
};
