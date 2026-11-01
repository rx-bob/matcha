const std = @import("std");

pub const MarkdownFormat = enum {
    plan,
};

pub const RenderError = error{ NotAnObject, OutOfMemory };

pub fn headingPrefix(format: MarkdownFormat) []const u8 {
    return switch (format) {
        .plan => "# ",
    };
}

pub fn renderPlanMarkdown(allocator: std.mem.Allocator, plan_value: std.json.Value) RenderError![]const u8 {
    if (plan_value != .object) {
        return RenderError.NotAnObject;
    }

    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer out.deinit(allocator);
    var writer = MarkdownWriter{ .out = &out, .allocator = allocator };

    try renderPlan(&writer, plan_value.object);
    try writer.writeLine("");

    const raw = try out.toOwnedSlice(allocator);
    defer allocator.free(raw);
    return normalizeBlankLines(allocator, raw);
}

fn normalizeBlankLines(allocator: std.mem.Allocator, input: []const u8) RenderError![]const u8 {
    var normalized = try std.ArrayList(u8).initCapacity(allocator, input.len);
    defer normalized.deinit(allocator);

    var consecutive_newlines: usize = 0;
    for (input) |character| {
        if (character == '\n') {
            consecutive_newlines += 1;
            continue;
        }

        const emit_count = if (consecutive_newlines > 2) 2 else consecutive_newlines;
        if (consecutive_newlines > 0) {
            for (0..emit_count) |_| {
                try normalized.append(allocator, '\n');
            }
            consecutive_newlines = 0;
        }

        try normalized.append(allocator, character);
    }

    if (consecutive_newlines > 0) {
        const emit_count = if (consecutive_newlines > 2) 2 else consecutive_newlines;
        for (0..emit_count) |_| {
            try normalized.append(allocator, '\n');
        }
    }

    while (normalized.items.len > 0 and normalized.items[normalized.items.len - 1] == '\n') {
        normalized.items.len -= 1;
    }
    try normalized.append(allocator, '\n');

    return try normalized.toOwnedSlice(allocator);
}

const MarkdownWriter = struct {
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    last_line_blank: bool = false,

    fn writeLine(self: *MarkdownWriter, line: []const u8) !void {
        const current_line_blank = line.len == 0;
        if (current_line_blank and self.last_line_blank) {
            return;
        }

        try self.out.appendSlice(self.allocator, line);
        try self.out.append(self.allocator, '\n');
        self.last_line_blank = current_line_blank;
    }

    fn writeKVLine(self: *MarkdownWriter, comptime fmt: []const u8, value: []const u8) !void {
        const rendered = try std.fmt.allocPrint(self.allocator, fmt, .{value});
        defer self.allocator.free(rendered);
        try self.writeLine(rendered);
    }

    fn writeFormattedLine(self: *MarkdownWriter, comptime fmt: []const u8, value: anytype) !void {
        const rendered = try std.fmt.allocPrint(self.allocator, fmt, value);
        defer self.allocator.free(rendered);
        try self.writeLine(rendered);
    }
};

