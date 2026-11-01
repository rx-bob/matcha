const std = @import("std");

pub const RenderError = error{
    NotAnObject,
    MaxDepthExceeded,
    OutOfMemory,
};

pub const MAX_DEPTH: usize = 256;

pub const FieldNode = struct {
    name: []const u8,
    children: ?[]FieldNode,

    pub fn deinit(self: *const FieldNode, allocator: std.mem.Allocator) void {
        if (self.children) |children| {
            for (children) |*child| {
                child.deinit(allocator);
            }
            allocator.free(children);
        }
    }
};

const ToonWriter = struct {
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    line_count: usize = 0,

    fn beginLine(self: *ToonWriter, depth: usize) RenderError!void {
        if (self.line_count > 0) {
            try self.out.append(self.allocator, '\n');
        }
        self.line_count += 1;
        try self.out.appendNTimes(self.allocator, ' ', depth * 2);
    }

    fn writeObject(self: *ToonWriter, object: std.json.ObjectMap, depth: usize) RenderError!void {
        try validateDepth(depth);
        var iterator = object.iterator();
        while (iterator.next()) |entry| {
            try self.writeKeyValuePair(entry.key_ptr.*, entry.value_ptr.*, depth);
        }
    }

    fn writeKeyValuePair(self: *ToonWriter, key: []const u8, value: std.json.Value, depth: usize) RenderError!void {
        switch (value) {
            .array => |array| try self.writeArray(key, array, depth),
            .object => |object| {
                if (try extractKeyedTabularFields(self.allocator, &object)) |fields| {
                    defer freeFields(self.allocator, fields);
                    try self.beginLine(depth);
                    try self.writeHeader(object.count(), key, fields, true);
                    try self.writeKeyedEntryRows(object, fields, depth + 1);
                    return;
                }

                try self.beginLine(depth);
                try self.writeEncodedKey(key);
                try self.out.append(self.allocator, ':');
                if (object.count() > 0) {
                    try self.writeObject(object, depth + 1);
                }
            },
            else => {
                try self.beginLine(depth);
                try self.writeEncodedKey(key);
                try self.out.appendSlice(self.allocator, ": ");
                try self.writePrimitive(value);
            },
        }
    }

    fn writeArray(self: *ToonWriter, key: ?[]const u8, array: std.json.Array, depth: usize) RenderError!void {
        try validateDepth(depth);

        if (array.items.len == 0) {
            try self.beginLine(depth);
            if (key) |name| {
                try self.writeEncodedKey(name);
                try self.out.appendSlice(self.allocator, ": []");
            } else {
                try self.out.appendSlice(self.allocator, "[]");
            }
            return;
        }

        if (allPrimitives(array.items)) {
            try self.beginLine(depth);
            try self.writeHeader(array.items.len, key, null, false);
            try self.writeInlineValues(array.items);
            return;
        }

        if (allObjects(array.items)) {
            if (try extractTabularFields(self.allocator, array.items)) |fields| {
                defer freeFields(self.allocator, fields);
                try self.beginLine(depth);
                try self.writeHeader(array.items.len, key, fields, false);
                try self.writeTabularRows(array.items, fields, depth + 1);
                return;
            }
        }

        try self.beginLine(depth);
        try self.writeHeader(array.items.len, key, null, false);
        for (array.items) |item| {
            try self.writeListItem(item, depth + 1);
        }
    }

    fn writeListItem(self: *ToonWriter, value: std.json.Value, depth: usize) RenderError!void {
        try validateDepth(depth);

        switch (value) {
            .array => |array| {
                try self.beginLine(depth);
                try self.out.appendSlice(self.allocator, "- ");
                try self.writeHeader(array.items.len, null, null, false);
                if (allPrimitives(array.items)) {
                    try self.writeInlineValues(array.items);
                } else {
                    for (array.items) |item| {
                        try self.writeListItem(item, depth + 1);
                    }
                }
            },
            .object => |object| try self.writeObjectListItem(object, depth),
            else => {
                try self.beginLine(depth);
                try self.out.appendSlice(self.allocator, "- ");
                try self.writePrimitive(value);
            },
        }
    }

    fn writeObjectListItem(self: *ToonWriter, object: std.json.ObjectMap, depth: usize) RenderError!void {
        if (object.count() == 0) {
            try self.beginLine(depth);
            try self.out.appendSlice(self.allocator, "-");
            return;
        }

        var iterator = object.iterator();
        const first = iterator.next().?;
        const first_key = first.key_ptr.*;
        const first_value = first.value_ptr.*;

        if (first_value == .array) {
            const array = first_value.array;
            if (array.items.len > 0 and allObjects(array.items)) {
                if (try extractTabularFields(self.allocator, array.items)) |fields| {
                    defer freeFields(self.allocator, fields);
                    try self.beginLine(depth);
                    try self.out.appendSlice(self.allocator, "- ");
                    try self.writeHeader(array.items.len, first_key, fields, false);
                    try self.writeTabularRows(array.items, fields, depth + 2);
                    try self.writeRemainingFields(&iterator, depth + 1);
                    return;
                }
            }
        }

        if (first_value == .object) {
            const first_object = first_value.object;
            if (try extractKeyedTabularFields(self.allocator, &first_object)) |fields| {
                defer freeFields(self.allocator, fields);
                try self.beginLine(depth);
                try self.out.appendSlice(self.allocator, "- ");
                try self.writeHeader(first_object.count(), first_key, fields, true);
                try self.writeKeyedEntryRows(first_object, fields, depth + 2);
                try self.writeRemainingFields(&iterator, depth + 1);
                return;
            }
        }

        switch (first_value) {
            .array => |array| {
                try self.beginLine(depth);
                try self.out.appendSlice(self.allocator, "- ");
                try self.writeEncodedKey(first_key);
                if (array.items.len == 0) {
                    try self.out.appendSlice(self.allocator, ": []");
                } else {
                    try self.writeHeader(array.items.len, null, null, false);
                    if (allPrimitives(array.items)) {
                        try self.writeInlineValues(array.items);
                    } else {
                        for (array.items) |item| {
                            try self.writeListItem(item, depth + 2);
                        }
                    }
                }
            },
            .object => |first_object| {
                try self.beginLine(depth);
                try self.out.appendSlice(self.allocator, "- ");
                try self.writeEncodedKey(first_key);
                try self.out.append(self.allocator, ':');
                if (first_object.count() > 0) {
                    try self.writeObject(first_object, depth + 2);
                }
            },
            else => {
                try self.beginLine(depth);
                try self.out.appendSlice(self.allocator, "- ");
                try self.writeEncodedKey(first_key);
                try self.out.appendSlice(self.allocator, ": ");
                try self.writePrimitive(first_value);
            },
        }

        try self.writeRemainingFields(&iterator, depth + 1);
    }

    fn writeRemainingFields(self: *ToonWriter, iterator: *std.json.ObjectMap.Iterator, depth: usize) RenderError!void {
        while (iterator.next()) |entry| {
            try self.writeKeyValuePair(entry.key_ptr.*, entry.value_ptr.*, depth);
        }
    }

    fn writeHeader(
        self: *ToonWriter,
        length: usize,
        key: ?[]const u8,
        fields: ?[]const FieldNode,
        keyed: bool,
    ) RenderError!void {
        if (key) |name| {
            try self.writeEncodedKey(name);
        }

        if (keyed) {
            try self.out.print(self.allocator, "[{d}:]", .{length});
        } else {
            try self.out.print(self.allocator, "[{d}]", .{length});
        }

        if (fields) |field_list| {
            try self.out.append(self.allocator, '{');
            try self.writeFieldSegment(field_list);
            try self.out.append(self.allocator, '}');
        }

        try self.out.append(self.allocator, ':');
    }

    fn writeFieldSegment(self: *ToonWriter, fields: []const FieldNode) RenderError!void {
        for (fields, 0..) |field, index| {
            if (index > 0) {
                try self.out.append(self.allocator, ',');
            }
            try self.writeEncodedKey(field.name);
            if (field.children) |children| {
                try self.out.append(self.allocator, '{');
                try self.writeFieldSegment(children);
                try self.out.append(self.allocator, '}');
            }
        }
    }

    fn writeTabularRows(
        self: *ToonWriter,
        rows: []const std.json.Value,
        fields: []const FieldNode,
        depth: usize,
    ) RenderError!void {
        for (rows) |row| {
            try self.writeTabularRow(row, fields, depth);
        }
    }

    fn writeTabularRow(
        self: *ToonWriter,
        value: std.json.Value,
        fields: []const FieldNode,
        depth: usize,
    ) RenderError!void {
        const row = switch (value) {
            .object => |object| object,
            else => unreachable,
        };

        var leaves = try std.ArrayList(std.json.Value).initCapacity(self.allocator, 0);
        defer leaves.deinit(self.allocator);
        try collectRowLeaves(self.allocator, &row, fields, &leaves);

        try self.beginLine(depth);
        try self.writeJoinedValues(leaves.items);
    }

    fn writeKeyedEntryRows(
        self: *ToonWriter,
        object: std.json.ObjectMap,
        fields: []const FieldNode,
        depth: usize,
    ) RenderError!void {
        var iterator = object.iterator();
        while (iterator.next()) |entry| {
            const row = switch (entry.value_ptr.*) {
                .object => |entry_object| entry_object,
                else => unreachable,
            };

            var leaves = try std.ArrayList(std.json.Value).initCapacity(self.allocator, 0);
            defer leaves.deinit(self.allocator);
            try collectRowLeaves(self.allocator, &row, fields, &leaves);

            try self.beginLine(depth);
            try self.writeEncodedKey(entry.key_ptr.*);
            try self.out.appendSlice(self.allocator, ": ");
            try self.writeJoinedValues(leaves.items);
        }
    }

    fn writeInlineValues(self: *ToonWriter, values: []const std.json.Value) RenderError!void {
        if (values.len == 0) return;

        try self.out.append(self.allocator, ' ');
        try self.writeJoinedValues(values);
    }

    fn writeJoinedValues(self: *ToonWriter, values: []const std.json.Value) RenderError!void {
        for (values, 0..) |value, index| {
            if (index > 0) {
                try self.out.append(self.allocator, ',');
            }
            try self.writePrimitive(value);
        }
    }

    fn writePrimitive(self: *ToonWriter, value: std.json.Value) RenderError!void {
        switch (value) {
            .null => try self.out.appendSlice(self.allocator, "null"),
            .bool => |boolean| try self.out.appendSlice(self.allocator, if (boolean) "true" else "false"),
            .integer => |integer| try self.out.print(self.allocator, "{d}", .{integer}),
            .float => |float| try writeCanonicalFloat(self, float),
            .number_string => |number| try writeCanonicalNumberString(self, number),
            .string => |string| {
                if (needsQuoting(string)) {
                    try self.writeQuotedString(string);
                } else {
                    try self.out.appendSlice(self.allocator, string);
                }
            },
            .array, .object => unreachable,
        }
    }

    fn writeEncodedKey(self: *ToonWriter, key: []const u8) RenderError!void {
        if (isValidUnquotedKey(key)) {
            try self.out.appendSlice(self.allocator, key);
        } else {
            try self.writeQuotedString(key);
        }
    }

    fn writeQuotedString(self: *ToonWriter, value: []const u8) RenderError!void {
        try self.out.append(self.allocator, '"');
        for (value) |byte| {
            switch (byte) {
                '\\' => try self.out.appendSlice(self.allocator, "\\\\"),
                '"' => try self.out.appendSlice(self.allocator, "\\\""),
                '\n' => try self.out.appendSlice(self.allocator, "\\n"),
                '\r' => try self.out.appendSlice(self.allocator, "\\r"),
                '\t' => try self.out.appendSlice(self.allocator, "\\t"),
                else => {
                    if (byte <= 0x1f) {
                        const hex = "0123456789abcdef";
                        try self.out.appendSlice(self.allocator, "\\u00");
                        try self.out.append(self.allocator, hex[byte >> 4]);
                        try self.out.append(self.allocator, hex[byte & 0x0f]);
                    } else {
                        try self.out.append(self.allocator, byte);
                    }
                },
            }
        }
        try self.out.append(self.allocator, '"');
    }
};

