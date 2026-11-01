const std = @import("std");

pub const RenderError = error{
    NotAnObject,
    MaxDepthExceeded,
    OutOfMemory,
};

pub const MAX_DEPTH: usize = 256;

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
            if (key) |name| {
                try self.writeEncodedKey(name);
            }
            try self.out.print(self.allocator, "[{d}]:", .{array.items.len});
            try self.writeInlineValues(array.items);
            return;
        }

        try self.beginLine(depth);
        if (key) |name| {
            try self.writeEncodedKey(name);
        }
        try self.out.print(self.allocator, "[{d}]:", .{array.items.len});
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
                if (array.items.len == 0) {
                    try self.out.appendSlice(self.allocator, "[]");
                } else if (allPrimitives(array.items)) {
                    try self.out.print(self.allocator, "[{d}]:", .{array.items.len});
                    try self.writeInlineValues(array.items);
                } else {
                    try self.out.print(self.allocator, "[{d}]:", .{array.items.len});
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

        switch (first_value) {
            .array => |array| {
                try self.beginLine(depth);
                try self.out.appendSlice(self.allocator, "- ");
                try self.writeEncodedKey(first_key);
                if (array.items.len == 0) {
                    try self.out.appendSlice(self.allocator, ": []");
                } else if (allPrimitives(array.items)) {
                    try self.out.print(self.allocator, "[{d}]:", .{array.items.len});
                    try self.writeInlineValues(array.items);
                } else {
                    try self.out.print(self.allocator, "[{d}]:", .{array.items.len});
                    for (array.items) |item| {
                        try self.writeListItem(item, depth + 2);
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

        while (iterator.next()) |entry| {
            try self.writeKeyValuePair(entry.key_ptr.*, entry.value_ptr.*, depth + 1);
        }
    }

    fn writeInlineValues(self: *ToonWriter, values: []const std.json.Value) RenderError!void {
        if (values.len == 0) return;

        try self.out.append(self.allocator, ' ');
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
    try writer.writeObject(plan_value.object, 0);

    return try out.toOwnedSlice(allocator);
}

fn validateDepth(depth: usize) RenderError!void {
    if (depth > MAX_DEPTH) {
        return RenderError.MaxDepthExceeded;
    }
}

fn allPrimitives(values: []const std.json.Value) bool {
    for (values) |value| {
        if (!isPrimitive(value)) return false;
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