fn renderPlan(out: *MarkdownWriter, plan: std.json.ObjectMap) !void {
    const title = getString(plan, "title") orelse "";

    try out.writeFormattedLine("# {s}", .{title});
    try out.writeLine("");
    try out.writeKVLine("- **Plan ID:** {s}", getString(plan, "id") orelse "");

    if (getString(plan, "project")) |project| {
        try out.writeKVLine("- **Project:** {s}", project);
    }

    if (getString(plan, "status")) |status| {
        try out.writeKVLine("- **Status:** {s}", status);
    }

    if (getString(plan, "generatedAt")) |generated_at| {
        try out.writeKVLine("- **Generated At:** {s}", generated_at);
    }

    if (plan.get("schemaVersion")) |schema_version| {
        const schema_version_text = try renderJsonValue(out.allocator, schema_version);
        defer out.allocator.free(schema_version_text);
        try out.writeFormattedLine("- **Schema Version:** {s}", .{schema_version_text});
    }

    if (getString(plan, "scope")) |scope| {
        try out.writeLine("");
        try out.writeLine("## Scope");
        try out.writeLine("");
        try out.writeLine(scope);
    }

    if (getArray(plan, "summary")) |summary| {
        if (summary.items.len > 0) {
            try out.writeLine("");
            try out.writeLine("## Summary");
            try out.writeLine("");

            for (summary.items) |summary_item| {
                if (summary_item == .string) {
                    try out.writeLine(summary_item.string);
                    try out.writeLine("");
                }
            }
        }
    }

    if (getObject(plan, "metadata")) |metadata| {
        if (metadata.count() > 0) {
            try out.writeLine("## Metadata");
            try out.writeLine("");

            const keys = try sortedKeys(out.allocator, metadata);
            defer out.allocator.free(keys);
            for (keys) |key| {
                const metadata_value = metadata.get(key) orelse continue;
                const rendered = try renderJsonValue(out.allocator, metadata_value);
                defer out.allocator.free(rendered);
                try out.writeFormattedLine("- **{s}:** {s}", .{ key, rendered });
            }

            try out.writeLine("");
        }
    }

    if (getArray(plan, "changedFiles")) |changed_files| {
        if (changed_files.items.len > 0) {
            try renderChangedFiles(out, changed_files);
        }
    }

    if (getArray(plan, "epics")) |epics| {
        if (epics.items.len > 0) {
            try out.writeLine("## Epics");
            try out.writeLine("");

            for (epics.items) |epic| {
                if (epic == .object) {
                    try renderEpic(out, epic.object);
                }
            }
        }
    }

    if (getArray(plan, "sections")) |sections| {
        if (sections.items.len > 0) {
            try out.writeLine("## Sections");
            try out.writeLine("");

            for (sections.items) |section| {
                if (section == .object) {
                    try renderSection(out, section.object);
                }
            }
        }
    }

    if (getArray(plan, "recommendedOrder")) |recommended_order| {
        if (recommended_order.items.len > 0) {
            try out.writeLine("## Recommended Order");
            try out.writeLine("");

            for (recommended_order.items) |item| {
                if (item == .object) {
                    try renderRecommendedOrderItem(out, item.object);
                }
            }
        }
    }

    if (getStringList(plan, "exitCriteria", out.allocator)) |exit_criteria| {
        defer out.allocator.free(exit_criteria);
        if (exit_criteria.len > 0) {
            try out.writeLine("## Exit Criteria");
            try out.writeLine("");

            for (exit_criteria) |criterion| {
                try out.writeFormattedLine("- {s}", .{criterion});
            }

            try out.writeLine("");
        }
    }
}

fn renderChangedFiles(out: *MarkdownWriter, changed_files: std.json.Array) !void {
    try out.writeLine("## Changed Files");
    try out.writeLine("");

    for (changed_files.items) |tree| {
        if (tree != .object) continue;
        const tree_object = tree.object;

        if (getString(tree_object, "label")) |label| {
            try out.writeFormattedLine("### {s}", .{label});
            try out.writeLine("");
        }

        if (getObject(tree_object, "root")) |root| {
            try renderFileTreeNode(out, root, 0);
        }

        try out.writeLine("");
    }
}

fn renderFileTreeNode(out: *MarkdownWriter, node: std.json.ObjectMap, depth: usize) !void {
    const name = getString(node, "name") orelse "";
    const node_type = getString(node, "type") orelse "";

    var line = try std.ArrayList(u8).initCapacity(out.allocator, 0);
    defer line.deinit(out.allocator);

    var indent: usize = 0;
    while (indent < depth) : (indent += 1) {
        try line.appendSlice(out.allocator, "  ");
    }
    try line.appendSlice(out.allocator, name);

    if (std.mem.eql(u8, node_type, "file")) {
        if (getString(node, "status")) |status| {
            if (std.mem.eql(u8, status, "new")) {
                try line.appendSlice(out.allocator, " [new]");
            } else if (std.mem.eql(u8, status, "modified")) {
                try line.appendSlice(out.allocator, " [mod]");
            }
        }

        if (getStringList(node, "stories", out.allocator)) |stories| {
            defer out.allocator.free(stories);
            if (stories.len > 0) {
                try line.appendSlice(out.allocator, " (Stories: ");
                for (stories, 0..) |story, index| {
                    if (index > 0) {
                        try line.appendSlice(out.allocator, ", ");
                    }
                    try line.appendSlice(out.allocator, story);
                }
                try line.appendSlice(out.allocator, ")");
            }
        }
    }

    const line_text = try line.toOwnedSlice(out.allocator);
    defer out.allocator.free(line_text);
    try out.writeLine(line_text);

    if (getArray(node, "children")) |children| {
        for (children.items) |child| {
            if (child == .object) {
                try renderFileTreeNode(out, child.object, depth + 1);
            }
        }
    }
}