pub fn renderPlanToon(allocator: std.mem.Allocator, plan_value: std.json.Value) RenderError![]const u8 {
    if (plan_value != .object) {
        return RenderError.NotAnObject;
    }

    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer out.deinit(allocator);

    var writer = ToonWriter{ .out = &out, .allocator = allocator };

    if (try extractKeyedTabularFields(allocator, &plan_value.object)) |fields| {
        defer freeFields(allocator, fields);
        try writer.beginLine(0);
        try writer.writeHeader(plan_value.object.count(), null, fields, true);
        try writer.writeKeyedEntryRows(plan_value.object, fields, 1);
    } else {
        try writer.writeObject(plan_value.object, 0);
    }

    return try out.toOwnedSlice(allocator);
}

fn freeFields(allocator: std.mem.Allocator, fields: []FieldNode) void {
    for (fields) |*field| {
        field.deinit(allocator);
    }
    allocator.free(fields);
}

fn validateDepth(depth: usize) RenderError!void {
    if (depth > MAX_DEPTH) {
        return RenderError.MaxDepthExceeded;
    }
}

pub fn extractTabularFields(
    allocator: std.mem.Allocator,
    rows: []const std.json.Value,
) RenderError!?[]FieldNode {
    if (rows.len == 0) return null;

    const objects = try allocator.alloc(*const std.json.ObjectMap, rows.len);
    defer allocator.free(objects);

    for (rows, 0..) |*row, index| {
        switch (row.*) {
            .object => |*object| objects[index] = object,
            else => return null,
        }
    }

    return extractFieldsFromObjects(allocator, objects, 0);
}

