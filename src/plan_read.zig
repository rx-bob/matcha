const std = @import("std");

const path = @import("path.zig");

pub const PlanReadError = error{
    missing_path,
    extra_arguments,
    invalid_argument,
    missing_home,
    cannot_read_input,
    invalid_json,
    unsupported_input,
    out_of_memory,
};

pub const ParsedPlanDocument = struct {
    allocator: std.mem.Allocator,
    raw: []const u8,
    title: []const u8,
    arena: std.heap.ArenaAllocator,
    data: std.json.Value,

    pub fn deinit(self: *ParsedPlanDocument) void {
        self.allocator.free(self.raw);
        self.allocator.free(self.title);
        self.arena.deinit();
    }
};

pub fn parsePlanReadInput(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) PlanReadError!ParsedPlanDocument {
    const resolved = parsePlanReadArgument(allocator, args) catch |err| switch (err) {
        error.MissingHome => return PlanReadError.missing_home,
        error.OutOfMemory => return PlanReadError.out_of_memory,
        else => return PlanReadError.cannot_read_input,
    };
    defer if (resolved.owned_path) allocator.free(resolved.path);
    const input_path = resolved.path;

    const raw_input = std.Io.Dir.cwd().readFileAlloc(
        io,
        input_path,
        allocator,
        .limited(16 * 1024 * 1024),
    ) catch |err| {
        switch (err) {
            error.OutOfMemory => return PlanReadError.out_of_memory,
            else => return PlanReadError.cannot_read_input,
        }
    };
    defer allocator.free(raw_input);

    const plan_payload = detectPlanPayload(raw_input) orelse {
        return PlanReadError.unsupported_input;
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), plan_payload, .{}) catch |err| {
        return switch (err) {
            error.OutOfMemory => PlanReadError.out_of_memory,
            else => PlanReadError.invalid_json,
        };
    };
    const raw_output = allocator.dupe(u8, plan_payload) catch return PlanReadError.out_of_memory;
    errdefer allocator.free(raw_output);
    const title = extractTitle(parsed.value);
    const title_output = allocator.dupe(u8, title) catch return PlanReadError.out_of_memory;

    return ParsedPlanDocument{
        .allocator = allocator,
        .raw = raw_output,
        .title = title_output,
        .arena = arena,
        .data = parsed.value,
    };
}

const ResolvedPlanReadPath = struct {
    path: []const u8,
    owned_path: bool,
};

fn parsePlanReadArgument(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) (PlanReadError || path.PathError)!ResolvedPlanReadPath {
    if (args.len == 0) {
        return PlanReadError.missing_path;
    }

    if (args.len > 1) {
        return PlanReadError.extra_arguments;
    }

    if (std.mem.startsWith(u8, args[0], "-")) {
        return PlanReadError.invalid_argument;
    }

    if (path.isHomeRelative(args[0])) {
        return ResolvedPlanReadPath{
            .path = try path.expandHomePath(allocator, args[0]),
            .owned_path = true,
        };
    }

    return ResolvedPlanReadPath{
        .path = args[0],
        .owned_path = false,
    };
}

fn detectPlanPayload(raw_input: []const u8) ?[]const u8 {
    const trimmed = trimLeadingWhitespace(raw_input);
    if (trimmed.len == 0) {
        return null;
    }

    if (trimmed[0] == '{') {
        return std.mem.trim(u8, raw_input, " \t\r\n");
    }

    return extractPlanDataFromHtml(raw_input);
}

fn trimLeadingWhitespace(text: []const u8) []const u8 {
    var index: usize = 0;

    while (index < text.len) : (index += 1) {
        switch (text[index]) {
            ' ', '\t', '\r', '\n' => continue,
            else => break,
        }
    }

    return text[index..];
}

fn extractPlanDataFromHtml(raw_input: []const u8) ?[]const u8 {
    const marker_double = std.mem.indexOf(u8, raw_input, "id=\"plan-data\"");
    const marker_single = if (marker_double == null)
        std.mem.indexOf(u8, raw_input, "id='plan-data'")
    else
        null;

    const marker = marker_double orelse marker_single orelse return null;

    const tag_start = std.mem.lastIndexOfAny(u8, raw_input[0..marker], "<");
    if (tag_start == null) {
        return null;
    }

    if (!std.mem.startsWith(u8, raw_input[tag_start.?..], "<script")) {
        return null;
    }

    const open_tag_end = if (tag_start) |start| std.mem.indexOfScalar(u8, raw_input[start..], '>') else null;
    if (open_tag_end == null) {
        return null;
    }

    const body_start = tag_start.? + open_tag_end.? + 1;
    const close_tag = std.mem.indexOf(u8, raw_input[body_start..], "</script>");
    if (close_tag == null) {
        return null;
    }

    return std.mem.trim(u8, raw_input[body_start..][0..close_tag.?], " \t\r\n");
}

fn extractTitle(value: std.json.Value) []const u8 {
    if (value == .object) {
        if (value.object.get("title")) |title| {
            if (title == .string) {
                return title.string;
            }
        }
    }

    return "# ";
}

test "detects raw plan JSON" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const input_path = try std.fmt.allocPrint(allocator, "{s}/plan.json", .{tmp.dir.path.?});
    defer allocator.free(input_path);

    try tmp.dir.writeFile("plan.json", "{\"title\":\"Plan Fixture\",\"schemaVersion\":1}\n");

    const document = try parsePlanReadInput(std.testing.io, allocator, &.{input_path});
    defer document.deinit();

    try std.testing.expectEqualStrings("Plan Fixture", document.title);
    try std.testing.expect(std.mem.indexOf(u8, document.raw, "\"Plan Fixture\"") != null);
}

test "extracts plan JSON from generated plan HTML" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const input_path = try std.fmt.allocPrint(allocator, "{s}/plan.html", .{tmp.dir.path.?});
    defer allocator.free(input_path);

    try tmp.dir.writeFile("plan.html", "<html><body>\n  <script type=\"application/json\" id=\"plan-data\">\n    {\"title\":\"HTML Fixture\",\"schemaVersion\":1}\n  </script>\n</body></html>\n");

    const document = try parsePlanReadInput(std.testing.io, allocator, &.{input_path});
    defer document.deinit();

    try std.testing.expectEqualStrings("HTML Fixture", document.title);
    try std.testing.expect(std.mem.indexOf(u8, document.raw, "\"title\":\"HTML Fixture\"") != null);
}

test "rejects missing and extra plan read arguments" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        PlanReadError.missing_path,
        parsePlanReadInput(std.testing.io, allocator, &.{}),
    );
    try std.testing.expectError(
        PlanReadError.extra_arguments,
        parsePlanReadInput(std.testing.io, allocator, &.{ "one.json", "two.json" }),
    );
    try std.testing.expectError(
        PlanReadError.invalid_argument,
        parsePlanReadInput(std.testing.io, allocator, &.{"--output"}),
    );
}

test "rejects unsupported plan read input" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const input_path = try std.fmt.allocPrint(allocator, "{s}/unsupported.txt", .{tmp.dir.path.?});
    defer allocator.free(input_path);

    try tmp.dir.writeFile("unsupported.txt", "this is not json");

    try std.testing.expectError(
        PlanReadError.unsupported_input,
        parsePlanReadInput(std.testing.io, allocator, &.{input_path}),
    );
}
