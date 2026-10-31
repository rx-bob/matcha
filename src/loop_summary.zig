const std = @import("std");
const store = @import("loop_store.zig");

/// Use the worker's cumulative report; verifier-only replies often describe checks
/// without describing the implementation. Never treat an error diagnostic as work.
pub fn render(allocator: std.mem.Allocator, state: store.LoopState, history: []const u8) ![]u8 {
    var selected: ?[]u8 = null;
    defer if (selected) |value| allocator.free(value);
    var lines = std.mem.tokenizeScalar(u8, history, '\n');
    while (lines.next()) |line| {
        var parsed = std.json.parseFromSlice(store.TurnRecord, allocator, line, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();
        const record = parsed.value;
        if (record.role != .worker or record.outcome == .@"error" or std.mem.trim(u8, record.summary, " \t\r\n").len == 0) continue;
        const copy = try allocator.dupe(u8, record.summary);
        if (selected) |previous| allocator.free(previous);
        selected = copy;
    }
    const report = selected orelse state.completion_summary orelse state.last_blocker_summary orelse "No work summary was recorded before the loop stopped.";
    return brief(allocator, report);
}

fn brief(allocator: std.mem.Allocator, report: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var words = std.mem.tokenizeAny(u8, report, " \t\r\n");
    var count: usize = 0;
    while (words.next()) |word| {
        if (count == 80 or output.items.len + word.len > 800) {
            try output.appendSlice(allocator, "…");
            break;
        }
        if (count > 0) try output.append(allocator, ' ');
        // Keep terminal escape/control bytes out of the final report.
        for (word) |byte| try output.append(allocator, if (byte < 32 or byte == 127) ' ' else byte);
        count += 1;
    }
    return output.toOwnedSlice(allocator);
}

test "summary retains worker accomplishments across a verifier reply" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, .{
        .id = "loop",
        .backend = .codex,
        .cwd = ".",
        .objective = "fix",
        .started_at_ms = 0,
        .updated_at_ms = 0,
        .completion_summary = "Checks passed.",
    },
        \\{"turn":1,"role":"worker","backend":"codex","outcome":"complete","summary":"Fixed the leak. Regression checks passed."}
        \\{"turn":2,"role":"verifier","backend":"codex","outcome":"verifier_pass","summary":"Looks good."}
    );
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Fixed the leak. Regression checks passed.", result);
}

test "summary handles missing history and limits long agent reports" {
    const allocator = std.testing.allocator;
    const result = try render(allocator, .{ .id = "loop", .backend = .codex, .cwd = ".", .objective = "fix", .started_at_ms = 0, .updated_at_ms = 0 }, "bad json\n");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("No work summary was recorded before the loop stopped.", result);
    const short = try brief(allocator, "word " ** 100);
    defer allocator.free(short);
    try std.testing.expect(short.len < 410);
    try std.testing.expect(std.mem.endsWith(u8, short, "…"));
}