pub fn extractKeyedTabularFields(
    allocator: std.mem.Allocator,
    object: *const std.json.ObjectMap,
) RenderError!?[]FieldNode {
    if (object.count() < 2) return null;

    const entry_objects = try allocator.alloc(*const std.json.ObjectMap, object.count());
    defer allocator.free(entry_objects);

    var iterator = object.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| {
        switch (entry.value_ptr.*) {
            .object => |*entry_object| {
                if (entry_object.count() == 0) return null;
                entry_objects[index] = entry_object;
            },
            else => return null,
        }
        index += 1;
    }

    return extractFieldsFromObjects(allocator, entry_objects, 0);
}

fn extractFieldsFromObjects(
    allocator: std.mem.Allocator,
    objects: []const *const std.json.ObjectMap,
    depth: usize,
) RenderError!?[]FieldNode {
    const first_keys = objects[0].keys();
    if (first_keys.len == 0) return null;

    for (objects) |object| {
        if (object.count() != first_keys.len) return null;
        for (first_keys) |key| {
            if (!object.contains(key)) return null;
        }
    }

    const column_values = try allocator.alloc(*const std.json.Value, objects.len);
    defer allocator.free(column_values);

    const fields = try allocator.alloc(FieldNode, first_keys.len);
    var built: usize = 0;
    errdefer {
        for (fields[0..built]) |*field| {
            field.deinit(allocator);
        }
        allocator.free(fields);
    }

    for (first_keys) |key| {
        for (objects, 0..) |object, index| {
            column_values[index] = object.getPtr(key).?;
        }

        const column = try classifyColumn(allocator, key, column_values, depth);
        if (column == null) {
            for (fields[0..built]) |*field| {
                field.deinit(allocator);
            }
            allocator.free(fields);
            return null;
        }

        fields[built] = column.?;
        built += 1;
    }

    return fields;
}