fn renderEpic(out: *MarkdownWriter, epic: std.json.ObjectMap) !void {
    const id = getString(epic, "id") orelse "";
    const title = getString(epic, "title") orelse "";

    try out.writeFormattedLine("### {s}: {s}", .{ id, title });

    if (getString(epic, "summary")) |summary| {
        try out.writeLine("");
        try out.writeLine(summary);
    }

    if (getString(epic, "description")) |description| {
        try out.writeLine("");
        try out.writeLine(description);
    }

    if (getString(epic, "status")) |status| {
        try out.writeLine("");
        try out.writeKVLine("- **Status:** {s}", status);
    }

    if (getStringList(epic, "dependencies", out.allocator)) |dependencies| {
        defer out.allocator.free(dependencies);
        const dependencies_text = try joinPrefixComma(out.allocator, "- **Dependencies:** ", dependencies);
        defer out.allocator.free(dependencies_text);
        try out.writeLine(dependencies_text);
    }

    const stories = getArray(epic, "stories");
    if (stories != null and stories.?.items.len > 0) {
        try out.writeLine("");
        try out.writeLine("#### Stories");
        try out.writeLine("");

        for (stories.?.items) |story| {
            if (story == .object) {
                try renderStory(out, story.object);
            }
        }
    }

    try out.writeLine("");
}

fn renderStory(out: *MarkdownWriter, story: std.json.ObjectMap) !void {
    const id = getString(story, "id") orelse "";
    const title = getString(story, "title") orelse "";
    try out.writeFormattedLine("##### {s}: {s}", .{ id, title });

    if (getString(story, "status")) |status| {
        try out.writeLine("");
        try out.writeKVLine("- **Status:** {s}", status);
    }

    if (getString(story, "risk")) |risk| {
        try out.writeKVLine("- **Risk:** {s}", risk);
    }

    if (getStringList(story, "dependencies", out.allocator)) |dependencies| {
        defer out.allocator.free(dependencies);
        const dependencies_text = try joinPrefixComma(out.allocator, "- **Dependencies:** ", dependencies);
        defer out.allocator.free(dependencies_text);
        try out.writeLine(dependencies_text);
    }

    if (getString(story, "description")) |description| {
        try out.writeLine("");
        try out.writeLine(description);
    }

    if (getStringList(story, "details", out.allocator)) |details| {
        defer out.allocator.free(details);
        try out.writeLine("");
        try out.writeLine("**Details:**");
        try out.writeLine("");

        for (details) |detail| {
            try out.writeFormattedLine("- {s}", .{detail});
        }
    }

    if (getStringList(story, "acceptanceCriteria", out.allocator)) |acceptance| {
        defer out.allocator.free(acceptance);
        try out.writeLine("");
        try out.writeLine("**Acceptance Criteria:**");
        try out.writeLine("");

        for (acceptance) |criterion| {
            try out.writeFormattedLine("- {s}", .{criterion});
        }
    }

    if (getStringList(story, "unitTests", out.allocator)) |unit_tests| {
        defer out.allocator.free(unit_tests);
        try out.writeLine("");
        try out.writeLine("**Unit Tests:**");
        try out.writeLine("");

        for (unit_tests) |unit| {
            try out.writeFormattedLine("- {s}", .{unit});
        }
    }

    if (getStringList(story, "filesLikelyTouched", out.allocator)) |files| {
        defer out.allocator.free(files);
        try out.writeLine("");
        try out.writeLine("**Files Likely Touched:**");
        try out.writeLine("");

        for (files) |file| {
            const escaped = try escapeInlineCode(out.allocator, file);
            defer out.allocator.free(escaped);
            try out.writeFormattedLine("- {s}", .{escaped});
        }
    }

    try out.writeLine("");
}

fn renderSection(out: *MarkdownWriter, section: std.json.ObjectMap) !void {
    const id = getString(section, "id") orelse "";
    const title = getString(section, "title") orelse "";
    const kind = getString(section, "kind") orelse "";

    try out.writeFormattedLine("### {s}: {s}", .{ id, title });
    if (kind.len > 0) {
        try out.writeLine("");
        try out.writeFormattedLine("- **Kind:** {s}", .{kind});
    }

    if (getArray(section, "summary")) |summary| {
        if (summary.items.len > 0) {
            for (summary.items) |paragraph| {
                if (paragraph == .string) {
                    try out.writeLine("");
                    try out.writeLine(paragraph.string);
                }
            }
        }
    }

    if (getArray(section, "items")) |items| {
        for (items.items) |item| {
            if (item != .object) continue;
            const item_object = item.object;

            var row = try std.ArrayList(u8).initCapacity(out.allocator, 0);
            defer row.deinit(out.allocator);
            try row.appendSlice(out.allocator, "- ");

            if (getString(item_object, "title")) |text_title| {
                const title_text = try std.fmt.allocPrint(out.allocator, "**{s}:** ", .{text_title});
                defer out.allocator.free(title_text);
                try row.appendSlice(out.allocator, title_text);
            }

            if (getString(item_object, "text")) |text| {
                try row.appendSlice(out.allocator, text);
            }

            const row_text = try row.toOwnedSlice(out.allocator);
            defer out.allocator.free(row_text);
            try out.writeLine(row_text);
        }

        try out.writeLine("");
    }

    try out.writeLine("");
}

