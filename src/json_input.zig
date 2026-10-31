const std = @import("std");

pub const ParsedDocument = struct {
    allocator: std.mem.Allocator,
    raw: []const u8,
    title: []const u8,
    arena: std.heap.ArenaAllocator,
    data: std.json.Value,

    pub fn deinit(self: *ParsedDocument) void {
        self.arena.deinit();
        self.allocator.free(self.title);
        self.allocator.free(self.raw);
    }
};

pub const DocumentParseError = error{
    CannotReadInput,
    InvalidJson,
    OutOfMemory,
};

pub fn readJsonDocument(
    io: std.Io,
    allocator: std.mem.Allocator,
    input_path: []const u8,
) DocumentParseError!ParsedDocument {
    const raw_input = std.Io.Dir.cwd().readFileAlloc(
        io,
        input_path,
        allocator,
        .limited(16 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.OutOfMemory => return DocumentParseError.OutOfMemory,
        else => return DocumentParseError.CannotReadInput,
    };
    errdefer allocator.free(raw_input);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), raw_input, .{}) catch |err| {
        return switch (err) {
            error.OutOfMemory => DocumentParseError.OutOfMemory,
            else => DocumentParseError.InvalidJson,
        };
    };
    const title = extractTitle(parsed.value);

    return ParsedDocument{
        .allocator = allocator,
        .raw = raw_input,
        .title = try allocator.dupe(u8, title),
        .arena = arena,
        .data = parsed.value,
    };
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

test "reads JSON and extracts title" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const input_path = try std.fmt.allocPrint(allocator, "{s}/plan.json", .{tmp.dir.path.?});
    defer allocator.free(input_path);

    try tmp.dir.writeFile("plan.json", "{\"title\":\"Input Fixture\",\"extra\":true}\n");

    var parsed = try readJsonDocument(std.testing.io, allocator, input_path);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Input Fixture", parsed.title);
    try std.testing.expect(parsed.data == .object);
    try std.testing.expect(parsed.raw.len > 0);
}

test "reads map JSON and extracts title" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const input_path = try std.fmt.allocPrint(allocator, "{s}/map.json", .{tmp.dir.path.?});
    defer allocator.free(input_path);

    try tmp.dir.writeFile("map.json", "{\"title\":\"Map Fixture\",\"elements\":[]}\n");

    var parsed = try readJsonDocument(std.testing.io, allocator, input_path);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Map Fixture", parsed.title);
    try std.testing.expect(parsed.data == .object);
    try std.testing.expect(std.mem.indexOf(u8, parsed.raw, "\"elements\"") != null);
}

test "returns error for malformed JSON" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const input_path = try std.fmt.allocPrint(allocator, "{s}/bad.json", .{tmp.dir.path.?});
    defer allocator.free(input_path);

    try tmp.dir.writeFile("bad.json", "not json");

    try std.testing.expectError(
        DocumentParseError.InvalidJson,
        readJsonDocument(std.testing.io, allocator, input_path),
    );
}