fn classifyColumn(
    allocator: std.mem.Allocator,
    name: []const u8,
    values: []const *const std.json.Value,
    depth: usize,
) RenderError!?FieldNode {
    var all_primitive = true;
    for (values) |value| {
        if (!isPrimitive(value.*)) {
            all_primitive = false;
            break;
        }
    }
    if (all_primitive) {
        return FieldNode{ .name = name, .children = null };
    }

    if (depth >= MAX_DEPTH) return null;

    const objects = try allocator.alloc(*const std.json.ObjectMap, values.len);
    defer allocator.free(objects);

    for (values, 0..) |value, index| {
        switch (value.*) {
            .object => |*object| {
                if (object.count() == 0) return null;
                objects[index] = object;
            },
            else => return null,
        }
    }

    const children = try extractFieldsFromObjects(allocator, objects, depth + 1);
    if (children == null) return null;

    return FieldNode{ .name = name, .children = children.? };
}

fn collectRowLeaves(
    allocator: std.mem.Allocator,
    row: *const std.json.ObjectMap,
    fields: []const FieldNode,
    leaves: *std.ArrayList(std.json.Value),
) RenderError!void {
    for (fields) |field| {
        const value = row.getPtr(field.name).?;

        if (field.children) |children| {
            switch (value.*) {
                .object => |*nested| try collectRowLeaves(allocator, nested, children, leaves),
                else => unreachable,
            }
        } else {
            try leaves.append(allocator, value.*);
        }
    }
}