fn renderRecommendedOrderItem(out: *MarkdownWriter, item: std.json.ObjectMap) !void {
    const ref = getString(item, "ref") orelse "";
    if (getString(item, "reason")) |reason| {
        const line = try std.fmt.allocPrint(out.allocator, "1. **{s}**: {s}", .{ ref, reason });
        defer out.allocator.free(line);
        try out.writeLine(line);
    } else {
        try out.writeFormattedLine("1. **{s}**", .{ref});
    }
}

fn getString(container: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = container.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn getArray(container: std.json.ObjectMap, key: []const u8) ?std.json.Array {
    const value = container.get(key) orelse return null;
    return if (value == .array) value.array else null;
}

fn getObject(container: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = container.get(key) orelse return null;
    return if (value == .object) value.object else null;
}

fn getStringList(container: std.json.ObjectMap, key: []const u8, allocator: std.mem.Allocator) ?[][]const u8 {
    const array = getArray(container, key) orelse return null;
    if (array.items.len == 0) return null;

    var strings = (std.ArrayList([]const u8).initCapacity(allocator, 0) catch return null);
    defer strings.deinit(allocator);

    for (array.items) |value| {
        if (value == .string) {
            strings.append(allocator, value.string) catch return null;
        }
    }

    if (strings.items.len == 0) return null;

    return strings.toOwnedSlice(allocator) catch return null;
}

fn joinPrefixComma(allocator: std.mem.Allocator, prefix: []const u8, values: []const []const u8) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer result.deinit(allocator);
    try result.appendSlice(allocator, prefix);

    for (values, 0..) |value, index| {
        if (index > 0) {
            try result.appendSlice(allocator, ", ");
        }

        try result.appendSlice(allocator, value);
    }

    const owned = try result.toOwnedSlice(allocator);
    return owned;
}

fn sortedKeys(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![][]const u8 {
    var keys = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    errdefer keys.deinit(allocator);

    var it = object.iterator();
    while (it.next()) |entry| {
        try keys.append(allocator, entry.key_ptr.*);
    }

    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    return try keys.toOwnedSlice(allocator);
}

fn renderJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer out.deinit(allocator);

    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |bool_value| try out.appendSlice(allocator, if (bool_value) "true" else "false"),
        .integer => |integer| {
            const text = try std.fmt.allocPrint(allocator, "{}", .{integer});
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
        },
        .float => |float_value| {
            const text = try std.fmt.allocPrint(allocator, "{}", .{float_value});
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
        },
        .number_string => |string_number| try out.appendSlice(allocator, string_number),
        .string => |string_value| try out.appendSlice(allocator, string_value),
        .array => |array| {
            for (array.items, 0..) |item, index| {
                if (index > 0) {
                    try out.appendSlice(allocator, ", ");
                }

                const rendered = try renderJsonValue(allocator, item);
                defer allocator.free(rendered);
                try out.appendSlice(allocator, rendered);
            }
        },
        .object => |object| {
            const keys = try sortedKeys(allocator, object);
            defer allocator.free(keys);

            for (keys, 0..) |key, index| {
                if (index > 0) {
                    try out.appendSlice(allocator, ", ");
                }

                const rendered_value = try renderJsonValue(allocator, object.get(key) orelse .null);
                defer allocator.free(rendered_value);
                const rendered_entry = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ key, rendered_value });
                defer allocator.free(rendered_entry);
                try out.appendSlice(allocator, rendered_entry);
            }
        },
    }

    return try out.toOwnedSlice(allocator);
}

fn escapeInlineCode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, allocator, input, "`", "\\`");
}

fn parseJsonValue(allocator: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, text, .{});
}

test "markdown renderer exposes plan heading prefix" {
    try std.testing.expectEqualStrings("# ", headingPrefix(.plan));
}

