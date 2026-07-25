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

    if (getArray(plan, "workflows")) |workflows| {
        if (workflows.items.len > 0) {
            try out.writeLine("## Workflows");
            try out.writeLine("");

            for (workflows.items) |workflow| {
                if (workflow == .object) {
                    try renderWorkflow(out, workflow.object);
                }
            }
        }
    }

    if (getArray(plan, "commands")) |commands| {
        if (commands.items.len > 0) {
            try out.writeLine("## Commands");
            try out.writeLine("");

            for (commands.items) |command| {
                if (command == .object) {
                    try renderCommand(out, command.object);
                }
            }
        }
    }

    if (getArray(plan, "blockers")) |blockers| {
        if (blockers.items.len > 0) {
            try out.writeLine("## Blockers");
            try out.writeLine("");

            for (blockers.items) |blocker| {
                if (blocker == .object) {
                    try renderBlocker(out, blocker.object);
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

fn renderEpic(out: *MarkdownWriter, epic: std.json.ObjectMap) !void {
    const id = getString(epic, "id") orelse "";
    const title = getString(epic, "title") orelse "";

    try out.writeFormattedLine("### {s}: {s}", .{ id, title });

    if (getString(epic, "summary")) |summary| {
        try out.writeLine("");
        try out.writeLine(summary);
    }

    if (getString(epic, "status")) |status| {
        try out.writeLine("");
        try out.writeKVLine("- **Status:** {s}", status);
    }

    if (getStringList(epic, "tags", out.allocator)) |tags| {
        defer out.allocator.free(tags);
        const tags_text = try joinPrefixComma(out.allocator, "- **Tags:** ", tags);
        defer out.allocator.free(tags_text);
        try out.writeLine(tags_text);
    }

    if (getString(epic, "testFocus")) |test_focus| {
        try out.writeKVLine("- **Test Focus:** {s}", test_focus);
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

    if (getU64(story, "priority")) |priority| {
        try out.writeFormattedLine("- **Priority:** {d}", .{priority});
    }

    if (getString(story, "risk")) |risk| {
        try out.writeKVLine("- **Risk:** {s}", risk);
    }

    if (getString(story, "owner")) |owner| {
        try out.writeKVLine("- **Owner:** {s}", owner);
    }

    if (story.get("estimate")) |estimate| {
        if (estimate != .null) {
            const estimate_text = try renderJsonValue(out.allocator, estimate);
            defer out.allocator.free(estimate_text);
            try out.writeFormattedLine("- **Estimate:** {s}", .{estimate_text});
        }
    }

    if (getStringList(story, "tags", out.allocator)) |tags| {
        defer out.allocator.free(tags);
        const tags_text = try joinPrefixComma(out.allocator, "- **Tags:** ", tags);
        defer out.allocator.free(tags_text);
        try out.writeLine(tags_text);
    }

    if (getStringList(story, "dependencies", out.allocator)) |dependencies| {
        defer out.allocator.free(dependencies);
        const dependencies_text = try joinPrefixComma(out.allocator, "- **Dependencies:** ", dependencies);
        defer out.allocator.free(dependencies_text);
        try out.writeLine(dependencies_text);
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

    if (getStringList(story, "commandsToRun", out.allocator)) |commands| {
        defer out.allocator.free(commands);
        try out.writeLine("");
        try out.writeLine("**Commands to Run:**");
        try out.writeLine("");

        for (commands) |command| {
            try out.writeLine("```sh");
            try out.writeLine(command);
            try out.writeLine("```");
        }
    }

    if (getStringList(story, "artifacts", out.allocator)) |artifacts| {
        defer out.allocator.free(artifacts);
        try out.writeLine("");
        try out.writeLine("**Artifacts:**");
        try out.writeLine("");

        for (artifacts) |artifact| {
            try out.writeFormattedLine("- {s}", .{artifact});
        }
    }

    if (getStringList(story, "notes", out.allocator)) |notes| {
        defer out.allocator.free(notes);
        try out.writeLine("");
        try out.writeLine("**Notes:**");
        try out.writeLine("");

        for (notes) |note| {
            try out.writeFormattedLine("- {s}", .{note});
        }
    }

    try out.writeLine("");
}

fn renderSection(out: *MarkdownWriter, section: std.json.ObjectMap) !void {
    const id = getString(section, "id") orelse "";
    const title = getString(section, "title") orelse "";
    const kind = getString(section, "kind") orelse "";

    try out.writeFormattedLine("### {s}: {s}", .{ id, title });
    try out.writeLine("");
    try out.writeFormattedLine("- **Kind:** {s}", .{kind});

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

            if (getString(item_object, "status")) |status| {
                try row.appendSlice(out.allocator, " (");
                try row.appendSlice(out.allocator, status);
                try row.appendSlice(out.allocator, ")");
            }

            if (item_object.get("priority")) |priority| {
                if (priority == .integer and priority.integer > 0) {
                    const priority_text = try std.fmt.allocPrint(out.allocator, " [priority {d}]", .{priority.integer});
                    defer out.allocator.free(priority_text);
                    try row.appendSlice(out.allocator, priority_text);
                }
            }

            if (getStringList(item_object, "tags", out.allocator)) |tags| {
                defer out.allocator.free(tags);
                const joined = try joinPrefixComma(out.allocator, " [", tags);
                defer out.allocator.free(joined);
                const tags_text = try std.fmt.allocPrint(out.allocator, "{s}]", .{joined});
                defer out.allocator.free(tags_text);
                try row.appendSlice(out.allocator, tags_text);
            }

            if (getString(item_object, "ref")) |ref| {
                try row.appendSlice(out.allocator, " (ref: ");
                try row.appendSlice(out.allocator, ref);
                try row.appendSlice(out.allocator, ")");
            }

            const row_text = try row.toOwnedSlice(out.allocator);
            defer out.allocator.free(row_text);
            try out.writeLine(row_text);
        }

        try out.writeLine("");
    }

    if (getArray(section, "rows")) |rows| {
        const has_rows = rows.items.len > 0;
        if (has_rows) {
            const section_columns = try sectionColumns(out.allocator, section);
            defer out.allocator.free(section_columns);

            if (section_columns.len > 0) {
                const header = try sectionHeaderRow(out.allocator, section_columns);
                defer out.allocator.free(header);
                try out.writeLine(header);

                const separator = try sectionSeparatorRow(out.allocator, section_columns);
                defer out.allocator.free(separator);
                try out.writeLine(separator);

                for (rows.items) |row| {
                    if (row != .object) continue;

                    const line = try sectionRowLine(out.allocator, section_columns, row.object);
                    defer out.allocator.free(line);
                    try out.writeLine(line);
                }

                try out.writeLine("");
            }
        }
    }

    try out.writeLine("");
}

fn renderWorkflow(out: *MarkdownWriter, workflow: std.json.ObjectMap) !void {
    const id = getString(workflow, "id") orelse "";
    const title = getString(workflow, "title") orelse "";
    const kind = getString(workflow, "kind") orelse "";

    try out.writeFormattedLine("### {s}: {s}", .{ id, title });
    try out.writeLine("");
    try out.writeFormattedLine("- **Kind:** {s}", .{kind});
    try out.writeLine("");

    if (getArray(workflow, "steps")) |steps| {
        if (steps.items.len > 0) {
            try out.writeLine("**Steps:**");
            try out.writeLine("");

            var index: usize = 0;
            for (steps.items) |step| {
                const step_number = index + 1;
                if (step == .string) {
                    try out.writeFormattedLine("{d}. {s}", .{ step_number, step.string });
                } else if (step == .object) {
                    try renderWorkflowStep(out, step.object, step_number);
                }
                index += 1;
            }

            try out.writeLine("");
        }
    }

    try out.writeLine("");
}

fn renderWorkflowStep(out: *MarkdownWriter, workflow_step: std.json.ObjectMap, step_number: usize) !void {
    const step_text = getString(workflow_step, "text") orelse "";
    var line = try std.ArrayList(u8).initCapacity(out.allocator, 0);
    defer line.deinit(out.allocator);

    const prefix = try std.fmt.allocPrint(out.allocator, "{d}. {s}", .{ step_number, step_text });
    defer out.allocator.free(prefix);
    try line.appendSlice(out.allocator, prefix);

    if (getString(workflow_step, "id")) |id| {
        const id_text = try std.fmt.allocPrint(out.allocator, " ({s})", .{id});
        defer out.allocator.free(id_text);
        try line.appendSlice(out.allocator, id_text);
    }

    if (getString(workflow_step, "status")) |status| {
        const status_text = try std.fmt.allocPrint(out.allocator, " ({s})", .{status});
        defer out.allocator.free(status_text);
        try line.appendSlice(out.allocator, status_text);
    }

    const line_text = try line.toOwnedSlice(out.allocator);
    defer out.allocator.free(line_text);
    try out.writeLine(line_text);

    if (getString(workflow_step, "command")) |command| {
        try out.writeLine("   ```sh");
        try out.writeFormattedLine("   {s}", .{command});
        try out.writeLine("   ```");
    }

    if (getStringList(workflow_step, "expectedResults", out.allocator)) |results| {
        defer out.allocator.free(results);
        for (results) |result| {
            try out.writeFormattedLine("   - Expected: {s}", .{result});
        }
    }

    if (getStringList(workflow_step, "refs", out.allocator)) |refs| {
        defer out.allocator.free(refs);
        const refs_text = try joinPrefixComma(out.allocator, "   - Refs: ", refs);
        defer out.allocator.free(refs_text);
        try out.writeLine(refs_text);
    }
}

fn renderCommand(out: *MarkdownWriter, command: std.json.ObjectMap) !void {
    const title = getString(command, "title") orelse "";
    const command_text = getString(command, "command") orelse "";

    try out.writeFormattedLine("### {s}", .{title});
    try out.writeLine("");

    if (getString(command, "workingDirectory")) |working_directory| {
        const escaped_path = try escapeInlineCode(out.allocator, working_directory);
        defer out.allocator.free(escaped_path);
        try out.writeFormattedLine("- **Working Directory:** `{s}`", .{escaped_path});
    }

    if (getObject(command, "environment")) |environment| {
        if (environment.count() > 0) {
            try out.writeLine("- **Environment:**");

            const env_keys = try sortedKeys(out.allocator, environment);
            defer out.allocator.free(env_keys);

            for (env_keys) |env_key| {
                if (environment.get(env_key)) |env_value| {
                    if (env_value == .string) {
                        try out.writeFormattedLine("  - {s}={s}", .{ env_key, env_value.string });
                    }
                }
            }
        }
    }

    try out.writeLine("");
    try out.writeLine("```sh");
    try out.writeLine(command_text);
    try out.writeLine("```");

    if (getStringList(command, "expectedResults", out.allocator)) |expected_results| {
        defer out.allocator.free(expected_results);
        try out.writeLine("");
        try out.writeLine("**Expected Results:**");
        try out.writeLine("");

        for (expected_results) |result| {
            try out.writeFormattedLine("- {s}", .{result});
        }
    }

    if (getStringList(command, "refs", out.allocator)) |refs| {
        defer out.allocator.free(refs);
        const refs_text = try joinPrefixComma(out.allocator, "**Refs:** ", refs);
        defer out.allocator.free(refs_text);
        try out.writeLine("");
        try out.writeLine(refs_text);
    }

    try out.writeLine("");
}

fn renderBlocker(out: *MarkdownWriter, blocker: std.json.ObjectMap) !void {
    const area = getString(blocker, "area") orelse "";
    const required_fix = getString(blocker, "requiredFix") orelse "";
    const priority = blocker.get("priority");

    try out.writeFormattedLine("### Blocker: {s}", .{area});
    try out.writeLine("");

    if (priority) |priority_value| {
        if (priority_value == .integer) {
            try out.writeFormattedLine("- **Priority:** {d}", .{priority_value.integer});
        }
    }

    if (required_fix.len > 0) {
        try out.writeFormattedLine("- **Required Fix:** {s}", .{required_fix});
    }

    if (getString(blocker, "status")) |status| {
        try out.writeFormattedLine("- **Status:** {s}", .{status});
    }

    if (getStringList(blocker, "refs", out.allocator)) |refs| {
        defer out.allocator.free(refs);
        const refs_text = try joinPrefixComma(out.allocator, "- **Refs:** ", refs);
        defer out.allocator.free(refs_text);
        try out.writeLine(refs_text);
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

fn sectionColumns(allocator: std.mem.Allocator, section: std.json.ObjectMap) ![][]const u8 {
    const section_columns = getArray(section, "columns");
    if (section_columns) |columns| {
        if (columns.items.len > 0) {
            var result = try std.ArrayList([]const u8).initCapacity(allocator, 0);
            errdefer result.deinit(allocator);

            for (columns.items) |column| {
                if (column == .string) {
                    try result.append(allocator, column.string);
                }
            }

            return try result.toOwnedSlice(allocator);
        }
    }

    const rows = getArray(section, "rows") orelse {
        var empty_columns = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        return try empty_columns.toOwnedSlice(allocator);
    };

    var keys = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    errdefer keys.deinit(allocator);

    for (rows.items) |row| {
        if (row != .object) continue;
        var it = row.object.iterator();
        while (it.next()) |entry| {
            var exists = false;
            for (keys.items) |key| {
                if (std.mem.eql(u8, key, entry.key_ptr.*)) {
                    exists = true;
                    break;
                }
            }

            if (!exists) {
                try keys.append(allocator, entry.key_ptr.*);
            }
        }
    }

    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    return try keys.toOwnedSlice(allocator);
}

fn sectionHeaderRow(allocator: std.mem.Allocator, columns: []const []const u8) ![]const u8 {
    var row = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer row.deinit(allocator);

    try row.appendSlice(allocator, "| ");
    for (columns, 0..) |column, index| {
        if (index > 0) {
            try row.appendSlice(allocator, " | ");
        }
        try row.appendSlice(allocator, column);
    }
    try row.appendSlice(allocator, " |");

    return try row.toOwnedSlice(allocator);
}

fn sectionSeparatorRow(allocator: std.mem.Allocator, columns: []const []const u8) ![]const u8 {
    var row = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer row.deinit(allocator);

    try row.appendSlice(allocator, "| ");
    for (columns, 0..) |column, index| {
        _ = column;
        if (index > 0) {
            try row.appendSlice(allocator, " | ");
        }
        try row.appendSlice(allocator, "---");
    }
    try row.appendSlice(allocator, " |");

    return try row.toOwnedSlice(allocator);
}

fn sectionRowLine(allocator: std.mem.Allocator, columns: []const []const u8, row: std.json.ObjectMap) ![]const u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer buffer.deinit(allocator);

    try buffer.appendSlice(allocator, "| ");
    for (columns, 0..) |column, index| {
        if (index > 0) {
            try buffer.appendSlice(allocator, " | ");
        }

        const raw = row.get(column) orelse .null;
        const rendered = try renderJsonValue(allocator, raw);
        defer allocator.free(rendered);
        const escaped = try escapeTableCell(allocator, rendered);
        defer allocator.free(escaped);
        try buffer.appendSlice(allocator, escaped);
    }
    try buffer.appendSlice(allocator, " |");

    return try buffer.toOwnedSlice(allocator);
}

fn escapeTableCell(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const escaped_pipes = try std.mem.replaceOwned(u8, allocator, text, "|", "\\|");
    errdefer allocator.free(escaped_pipes);
    const escaped_newlines = try std.mem.replaceOwned(u8, allocator, escaped_pipes, "\n", " ");
    allocator.free(escaped_pipes);
    return escaped_newlines;
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

fn getU64(container: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = container.get(key) orelse return null;

    return switch (value) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        else => null,
    };
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

    const parsed = try parseJsonValue(arena.allocator(), "{\"schemaVersion\":1,\"id\":\"epics\",\"title\":\"Delivery Plan\",\"epics\":[{\"id\":\"area-1\",\"title\":\"Core Area\",\"summary\":\"Core area summary.\",\"status\":\"in-progress\",\"tags\":[\"cli\"],\"testFocus\":\"Argument parsing\",\"dependencies\":[\"prereq-area\"],\"stories\":[{\"id\":\"item-1\",\"title\":\"Task One\",\"status\":\"planned\",\"priority\":1,\"risk\":\"low\",\"owner\":\"agent\",\"estimate\":\"2h\",\"tags\":[\"parser\"],\"dependencies\":[\"item-2\"],\"details\":[\"Detail one.\"],\"acceptanceCriteria\":[\"Criterion one.\"],\"unitTests\":[\"Test one.\"],\"filesLikelyTouched\":[\"src/mod.ts\"],\"commandsToRun\":[\"task test\"],\"artifacts\":[\"dist/matcha\"],\"notes\":[\"Note one.\"]}]}] }");
    defer parsed.deinit();

    const markdown = try renderPlanMarkdown(allocator, parsed.value);
    defer allocator.free(markdown);

    for ([_][]const u8{
        "## Epics",
        "### area-1: Core Area",
        "Epic summary.",
        "- **Status:** in-progress",
        "- **Tags:** cli",
        "- **Test Focus:** Argument parsing",
        "- **Dependencies:** prereq-area",
        "#### Stories",
        "##### item-1: Task One",
        "- **Status:** planned",
        "- **Priority:** 1",
        "- **Risk:** low",
        "- **Owner:** agent",
        "- **Estimate:** 2h",
        "- **Tags:** parser",
        "- **Dependencies:** item-2",
        "**Details:**",
        "- Detail one.",
        "**Acceptance Criteria:**",
        "- Criterion one.",
        "**Unit Tests:**",
        "- Test one.",
        "**Files Likely Touched:**",
        "- src/mod.ts",
        "**Commands to Run:**",
        "```sh",
        "task test",
        "```",
        "**Artifacts:**",
        "- dist/matcha",
        "**Notes:**",
        "- Note one.",
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

test "renders sections and section tables" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try parseJsonValue(
        arena.allocator(),
        "{\"schemaVersion\":1,\"id\":\"sections\",\"title\":\"Section Plan\",\"sections\":[{\"id\":\"rules\",\"title\":\"Rules\",\"kind\":\"rules\",\"summary\":[\"Rule summary.\"],\"items\":[{\"title\":\"One\",\"text\":\"First rule.\",\"status\":\"draft\",\"priority\":1,\"tags\":[\"cli\"],\"ref\":\"item-1\"}]},{\"id\":\"arch\",\"title\":\"Architecture\",\"kind\":\"architecture\",\"columns\":[\"component\",\"responsibility\"],\"rows\":[{\"component\":\"Engine\",\"responsibility\":\"Logic\"},{\"component\":\"UI\",\"responsibility\":\"Display\"}]}] }",
    );
    defer parsed.deinit();

    const markdown = try renderPlanMarkdown(allocator, parsed.value);
    defer allocator.free(markdown);

    for ([_][]const u8{
        "## Sections",
        "### rules: Rules",
        "- **Kind:** rules",
        "Rule summary.",
        "- **One:** First rule. (draft) [priority 1] [cli] (ref: item-1)",
        "### arch: Architecture",
        "- **Kind:** architecture",
        "| component | responsibility |",
        "| --- | --- |",
        "| Engine | Logic |",
        "| UI | Display |",
    }) |expected| {
        try std.testing.expect(std.mem.indexOf(u8, markdown, expected) != null);
    }
}

test "renders inferred table columns and escaped table cells" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try parseJsonValue(
        arena.allocator(),
        "{\"schemaVersion\":1,\"id\":\"inferred\",\"title\":\"Inferred Table Plan\",\"sections\":[{\"id\":\"t\",\"title\":\"Table\",\"kind\":\"rules\",\"rows\":[{\"a\":\"one | two\",\"b\":\"line\\nbreak\"},{\"b\":\"only b\",\"a\":\"only a\"}]}]}",
    );
    defer parsed.deinit();

    const markdown = try renderPlanMarkdown(allocator, parsed.value);
    defer allocator.free(markdown);

    try std.testing.expect(std.mem.indexOf(u8, markdown, "| a | b |") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "| one \\| two | line break |") != null);
}

test "renders workflows commands blockers recommended order and exit criteria" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try parseJsonValue(
        arena.allocator(),
        "{\"schemaVersion\":1,\"id\":\"remainder\",\"title\":\"Remainder Plan\",\"workflows\":[{\"id\":\"flow\",\"title\":\"Flow\",\"kind\":\"ordered-steps\",\"steps\":[\"Simple step.\",{\"id\":\"step-2\",\"text\":\"Complex step.\",\"command\":\"task test\",\"expectedResults\":[\"Tests pass.\"],\"refs\":[\"item-1\"] ,\"status\":\"planned\"}]}],\"commands\":[{\"title\":\"Verify\",\"command\":\"task verify\",\"workingDirectory\":\"~/repos/matcha\",\"environment\":{\"HOME\":\"/tmp\"},\"expectedResults\":[\"Clean diff.\"],\"refs\":[\"item-4\"]}],\"blockers\":[{\"priority\":1,\"area\":\"Design\",\"requiredFix\":\"Decide CLI shape.\",\"status\":\"planned\",\"refs\":[\"item-2\"]}],\"recommendedOrder\":[{\"ref\":\"item-1\",\"reason\":\"Dispatch first.\"}],\"exitCriteria\":[\"All tests pass.\"]}",
    );
    defer parsed.deinit();

    const markdown = try renderPlanMarkdown(allocator, parsed.value);
    defer allocator.free(markdown);

    for ([_][]const u8{
        "## Workflows",
        "### flow: Flow",
        "- **Kind:** ordered-steps",
        "**Steps:**",
        "1. Simple step.",
        "2. Complex step. (step-2) (planned)",
        "   ```sh",
        "   task test",
        "   ```",
        "   - Expected: Tests pass.",
        "   - Refs: item-1",
        "## Commands",
        "### Verify",
        "- **Working Directory:** `~/repos/matcha`",
        "- **Environment:**",
        "  - HOME=/tmp",
        "```sh",
        "task verify",
        "```",
        "**Expected Results:**",
        "Clean diff.",
        "**Refs:** item-4",
        "## Blockers",
        "### Blocker: Design",
        "- **Priority:** 1",
        "- **Required Fix:** Decide CLI shape.",
        "- **Status:** planned",
        "- **Refs:** item-2",
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