fn allPrimitives(values: []const std.json.Value) bool {
    for (values) |value| {
        if (!isPrimitive(value)) return false;
    }
    return true;
}

fn allObjects(values: []const std.json.Value) bool {
    for (values) |value| {
        if (value != .object) return false;
    }
    return true;
}

fn isPrimitive(value: std.json.Value) bool {
    return switch (value) {
        .null, .bool, .integer, .float, .number_string, .string => true,
        .array, .object => false,
    };
}

fn writeCanonicalFloat(writer: *ToonWriter, value: f64) RenderError!void {
    if (!std.math.isFinite(value)) {
        try writer.out.appendSlice(writer.allocator, "null");
        return;
    }

    // The upper bound is exclusive: `i64::MAX as f64` rounds up to 2^63,
    // which is one past the last representable i64.
    if (@trunc(value) == value and value >= -9223372036854775808.0 and value < 9223372036854775808.0) {
        const integer: i64 = @intFromFloat(value);
        try writer.out.print(writer.allocator, "{d}", .{integer});
        return;
    }

    try writer.out.print(writer.allocator, "{d}", .{value});
}

fn writeCanonicalNumberString(writer: *ToonWriter, value: []const u8) RenderError!void {
    if (std.fmt.parseInt(i64, value, 10)) |integer| {
        try writer.out.print(writer.allocator, "{d}", .{integer});
        return;
    } else |_| {}

    if (std.fmt.parseInt(u64, value, 10)) |integer| {
        try writer.out.print(writer.allocator, "{d}", .{integer});
        return;
    } else |_| {}

    if (std.fmt.parseFloat(f64, value)) |float| {
        try writeCanonicalFloat(writer, float);
        return;
    } else |_| {}

    try writer.out.appendSlice(writer.allocator, value);
}

pub fn isValidUnquotedKey(key: []const u8) bool {
    if (key.len == 0) return false;

    const first = key[0];
    if (!std.ascii.isAlphabetic(first) and first != '_') return false;

    for (key[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '.') return false;
    }
    return true;
}

pub fn isKeyword(value: []const u8) bool {
    return std.mem.eql(u8, value, "null") or
        std.mem.eql(u8, value, "true") or
        std.mem.eql(u8, value, "false");
}

pub fn isNumericLike(value: []const u8) bool {
    var index: usize = 0;

    if (index < value.len and (value[index] == '+' or value[index] == '-')) {
        index += 1;
    }

    const integer_start = index;
    while (index < value.len and std.ascii.isDigit(value[index])) {
        index += 1;
    }
    if (index == integer_start) return false;

    if (index < value.len and value[index] == '.') {
        index += 1;
        const fraction_start = index;
        while (index < value.len and std.ascii.isDigit(value[index])) {
            index += 1;
        }
        if (index == fraction_start) return false;
    }

    if (index < value.len and (value[index] == 'e' or value[index] == 'E')) {
        index += 1;
        if (index < value.len and (value[index] == '+' or value[index] == '-')) {
            index += 1;
        }
        const exponent_start = index;
        while (index < value.len and std.ascii.isDigit(value[index])) {
            index += 1;
        }
        if (index == exponent_start) return false;
    }

    return index == value.len;
}

pub fn needsQuoting(value: []const u8) bool {
    if (value.len == 0) return true;

    const first = value[0];
    const last = value[value.len - 1];
    if (first == ' ' or first == '\t' or last == ' ' or last == '\t') {
        return true;
    }

    if (isKeyword(value) or isNumericLike(value)) {
        return true;
    }

    for (value) |byte| {
        switch (byte) {
            ':', '"', '\\', '[', ']', '{', '}', ',' => return true,
            else => if (byte <= 0x1f) return true,
        }
    }

    return first == '-' or first == '#';
}