test "renders minimal plan and top-level fields" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try parseJsonValue(arena.allocator(), "{\"schemaVersion\":1,\"id\":\"minimal\",\"title\":\"Minimal Plan\"}");
    defer parsed.deinit();

    const markdown = try renderPlanMarkdown(allocator, parsed.value);
    defer allocator.free(markdown);

    try std.testing.expect(std.mem.indexOf(u8, markdown, "# Minimal Plan") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "- **Plan ID:** minimal") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "- **Schema Version:** 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "\n\n\n") == null);
}

test "normalizes excessive blank lines and trailing newline" {
    const allocator = std.testing.allocator;
    const normalized = try normalizeBlankLines(
        allocator,
        "# Title\n\n\n\nSection\n\n\n\n\n\n\nEnd\n\n\n\n",
    );
    defer allocator.free(normalized);

    try std.testing.expectEqualStrings("# Title\n\nSection\n\nEnd\n", normalized);
}

test "renders metadata key order deterministically" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try parseJsonValue(
        arena.allocator(),
        "{\"schemaVersion\":1,\"id\":\"ordered\",\"title\":\"Ordered Plan\",\"metadata\":{\"z\":1,\"a\":2,\"m\":3}}",
    );
    defer parsed.deinit();

    const markdown = try renderPlanMarkdown(allocator, parsed.value);
    defer allocator.free(markdown);

    const idx_a = std.mem.indexOf(u8, markdown, "- **a:** 2") orelse return error.TestUnexpectedResult;
    const idx_m = std.mem.indexOf(u8, markdown, "- **m:** 3") orelse return error.TestUnexpectedResult;
    const idx_z = std.mem.indexOf(u8, markdown, "- **z:** 1") orelse return error.TestUnexpectedResult;

    try std.testing.expect(idx_a < idx_m);
    try std.testing.expect(idx_m < idx_z);
}

test "renders epics and stories with core fields" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try parseJsonValue(arena.allocator(), "{\"schemaVersion\":1,\"id\":\"epics\",\"title\":\"Delivery Plan\",\"epics\":[{\"id\":\"area-1\",\"title\":\"Core Area\",\"summary\":\"Core area summary.\",\"description\":\"Epic description.\",\"status\":\"in-progress\",\"dependencies\":[\"prereq-area\"],\"stories\":[{\"id\":\"item-1\",\"title\":\"Task One\",\"status\":\"planned\",\"risk\":\"low\",\"dependencies\":[\"item-2\"],\"description\":\"Story description.\",\"details\":[\"Detail one.\"],\"acceptanceCriteria\":[\"Criterion one.\"],\"unitTests\":[\"Test one.\"],\"filesLikelyTouched\":[\"src/mod.ts\"]}]}] }");
    defer parsed.deinit();

    const markdown = try renderPlanMarkdown(allocator, parsed.value);
    defer allocator.free(markdown);

    for ([_][]const u8{
        "## Epics",
        "### area-1: Core Area",
        "Core area summary.",
        "Epic description.",
        "- **Status:** in-progress",
        "- **Dependencies:** prereq-area",
        "#### Stories",
        "##### item-1: Task One",
        "- **Status:** planned",
        "- **Risk:** low",
        "- **Dependencies:** item-2",
        "Story description.",
        "**Details:**",
        "- Detail one.",
        "**Acceptance Criteria:**",
        "- Criterion one.",
        "**Unit Tests:**",
        "- Test one.",
        "**Files Likely Touched:**",
        "- src/mod.ts",
    }) |expected| {
        try std.testing.expect(std.mem.indexOf(u8, markdown, expected) != null);
    }
}

test "renders changed files tree with status markers, stories, and indentation" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try parseJsonValue(arena.allocator(), "{\"schemaVersion\":1,\"id\":\"changed\",\"title\":\"Changed Plan\",\"changedFiles\":[{\"label\":\"Source\",\"root\":{\"name\":\"src\",\"type\":\"folder\",\"children\":[{\"name\":\"main.zig\",\"type\":\"file\",\"status\":\"new\",\"stories\":[\"E1.S1\",\"E2.S1\"]},{\"name\":\"cli.zig\",\"type\":\"file\",\"status\":\"modified\",\"stories\":[\"E1.S2\"]},{\"name\":\"utils\",\"type\":\"folder\",\"children\":[{\"name\":\"helpers.zig\",\"type\":\"file\",\"status\":\"modified\",\"stories\":[\"E2.S3\"]}]}]}},{\"root\":{\"name\":\"test\",\"type\":\"folder\",\"children\":[{\"name\":\"main.test.zig\",\"type\":\"file\",\"status\":\"new\"}]}}]}");
    defer parsed.deinit();

    const markdown = try renderPlanMarkdown(allocator, parsed.value);
    defer allocator.free(markdown);

    for ([_][]const u8{
        "## Changed Files",
        "### Source",
        "src",
        "  main.zig [new] (Stories: E1.S1, E2.S1)",
        "  cli.zig [mod] (Stories: E1.S2)",
        "  utils",
        "    helpers.zig [mod] (Stories: E2.S3)",
        "test",
        "  main.test.zig [new]",
    }) |expected| {
        try std.testing.expect(std.mem.indexOf(u8, markdown, expected) != null);
    }
}

