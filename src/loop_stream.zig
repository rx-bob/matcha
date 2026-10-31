const std = @import("std");
const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("unistd.h");
    @cInclude("termios.h");
    @cInclude("poll.h");
});
const options = @import("loop_options.zig");
const store = @import("loop_store.zig");

pub const BackendKind = options.BackendKind;

pub const ToolSummary = struct {
    name: []const u8,
    detail: []const u8 = "",
    id: ?[]const u8 = null,
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

const TextStyle = enum {
    state,
    green,
    assistant,
    command_latest,
    command_old,

    fn escape(self: TextStyle) []const u8 {
        return switch (self) {
            .state => "\x1b[38;2;255;165;0m",
            .green => "\x1b[38;2;144;238;144m",
            .command_latest => "\x1b[38;2;255;255;255m",
            .command_old => "\x1b[38;2;192;192;192m",
            .assistant => "\x1b[48;2;0;64;32m",
        };
    }
};

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
    final_summary: ?[]const u8 = null,
    io: ?std.Io = null,
    model: ?[]const u8 = null,
    max_turns: ?u32 = null,
    elapsed_base_seconds: u64 = 0,
    status_started_at: ?std.Io.Timestamp = null,
    terminal_ui: bool = false,
    terminal_rows: usize = 0,
    output_mutex: std.Io.Mutex = .init,
    stop_status_ticker: std.atomic.Value(bool) = .init(false),
    status_ticker: ?std.Thread = null,
    original_stdin_termios: c.struct_termios = undefined,
    stdin_raw: bool = false,
    stop_input_reader: std.atomic.Value(bool) = .init(false),
    input_reader: ?std.Thread = null,
    history: ?std.Io.Writer.Allocating = null,
    view_top: ?usize = null,
    style_spans: std.ArrayList(struct { start: usize, end: usize, style: TextStyle = .state, hidden: bool = false }) = .empty,

    command_spans: [3]usize = undefined,
    command_count: usize = 0,
    command_ids: std.ArrayList([]const u8) = .empty,
    plain_commands: std.ArrayList([]const u8) = .empty,

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
        self.stopStatusTicker();
        self.stopInputReader();
        if (self.io) |io| self.output_mutex.lockUncancelable(io);
        self.endTerminalUi() catch {};
        if (self.io) |io| self.output_mutex.unlock(io);
        if (self.last_error_message) |message| self.allocator.free(message);
        self.last_error_message = null;
        if (self.history) |*history| history.deinit();
        self.style_spans.deinit(self.allocator);
        for (self.command_ids.items) |id| self.allocator.free(id);
        self.command_ids.deinit(self.allocator);
        for (self.plain_commands.items) |command| self.allocator.free(command);
        self.plain_commands.deinit(self.allocator);
    }

    pub fn configureStatus(self: *Presenter, io: std.Io, model: ?[]const u8, max_turns: ?u32, elapsed_base_seconds: u64) void {
        self.io = io;
        self.model = model;
        self.max_turns = max_turns;
        self.elapsed_base_seconds = elapsed_base_seconds;
        self.status_started_at = std.Io.Clock.awake.now(io);
    }

    pub fn loopStarted(self: *Presenter) !void {
        try self.lockOutput();
        defer self.unlockOutput();
        switch (self.mode) {
            .live => {
                try self.beginTerminalUi();
                try self.printState("=== [loop {s} started | {s}] ===\n", .{ self.loop_id, @tagName(self.backend) });
                try self.updateStatusBar();
                try self.flush();
            },
            .quiet => {},
            .json => try self.writeJson(.{ .type = "loop.started", .loop_id = self.loop_id, .backend = @tagName(self.backend) }),
        }
    }

    pub fn turnStarted(self: *Presenter, turn_number: u32, role: store.TurnRole, tokens_used: u64) !void {
        try self.lockOutput();
        defer self.unlockOutput();
        if (self.last_error_message) |message| self.allocator.free(message);
        self.last_error_message = null;
        if (turn_number > 1 and self.mode != .json) try self.writeTurnSeparator();
        self.turn_number = turn_number;
        self.role = role;
        try self.updateStatusBar();
        switch (self.mode) {
            .live => {
                try self.printState("=== [loop {s} | turn {d} | {s}:{s} | {d} tok] ===\n", .{ self.loop_id, turn_number, @tagName(role), @tagName(self.backend), tokens_used });
                try self.flush();
            },
            .quiet => {
                try self.printState("[turn {d}]\n", .{turn_number});
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

    fn writeTurnSeparator(self: *Presenter) !void {
        const width = terminalColumns();
        const start = if (self.terminal_ui) self.history.?.written().len else 0;
        const direct_color = !self.terminal_ui and c.isatty(c.STDOUT_FILENO) == 1;
        if (direct_color) try self.writer.writeAll("\x1b[38;2;144;238;144m");
        var hashes: [128]u8 = undefined;
        @memset(&hashes, '#');
        for (0..2) |_| {
            var remaining = width;
            while (remaining > 0) {
                const count = @min(remaining, hashes.len);
                try self.bodyWriter().writeAll(hashes[0..count]);
                remaining -= count;
            }
            try self.bodyWriter().writeByte('\n');
        }
        if (self.terminal_ui) {
            try self.style_spans.append(self.allocator, .{ .start = start, .end = self.history.?.written().len, .style = .green });
        }
        if (direct_color) try self.writer.writeAll("\x1b[0m");
        try self.flush();
    }

    pub fn handleEvent(self: *Presenter, event: NormalizedEvent) !void {
        try self.lockOutput();
        defer self.unlockOutput();
        try self.updateStatusBar();
        switch (event) {
            .session_id => |session_id| switch (self.mode) {
                .live => {
                    try self.printState("  session: {s}\n", .{session_id});
                    try self.flush();
                },
                .quiet => {},
                .json => try self.writeJson(.{ .type = "turn.session", .loop_id = self.loop_id, .turn = self.turn_number, .session_id = session_id }),
            },
            .tool_call => |tool| switch (self.mode) {
                .live => {
                    if (isCommand(tool.name)) try self.recordCommand(tool);
                },
                .quiet => {},
                .json => try self.writeJson(.{ .type = "turn.tool", .loop_id = self.loop_id, .turn = self.turn_number, .tool = tool.name, .detail = tool.detail }),
            },
            .assistant_text => |text| switch (self.mode) {
                .live => {
                    try self.finishCommandGroup();
                    try self.printState("  assistant: ", .{});
                    try self.printStyled(.green, "\"", .{});
                    try self.printStyled(.assistant, "{s}", .{std.mem.trimEnd(u8, text, "\r\n")});
                    try self.printStyled(.green, "\"", .{});
                    try self.bodyWriter().writeByte('\n');
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
                        try self.bodyWriter().writeAll("  error: ");
                        try writeOneLine(self.bodyWriter(), message, 240);
                        try self.bodyWriter().writeByte('\n');
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
        try self.lockOutput();
        defer self.unlockOutput();
        try self.finishCommandGroup();
        try self.updateStatusBar();
        switch (self.mode) {
            .live => {
                try self.printState("=== [turn {d} completed | {s} | {d} tok | {d} ms] ===\n", .{ self.turn_number, @tagName(status), tokens_used, elapsed_ms });
                try self.flush();
            },
            .quiet => {
                try self.printState("[turn {d}] status={s} tokens={d} elapsed={d}ms\n", .{ self.turn_number, @tagName(status), tokens_used, elapsed_ms });
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
        try self.lockOutput();
        defer self.unlockOutput();
        try self.updateStatusBar();
        switch (self.mode) {
            .live => {
                try self.printState("  status: {s} -> {s}\n", .{ @tagName(previous), @tagName(next) });
                try self.flush();
            },
            .quiet => {
                try self.printState("[loop {s}] status: {s} -> {s}\n", .{ self.loop_id, @tagName(previous), @tagName(next) });
                try self.flush();
            },
            .json => try self.writeJson(.{ .type = "loop.status_changed", .loop_id = self.loop_id, .from = @tagName(previous), .to = @tagName(next) }),
        }
    }

    pub fn loopFinished(self: *Presenter, status: store.LoopStatus, turns_completed: u32, tokens_used: u64, outcome: []const u8) !void {
        self.stopStatusTicker();
        self.stopInputReader();
        try self.lockOutput();
        defer self.unlockOutput();
        try self.finishCommandGroup();
        try self.endTerminalUi();
        switch (self.mode) {
            .live => {
                try self.printState("=== [loop {s} finished | {s} | {d} turns | {d} tok] ===\n", .{ self.loop_id, @tagName(status), turns_completed, tokens_used });
                try self.bodyWriter().print("{s}\n", .{outcome});
                if (self.final_summary) |summary| {
                    try self.printState("\nSummary\n", .{});
                    try self.bodyWriter().print("{s}\n", .{summary});
                }
                try self.flush();
            },
            .quiet => {
                try self.printState("[loop {s}] finished status={s} turns={d} tokens={d}: {s}\n", .{ self.loop_id, @tagName(status), turns_completed, tokens_used, outcome });
                if (self.final_summary) |summary| try self.bodyWriter().print("Summary: {s}\n", .{summary});
                try self.flush();
            },
            .json => try self.writeJson(.{
                .type = "loop.finished",
                .loop_id = self.loop_id,
                .status = @tagName(status),
                .turns_completed = turns_completed,
                .tokens_used = tokens_used,
                .outcome = outcome,
                .summary = self.final_summary,
            }),
        }
    }

    fn writeJson(self: *Presenter, value: anytype) !void {
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(encoded);
        try self.bodyWriter().writeAll(encoded);
        try self.bodyWriter().writeByte('\n');
        try self.flush();
    }

    fn recordCommand(self: *Presenter, tool: ToolSummary) !void {
        if (tool.id) |id| {
            for (self.command_ids.items) |seen| if (std.mem.eql(u8, seen, id)) return;
            const copy = try self.allocator.dupe(u8, id);
            errdefer self.allocator.free(copy);
            try self.command_ids.append(self.allocator, copy);
        }
        var text = std.Io.Writer.Allocating.init(self.allocator);
        defer text.deinit();
        try text.writer.writeAll("Ran ");
        try writeOneLine(&text.writer, if (tool.detail.len > 0) tool.detail else tool.name, 512);
        try text.writer.writeByte('\n');
        if (self.terminal_ui) {
            if (self.command_count == 3) {
                self.style_spans.items[self.command_spans[0]].hidden = true;
                self.command_spans[0] = self.command_spans[1];
                self.command_spans[1] = self.command_spans[2];
                self.command_count = 2;
            }
            for (self.command_spans[0..self.command_count]) |index| self.style_spans.items[index].style = .command_old;
            self.command_spans[self.command_count] = self.style_spans.items.len;
            try self.printStyled(.command_latest, "{s}", .{text.written()});
            self.command_count += 1;
            try self.flush();
        } else {
            const copy = try self.allocator.dupe(u8, text.written());
            errdefer self.allocator.free(copy);
            try self.plain_commands.append(self.allocator, copy);
            if (self.plain_commands.items.len > 3) self.allocator.free(self.plain_commands.orderedRemove(0));
        }
    }

    fn finishCommandGroup(self: *Presenter) !void {
        for (self.plain_commands.items, 0..) |command, index| {
            try self.printStyled(if (index + 1 == self.plain_commands.items.len) .command_latest else .command_old, "{s}", .{command});
        }
        for (self.plain_commands.items) |command| self.allocator.free(command);
        self.plain_commands.clearRetainingCapacity();
        self.command_count = 0;
        for (self.command_ids.items) |id| self.allocator.free(id);
        self.command_ids.clearRetainingCapacity();
    }

    fn visibleHistoryRows(self: *Presenter) !std.ArrayList([]const u8) {
        var rows = try historyRows(self.allocator, self.history.?.written(), terminalColumns());
        var kept: usize = 0;
        var span_index: usize = 0;
        for (rows.items) |row| {
            const offset = @intFromPtr(row.ptr) - @intFromPtr(self.history.?.written().ptr);
            while (span_index < self.style_spans.items.len and self.style_spans.items[span_index].end <= offset) span_index += 1;
            if (span_index < self.style_spans.items.len) {
                const span = self.style_spans.items[span_index];
                if (span.hidden and offset >= span.start) continue;
            }
            rows.items[kept] = row;
            kept += 1;
        }
        rows.items.len = kept;
        return rows;
    }

    fn printState(self: *Presenter, comptime format: []const u8, args: anytype) !void {
        try self.printStyled(.state, format, args);
    }

    fn printStyled(self: *Presenter, style: TextStyle, comptime format: []const u8, args: anytype) !void {
        if (self.terminal_ui) {
            const start = self.history.?.written().len;
            try self.bodyWriter().print(format, args);
            try self.style_spans.append(self.allocator, .{ .start = start, .end = self.history.?.written().len, .style = style });
        } else {
            const color = c.isatty(c.STDOUT_FILENO) == 1;
            if (color) try self.writer.writeAll(style.escape());
            try self.writer.print(format, args);
            if (color) try self.writer.writeAll("\x1b[0m");
        }
    }

    fn bodyWriter(self: *Presenter) *std.Io.Writer {
        if (self.terminal_ui) return &self.history.?.writer;
        return self.writer;
    }

    fn flush(self: *Presenter) !void {
        if (self.terminal_ui) {
            try self.writer.writeAll("\x1b[?2026h");
            try self.drawHistory();
            try self.writer.writeAll("\x1b[?2026l");
        }
        try self.writer.flush();
    }

    fn drawHistory(self: *Presenter) !void {
        var rows = try self.visibleHistoryRows();
        defer rows.deinit(self.allocator);
        const height = self.terminal_rows - 1;
        const last_top = rows.items.len -| height;
        const top = @min(self.view_top orelse last_top, last_top);
        for (0..height) |row| {
            try self.writer.print("\x1b[{d};1H\x1b[2K", .{row + 1});
            if (top + row < rows.items.len) {
                const text = rows.items[top + row];
                const offset = @intFromPtr(text.ptr) - @intFromPtr(self.history.?.written().ptr);
                var position: usize = 0;
                while (position < text.len) {
                    var end = offset + text.len;
                    var color: ?[]const u8 = null;
                    for (self.style_spans.items) |span| {
                        if (span.end <= offset + position) continue;
                        if (span.start > offset + position) {
                            end = @min(end, span.start);
                        } else {
                            end = @min(end, span.end);
                            color = span.style.escape();
                        }
                        break;
                    }
                    if (color) |sequence| try self.writer.writeAll(sequence);
                    for (text[position .. end - offset]) |byte| {
                        try self.writer.writeByte(if (byte < 32 or byte == 127) ' ' else byte);
                    }
                    if (color != null) try self.writer.writeAll("\x1b[0m");
                    position = end - offset;
                }
            }
        }
    }

    fn navigate(self: *Presenter, action: Navigation) !void {
        var rows = try self.visibleHistoryRows();
        defer rows.deinit(self.allocator);
        const height = self.terminal_rows - 1;
        const bottom = rows.items.len -| height;
        const top = self.view_top orelse bottom;
        self.view_top = switch (action) {
            .up => top -| 3,
            .down => @min(top + 3, bottom),
            .page_up => top -| height,
            .page_down => @min(top + height, bottom),
            .home => 0,
            .end => null,
        };
        if (self.view_top != null and self.view_top.? >= bottom) self.view_top = null;
        try self.drawHistory();
        try self.updateStatusBar();
    }

    fn beginTerminalUi(self: *Presenter) !void {
        if (c.isatty(c.STDOUT_FILENO) != 1) return;
        var window: c.struct_winsize = undefined;
        if (c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &window) != 0 or window.ws_row < 3 or window.ws_col == 0) return;
        self.terminal_rows = window.ws_row;
        self.history = std.Io.Writer.Allocating.init(self.allocator);
        self.terminal_ui = true;
        try self.writer.print("\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1006h\x1b[2J\x1b[H\x1b[1;{d}r\x1b[1;1H", .{self.terminal_rows - 1});
        try self.updateStatusBar();
        try self.beginInputReader();
        self.stop_status_ticker.store(false, .release);
        self.status_ticker = try std.Thread.spawn(.{}, statusTicker, .{self});
    }

    fn updateStatusBar(self: *Presenter) !void {
        if (!self.terminal_ui) return;
        var window: c.struct_winsize = undefined;
        const columns: usize = if (c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &window) == 0 and window.ws_col > 0) window.ws_col else 80;
        const elapsed_seconds: u64 = self.elapsed_base_seconds + (if (self.io) |io| if (self.status_started_at) |started|
            @as(u64, @intCast(@max(@as(i96, 0), @divTrunc(started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds, std.time.ns_per_s))))
        else
            0 else 0);
        const turn_text = try std.fmt.allocPrint(self.allocator, "{d}", .{self.turn_number});
        defer self.allocator.free(turn_text);
        const limit_text = if (self.max_turns) |limit| try std.fmt.allocPrint(self.allocator, "{d}", .{limit}) else "∞";
        defer if (self.max_turns != null) self.allocator.free(limit_text);
        const elapsed_text = try std.fmt.allocPrint(self.allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{ elapsed_seconds / 3600, (elapsed_seconds / 60) % 60, elapsed_seconds % 60 });
        defer self.allocator.free(elapsed_text);
        var line_buffer: [1024]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buffer, " matcha » TURN {s} | LIMIT {s} | {s} | MODEL {s} | ELAPSED {s} | {s} ", .{
            turn_text,
            limit_text,
            @tagName(self.backend),
            self.model orelse "default",
            elapsed_text,
            if (self.view_top == null) "LIVE" else "SCROLLED (End: live)",
        });
        // Status symbols such as » and ∞ occupy one column despite their UTF-8 length.
        var shown_bytes: usize = 0;
        var shown_columns: usize = 0;
        while (shown_bytes < line.len and shown_columns < columns) : (shown_columns += 1) {
            const char_bytes = std.unicode.utf8ByteSequenceLength(line[shown_bytes]) catch 1;
            shown_bytes += @min(char_bytes, line.len - shown_bytes);
        }
        const shown = line[0..shown_bytes];
        try self.writer.print("\x1b[?2026h\x1b[s\x1b[{d};1H\x1b[0;38;2;0;0;0;48;2;144;238;144m", .{self.terminal_rows});
        try self.writer.writeAll(shown);
        for (shown_columns..columns) |_| try self.writer.writeByte(' ');
        try self.writer.writeAll("\x1b[0m\x1b[u\x1b[?2026l");
        try self.writer.flush();
    }

    fn endTerminalUi(self: *Presenter) !void {
        if (!self.terminal_ui) return;
        self.stopStatusTicker();
        self.stopInputReader();
        self.terminal_ui = false;
        try self.writer.writeAll("\x1b[?2026l\x1b[?25h\x1b[?1000l\x1b[?1006l\x1b[r\x1b[?1049l");
        try self.flush();
    }

    fn beginInputReader(self: *Presenter) !void {
        if (c.isatty(c.STDIN_FILENO) != 1) return;
        if (c.tcgetattr(c.STDIN_FILENO, &self.original_stdin_termios) != 0) return error.TerminalSetupFailed;
        var raw = self.original_stdin_termios;
        raw.c_lflag &= @as(c.tcflag_t, ~@as(c.tcflag_t, c.ICANON | c.ECHO));
        raw.c_cc[c.VMIN] = 0;
        raw.c_cc[c.VTIME] = 0;
        if (c.tcsetattr(c.STDIN_FILENO, c.TCSANOW, &raw) != 0) return error.TerminalSetupFailed;
        self.stdin_raw = true;
        self.stop_input_reader.store(false, .release);
        self.input_reader = try std.Thread.spawn(.{}, inputReader, .{self});
    }

    fn stopInputReader(self: *Presenter) void {
        self.stop_input_reader.store(true, .release);
        if (self.input_reader) |thread| {
            thread.join();
            self.input_reader = null;
        }
        if (self.stdin_raw) {
            _ = c.tcsetattr(c.STDIN_FILENO, c.TCSANOW, &self.original_stdin_termios);
            self.stdin_raw = false;
        }
    }

    fn lockOutput(self: *Presenter) !void {
        if (self.io) |io| try self.output_mutex.lock(io);
    }

    fn unlockOutput(self: *Presenter) void {
        if (self.io) |io| self.output_mutex.unlock(io);
    }

    fn stopStatusTicker(self: *Presenter) void {
        self.stop_status_ticker.store(true, .release);
        if (self.status_ticker) |thread| {
            thread.join();
            self.status_ticker = null;
        }
    }
};

fn statusTicker(presenter: *Presenter) void {
    const io = presenter.io orelse return;
    while (!presenter.stop_status_ticker.load(.acquire)) {
        io.sleep(.{ .nanoseconds = std.time.ns_per_s }, .awake) catch return;
        if (presenter.stop_status_ticker.load(.acquire)) return;
        presenter.output_mutex.lockUncancelable(io);
        if (!presenter.stop_status_ticker.load(.acquire)) presenter.updateStatusBar() catch {};
        presenter.output_mutex.unlock(io);
    }
}

const Navigation = enum { up, down, page_up, page_down, home, end };

fn navigation(sequence: []const u8) ?Navigation {
    if (std.mem.eql(u8, sequence, "[A")) return .up;
    if (std.mem.eql(u8, sequence, "[B")) return .down;
    if (std.mem.eql(u8, sequence, "[5~")) return .page_up;
    if (std.mem.eql(u8, sequence, "[6~")) return .page_down;
    if (std.mem.eql(u8, sequence, "[H") or std.mem.eql(u8, sequence, "[1~")) return .home;
    if (std.mem.eql(u8, sequence, "[F") or std.mem.eql(u8, sequence, "[4~")) return .end;
    if (std.mem.startsWith(u8, sequence, "[<") and std.mem.endsWith(u8, sequence, "M")) {
        const end = std.mem.indexOfScalar(u8, sequence, ';') orelse return null;
        const button = std.fmt.parseInt(u16, sequence[2..end], 10) catch return null;
        if (button & 0b11000011 == 64) return .up;
        if (button & 0b11000011 == 65) return .down;
    }
    return null;
}

fn historyRows(allocator: std.mem.Allocator, text: []const u8, width: usize) !std.ArrayList([]const u8) {
    var rows: std.ArrayList([]const u8) = .empty;
    errdefer rows.deinit(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var consumed: usize = 0;
    while (lines.next()) |line| {
        // A trailing newline ends the last row; it does not add a blank row.
        if (line.len == 0 and consumed == text.len) break;
        consumed += line.len + 1;
        if (line.len == 0) try rows.append(allocator, line);
        var remaining = line;
        while (remaining.len > 0) {
            var count = @min(remaining.len, @max(width, 4));
            while (count < remaining.len and remaining[count] & 0xc0 == 0x80) count -= 1;
            try rows.append(allocator, remaining[0..count]);
            remaining = remaining[count..];
        }
    }
    return rows;
}

fn inputReader(presenter: *Presenter) void {
    const io = presenter.io orelse return;
    var sequence: [64]u8 = undefined;
    var length: usize = 0;
    var escape = false;
    while (!presenter.stop_input_reader.load(.acquire)) {
        var poll_fd = c.struct_pollfd{ .fd = c.STDIN_FILENO, .events = c.POLLIN, .revents = 0 };
        const ready = c.poll(&poll_fd, 1, 100);
        if (ready <= 0 or (poll_fd.revents & c.POLLIN) == 0) continue;
        var byte: u8 = 0;
        if (c.read(c.STDIN_FILENO, &byte, 1) != 1) continue;
        if (byte == 27) {
            escape = true;
            length = 0;
            continue;
        }
        if (!escape) continue;
        if (length == sequence.len) {
            escape = false;
            continue;
        }
        sequence[length] = byte;
        length += 1;
        if (length < 2 or byte < 0x40 or byte > 0x7e) continue;
        escape = false;
        const action = navigation(sequence[0..length]) orelse continue;
        presenter.output_mutex.lockUncancelable(io);
        if (!presenter.stop_input_reader.load(.acquire)) presenter.navigate(action) catch {};
        presenter.output_mutex.unlock(io);
    }
}

fn isCommand(name: []const u8) bool {
    for ([_][]const u8{ "command_execution", "Execute", "Bash", "exec_command", "run_command", "run_shell_command", "shell", "terminal" }) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

fn terminalColumns() usize {
    if (c.isatty(c.STDOUT_FILENO) != 1) return 80;
    var window: c.struct_winsize = undefined;
    if (c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &window) != 0 or window.ws_col == 0) return 80;
    return window.ws_col;
}

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
            handler(context, .{ .tool_call = .{ .name = name, .detail = detail, .id = stringField(item, "id") } });
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
    const input = field(value, "input") orelse field(value, "arguments") orelse .null;
    const detail = stringField(value, "command") orelse stringField(input, "command") orelse stringField(value, "description") orelse "";
    handler(context, .{ .tool_call = .{ .name = name, .detail = detail, .id = stringField(value, "tool_use_id") orelse stringField(value, "id") } });
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
    try std.testing.expect(std.mem.indexOf(u8, live, "  -> Read: /repo/src/main.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, live, "  assistant: \"done\"") != null);
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

test "scroll navigation accepts arrows pages and SGR wheel reports" {
    try std.testing.expectEqual(Navigation.up, navigation("[A").?);
    try std.testing.expectEqual(Navigation.down, navigation("[B").?);
    try std.testing.expectEqual(Navigation.page_up, navigation("[5~").?);
    try std.testing.expectEqual(Navigation.page_down, navigation("[6~").?);
    try std.testing.expectEqual(Navigation.end, navigation("[F").?);
    try std.testing.expectEqual(Navigation.up, navigation("[<64;12;9M").?);
    try std.testing.expectEqual(Navigation.down, navigation("[<65;12;9M").?);
    try std.testing.expect(navigation("[<0;12;9M") == null);
    try std.testing.expect(navigation("[<64;12;9m") == null);
}

test "scroll history wraps text and preserves blank lines without a trailing phantom row" {
    var rows = try historyRows(std.testing.allocator, "abcdefgh\n\nlast\n", 4);
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), rows.items.len);
    try std.testing.expectEqualStrings("abcd", rows.items[0]);
    try std.testing.expectEqualStrings("efgh", rows.items[1]);
    try std.testing.expectEqualStrings("", rows.items[2]);
    try std.testing.expectEqualStrings("last", rows.items[3]);
}

test "scroll viewport stays on older logs as new output arrives and End resumes following" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var presenter = Presenter.init(std.testing.allocator, &output.writer, .live, "scroll", .codex);
    defer presenter.deinit();
    presenter.history = std.Io.Writer.Allocating.init(std.testing.allocator);
    presenter.terminal_ui = true;
    presenter.terminal_rows = 4;
    try presenter.bodyWriter().writeAll("one\ntwo\nthree\nfour\nfive\nsix\n");
    try presenter.navigate(.up);
    try std.testing.expectEqual(@as(?usize, 0), presenter.view_top);
    try presenter.bodyWriter().writeAll("seven\neight\n");
    try presenter.flush();
    try std.testing.expectEqual(@as(?usize, 0), presenter.view_top);
    try presenter.navigate(.page_down);
    try std.testing.expectEqual(@as(?usize, 3), presenter.view_top);
    try presenter.navigate(.end);
    try std.testing.expect(presenter.view_top == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "eight") != null);
}

test "assistant label and quotes have independent colors from message text" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var presenter = Presenter.init(std.testing.allocator, &output.writer, .live, "colors", .codex);
    defer presenter.deinit();
    presenter.history = std.Io.Writer.Allocating.init(std.testing.allocator);
    presenter.terminal_ui = true;
    presenter.terminal_rows = 4;
    try presenter.handleEvent(.{ .assistant_text = "hello\n" });
    try std.testing.expectEqualStrings("  assistant: \"hello\"\n", presenter.history.?.written());
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[38;2;255;165;0m  assistant: \x1b[0m\x1b[38;2;144;238;144m\"\x1b[0m\x1b[48;2;0;64;32mhello\x1b[0m\x1b[38;2;144;238;144m\"\x1b[0m") != null);
}

test "command groups retain only three executions and preserve older groups" {
    const allocator = std.testing.allocator;
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var presenter = Presenter.init(allocator, &output.writer, .live, "commands", .codex);
    defer presenter.deinit();
    presenter.history = std.Io.Writer.Allocating.init(allocator);
    presenter.terminal_ui = true;
    presenter.terminal_rows = 12;
    for ([_][]const u8{ "cmd-a", "cmd-b", "cmd-c", "cmd-d" }) |command| {
        try presenter.handleEvent(.{ .tool_call = .{ .name = "command_execution", .detail = command, .id = command } });
    }
    // A completion notification for the same command must not consume another slot.
    try presenter.handleEvent(.{ .tool_call = .{ .name = "command_execution", .detail = "cmd-d", .id = "cmd-d" } });
    try std.testing.expectEqual(@as(usize, 3), presenter.command_count);
    try std.testing.expectEqual(TextStyle.command_old, presenter.style_spans.items[presenter.command_spans[0]].style);
    try std.testing.expectEqual(TextStyle.command_old, presenter.style_spans.items[presenter.command_spans[1]].style);
    try std.testing.expectEqual(TextStyle.command_latest, presenter.style_spans.items[presenter.command_spans[2]].style);
    var rows = try presenter.visibleHistoryRows();
    defer rows.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), rows.items.len);
    try std.testing.expectEqualStrings("Ran cmd-b", rows.items[0]);
    try std.testing.expectEqualStrings("Ran cmd-d", rows.items[2]);
    try presenter.handleEvent(.{ .assistant_text = "Continuing" });
    try presenter.handleEvent(.{ .tool_call = .{ .name = "Bash", .detail = "cmd-e" } });
    var next = try presenter.visibleHistoryRows();
    defer next.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 5), next.items.len);
    try std.testing.expectEqualStrings("Ran cmd-b", next.items[0]);
    try std.testing.expectEqualStrings("Ran cmd-e", next.items[4]);
}

test "plain live command output flushes only the last three before assistant response" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var presenter = Presenter.init(std.testing.allocator, &output.writer, .live, "commands", .codex);
    defer presenter.deinit();
    for ([_][]const u8{ "a", "b", "c", "d" }) |command| {
        try presenter.handleEvent(.{ .tool_call = .{ .name = "Execute", .detail = command } });
    }
    try presenter.handleEvent(.{ .assistant_text = "done" });
    try std.testing.expectEqualStrings("Ran b\nRan c\nRan d\n  assistant: \"done\"\n", output.written());
}