fn renderJson(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();
    return renderPlanToon(allocator, parsed.value);
}

test "validates unquoted and quoted keys per TOON §7.3" {
    try std.testing.expect(isValidUnquotedKey("normal_key"));
    try std.testing.expect(isValidUnquotedKey("key.value"));
    try std.testing.expect(isValidUnquotedKey("_private"));
    try std.testing.expect(isValidUnquotedKey("KeyName"));
    try std.testing.expect(isValidUnquotedKey("key."));

    try std.testing.expect(!isValidUnquotedKey(""));
    try std.testing.expect(!isValidUnquotedKey("123"));
    try std.testing.expect(!isValidUnquotedKey("key-value"));
    try std.testing.expect(!isValidUnquotedKey("key value"));
    try std.testing.expect(!isValidUnquotedKey(".key"));
    try std.testing.expect(!isValidUnquotedKey("café"));

    const allocator = std.testing.allocator;
    const output = try renderJson(allocator, "{\"café\":1,\"key-value\":2,\"\":3,\"123\":4}");
    defer allocator.free(output);

    try std.testing.expectEqualStrings(
        "\"café\": 1\n\"key-value\": 2\n\"\": 3\n\"123\": 4",
        output,
    );
}

test "quotes and escapes strings per TOON §7.1 and §7.2" {
    try std.testing.expect(needsQuoting(""));
    try std.testing.expect(needsQuoting("true"));
    try std.testing.expect(needsQuoting("false"));
    try std.testing.expect(needsQuoting("null"));
    try std.testing.expect(needsQuoting("123"));
    try std.testing.expect(needsQuoting("+1"));
    try std.testing.expect(needsQuoting("05"));
    try std.testing.expect(needsQuoting("1e-3"));
    try std.testing.expect(needsQuoting("key:value"));
    try std.testing.expect(needsQuoting("hello[world]"));
    try std.testing.expect(needsQuoting("a,b"));
    try std.testing.expect(needsQuoting(" hello"));
    try std.testing.expect(needsQuoting("hello "));
    try std.testing.expect(needsQuoting("\thello"));
    try std.testing.expect(needsQuoting("#"));
    try std.testing.expect(needsQuoting("#hello"));
    try std.testing.expect(needsQuoting("-"));
    try std.testing.expect(needsQuoting("-dash"));
    try std.testing.expect(needsQuoting("a\u{0004}b"));
    try std.testing.expect(!needsQuoting("hello"));
    try std.testing.expect(!needsQuoting("hello world"));
    try std.testing.expect(!needsQuoting("café"));

    const allocator = std.testing.allocator;
    const output = try renderJson(
        allocator,
        "{\"empty\":\"\",\"keyword\":\"true\",\"numeric\":\"123\",\"plus\":\"+1\"," ++
            "\"leadingZero\":\"05\",\"exponent\":\"1e-3\",\"comma\":\"a,b\"," ++
            "\"colon\":\"key:value\",\"bracket\":\"hello[world]\",\"dash\":\"-dash\"," ++
            "\"hash\":\"#hello\",\"leadingSpace\":\" hello\",\"trailingSpace\":\"hello \"," ++
            "\"plain\":\"hello world\",\"cafe\":\"café\"," ++
            "\"escaped\":\"say \\\"hi\\\"\\nline\\tend\",\"control\":\"a\\u0004b\"}",
    );
    defer allocator.free(output);

    try std.testing.expectEqualStrings(
        "empty: \"\"\n" ++
            "keyword: \"true\"\n" ++
            "numeric: \"123\"\n" ++
            "plus: \"+1\"\n" ++
            "leadingZero: \"05\"\n" ++
            "exponent: \"1e-3\"\n" ++
            "comma: \"a,b\"\n" ++
            "colon: \"key:value\"\n" ++
            "bracket: \"hello[world]\"\n" ++
            "dash: \"-dash\"\n" ++
            "hash: \"#hello\"\n" ++
            "leadingSpace: \" hello\"\n" ++
            "trailingSpace: \"hello \"\n" ++
            "plain: hello world\n" ++
            "cafe: café\n" ++
            "escaped: \"say \\\"hi\\\"\\nline\\tend\"\n" ++
            "control: \"a\\u0004b\"",
        output,
    );
}