test "renders deterministic nested json values" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try parseJsonValue(arena.allocator(), "{\"schemaVersion\":1,\"id\":\"nested\",\"title\":\"Nested Plan\",\"metadata\":{\"matrix\":[1,2,{\"b\":3,\"a\":1}],\"flag\":true,\"none\":null,\"obj\":{\"z\":0,\"a\":1}}}");
    defer parsed.deinit();

    const markdown = try renderPlanMarkdown(allocator, parsed.value);
    defer allocator.free(markdown);

    try std.testing.expect(std.mem.indexOf(u8, markdown, "- **flag:** true") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "- **none:** null") != null);
    const obj_start = std.mem.indexOf(u8, markdown, "- **obj:**") orelse return error.TestUnexpectedResult;
    const obj_line_end = std.mem.indexOfScalarPos(u8, markdown, obj_start, '\n') orelse markdown.len;
    const obj_line = markdown[obj_start..obj_line_end];
    const a_pos = std.mem.indexOf(u8, obj_line, "a: 1") orelse return error.TestUnexpectedResult;
    const z_pos = std.mem.indexOf(u8, obj_line, "z: 0") orelse return error.TestUnexpectedResult;
    try std.testing.expect(a_pos < z_pos);
}

test "renders sections and items" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try parseJsonValue(
        arena.allocator(),
        "{\"schemaVersion\":1,\"id\":\"sections\",\"title\":\"Section Plan\",\"sections\":[{\"id\":\"rules\",\"title\":\"Rules\",\"kind\":\"rules\",\"summary\":[\"Rule summary.\"],\"items\":[{\"title\":\"One\",\"text\":\"First rule.\"}]},{\"id\":\"arch\",\"title\":\"Architecture\",\"items\":[{\"text\":\"Second rule.\"}]}] }",
    );
    defer parsed.deinit();

    const markdown = try renderPlanMarkdown(allocator, parsed.value);
    defer allocator.free(markdown);

    for ([_][]const u8{
        "## Sections",
        "### rules: Rules",
        "- **Kind:** rules",
        "Rule summary.",
        "- **One:** First rule.",
        "### arch: Architecture",
        "- Second rule.",
    }) |expected| {
        try std.testing.expect(std.mem.indexOf(u8, markdown, expected) != null);
    }
}

test "renders recommended order and exit criteria" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try parseJsonValue(
        arena.allocator(),
        "{\"schemaVersion\":1,\"id\":\"remainder\",\"title\":\"Remainder Plan\",\"recommendedOrder\":[{\"ref\":\"item-1\",\"reason\":\"Dispatch first.\"}],\"exitCriteria\":[\"All tests pass.\"]}",
    );
    defer parsed.deinit();

    const markdown = try renderPlanMarkdown(allocator, parsed.value);
    defer allocator.free(markdown);

    for ([_][]const u8{
        "## Recommended Order",
        "1. **item-1**: Dispatch first.",
        "## Exit Criteria",
        "- All tests pass.",
    }) |expected| {
        try std.testing.expect(std.mem.indexOf(u8, markdown, expected) != null);
    }
}

test "renders section item without title" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try parseJsonValue(arena.allocator(), "{\"schemaVersion\":1,\"id\":\"item\",\"title\":\"Item Plan\",\"sections\":[{\"id\":\"notes\",\"title\":\"Notes\",\"kind\":\"notes\",\"items\":[{\"text\":\"Plain note.\"}]}]}");
    defer parsed.deinit();

    const markdown = try renderPlanMarkdown(allocator, parsed.value);
    defer allocator.free(markdown);

    try std.testing.expect(std.mem.indexOf(u8, markdown, "- Plain note.") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "**undefined**") == null);
}