test "formats canonical numbers without exponents or trailing zeros" {
    const allocator = std.testing.allocator;

    var object: std.json.ObjectMap = .empty;
    defer object.deinit(allocator);
    try object.put(allocator, "integer", .{ .integer = 42 });
    try object.put(allocator, "negative", .{ .integer = -123 });
    try object.put(allocator, "negativeZero", .{ .float = -0.0 });
    try object.put(allocator, "rounded", .{ .float = 1.5 });
    try object.put(allocator, "million", .{ .float = 1e6 });
    try object.put(allocator, "micro", .{ .float = 1e-6 });
    try object.put(allocator, "nan", .{ .float = std.math.nan(f64) });
    try object.put(allocator, "infinity", .{ .float = std.math.inf(f64) });
    try object.put(allocator, "negativeInfinity", .{ .float = -std.math.inf(f64) });
    try object.put(allocator, "big", .{ .number_string = "9223372036854775808" });

    const output = try renderPlanToon(allocator, .{ .object = object });
    defer allocator.free(output);

    try std.testing.expectEqualStrings(
        "integer: 42\n" ++
            "negative: -123\n" ++
            "negativeZero: 0\n" ++
            "rounded: 1.5\n" ++
            "million: 1000000\n" ++
            "micro: 0.000001\n" ++
            "nan: null\n" ++
            "infinity: null\n" ++
            "negativeInfinity: null\n" ++
            "big: 9223372036854775808",
        output,
    );
}

test "encodes simple and nested objects and inline primitive arrays" {
    const allocator = std.testing.allocator;
    const output = try renderJson(
        allocator,
        "{\"name\":\"Alice\",\"age\":30,\"tags\":[\"a\",\"b\",\"c\"]," ++
            "\"user\":{\"name\":\"Bob\",\"roles\":[\"admin\"]},\"items\":[],\"empty\":{}}",
    );
    defer allocator.free(output);

    try std.testing.expectEqualStrings(
        "name: Alice\n" ++
            "age: 30\n" ++
            "tags[3]: a,b,c\n" ++
            "user:\n" ++
            "  name: Bob\n" ++
            "  roles[1]: admin\n" ++
            "items: []\n" ++
            "empty:",
        output,
    );

    try std.testing.expectError(RenderError.NotAnObject, renderPlanToon(allocator, .{ .integer = 1 }));
}

test "encodes tabular arrays and nested field groups" {
    const allocator = std.testing.allocator;

    const users = try renderJson(
        allocator,
        "{\"users\":[{\"id\":1,\"name\":\"Alice\"},{\"id\":2,\"name\":\"Bob\"}]}",
    );
    defer allocator.free(users);
    try std.testing.expectEqualStrings(
        "users[2]{id,name}:\n  1,Alice\n  2,Bob",
        users,
    );

    const orders = try renderJson(
        allocator,
        "{\"orders\":[" ++
            "{\"id\":1,\"customer\":{\"name\":\"Ada\",\"country\":\"DK\"},\"total\":99}," ++
            "{\"id\":2,\"customer\":{\"name\":\"Bob\",\"country\":\"UK\"},\"total\":149}]}",
    );
    defer allocator.free(orders);
    try std.testing.expectEqualStrings(
        "orders[2]{id,customer{name,country},total}:\n  1,Ada,DK,99\n  2,Bob,UK,149",
        orders,
    );

    const reordered = try renderJson(
        allocator,
        "{\"users\":[{\"id\":1,\"name\":\"Alice\"},{\"name\":\"Bob\",\"id\":2}]}",
    );
    defer allocator.free(reordered);
    try std.testing.expectEqualStrings(
        "users[2]{id,name}:\n  1,Alice\n  2,Bob",
        reordered,
    );
}

test "encodes keyed tabular objects at field and root positions" {
    const allocator = std.testing.allocator;

    const servers = try renderJson(
        allocator,
        "{\"servers\":{" ++
            "\"alpha\":{\"host\":\"a.example.com\",\"port\":8080}," ++
            "\"beta\":{\"host\":\"b.example.com\",\"port\":9090}}}",
    );
    defer allocator.free(servers);
    try std.testing.expectEqualStrings(
        "servers[2:]{host,port}:\n  alpha: a.example.com,8080\n  beta: b.example.com,9090",
        servers,
    );

    const root = try renderJson(
        allocator,
        "{\"alice\":{\"age\":30,\"city\":\"Berlin\"},\"bob\":{\"age\":25,\"city\":\"Oslo\"}}",
    );
    defer allocator.free(root);
    try std.testing.expectEqualStrings(
        "[2:]{age,city}:\n  alice: 30,Berlin\n  bob: 25,Oslo",
        root,
    );
}

test "encodes list items and object list items with §10 first-field rules" {
    const allocator = std.testing.allocator;

    const mixed = try renderJson(allocator, "{\"items\":[1,[2,3],{\"a\":1}]}");
    defer allocator.free(mixed);
    try std.testing.expectEqualStrings(
        "items[3]:\n  - 1\n  - [2]: 2,3\n  - a: 1",
        mixed,
    );

    const empty_objects = try renderJson(allocator, "{\"items\":[{},{}]}");
    defer allocator.free(empty_objects);
    try std.testing.expectEqualStrings("items[2]:\n  -\n  -", empty_objects);

    const primitive_arrays = try renderJson(allocator, "{\"matrix\":[[1,2],[3,4]]}");
    defer allocator.free(primitive_arrays);
    try std.testing.expectEqualStrings(
        "matrix[2]:\n  - [2]: 1,2\n  - [2]: 3,4",
        primitive_arrays,
    );

    const empty_inner_arrays = try renderJson(allocator, "{\"items\":[[],[]]}");
    defer allocator.free(empty_inner_arrays);
    try std.testing.expectEqualStrings(
        "items[2]:\n  - [0]:\n  - [0]:",
        empty_inner_arrays,
    );

    const siblings = try renderJson(
        allocator,
        "{\"items\":[{\"name\":\"a\",\"tags\":[\"x\",\"y\"],\"meta\":{\"k\":1},\"rest\":true}," ++
            "{\"name\":\"b\"}]}",
    );
    defer allocator.free(siblings);
    try std.testing.expectEqualStrings(
        "items[2]:\n" ++
            "  - name: a\n" ++
            "    tags[2]: x,y\n" ++
            "    meta:\n" ++
            "      k: 1\n" ++
            "    rest: true\n" ++
            "  - name: b",
        siblings,
    );

    const nested_array = try renderJson(
        allocator,
        "{\"items\":[{\"rows\":[[1,2],[3,4]],\"x\":1}]}",
    );
    defer allocator.free(nested_array);
    try std.testing.expectEqualStrings(
        "items[1]:\n" ++
            "  - rows[2]:\n" ++
            "      - [2]: 1,2\n" ++
            "      - [2]: 3,4\n" ++
            "    x: 1",
        nested_array,
    );

    const tabular_first = try renderJson(
        allocator,
        "{\"items\":[{\"users\":[{\"id\":1,\"name\":\"A\"},{\"id\":2,\"name\":\"B\"}],\"note\":\"n\"}]}",
    );
    defer allocator.free(tabular_first);
    try std.testing.expectEqualStrings(
        "items[1]:\n" ++
            "  - users[2]{id,name}:\n" ++
            "      1,A\n" ++
            "      2,B\n" ++
            "    note: n",
        tabular_first,
    );

    const keyed_first = try renderJson(
        allocator,
        "{\"items\":[{\"servers\":{\"a\":{\"host\":\"h\",\"port\":1},\"b\":{\"host\":\"i\",\"port\":2}},\"note\":\"n\"},{\"other\":1}]}",
    );
    defer allocator.free(keyed_first);
    try std.testing.expectEqualStrings(
        "items[2]:\n" ++
            "  - servers[2:]{host,port}:\n" ++
            "      a: h,1\n" ++
            "      b: i,2\n" ++
            "    note: n\n" ++
            "  - other: 1",
        keyed_first,
    );
}

test "enforces max nesting depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var value: std.json.Value = .{ .integer = 1 };
    for (0..MAX_DEPTH + 2) |_| {
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "n", value);
        value = .{ .object = object };
    }

    try std.testing.expectError(
        RenderError.MaxDepthExceeded,
        renderPlanToon(std.testing.allocator, value),
    );
}
