const std = @import("std");

pub const PathError = error{MissingHome} || std.mem.Allocator.Error;

pub fn isHomeRelative(input: []const u8) bool {
    return std.mem.eql(u8, input, "~") or
        std.mem.startsWith(u8, input, "~/") or
        std.mem.startsWith(u8, input, "~\\");
}

pub fn expandHomePath(
    allocator: std.mem.Allocator,
    input: []const u8,
) (std.mem.Allocator.Error || PathError)![]const u8 {
    if (!isHomeRelative(input)) {
        return input;
    }

    const home = try getHome(allocator);
    if (input.len == 1) {
        return home;
    }

    const buffer = allocator.alloc(u8, home.len + input.len - 1) catch |err| {
        allocator.free(home);
        return err;
    };
    std.mem.copyForwards(u8, buffer[0..home.len], home);
    std.mem.copyForwards(u8, buffer[home.len..], input[1..]);
    allocator.free(home);

    return buffer;
}

pub fn hasParentDirectory(input: []const u8) bool {
    return std.mem.lastIndexOfAny(u8, input, "/\\") != null;
}

pub fn parentDirectory(input: []const u8) ?[]const u8 {
    const index = std.mem.lastIndexOfAny(u8, input, "/\\") orelse return null;
    if (index == 0) return null;
    return input[0..index];
}

fn getHome(allocator: std.mem.Allocator) PathError![]const u8 {
    const home = std.c.getenv("HOME");
    if (home) |value| {
        return allocator.dupe(u8, std.mem.span(value));
    }

    const profile = std.c.getenv("USERPROFILE");
    if (profile) |value| {
        return allocator.dupe(u8, std.mem.span(value));
    }

    return error.MissingHome;
}

test "detects home-relative paths" {
    try std.testing.expect(isHomeRelative("~"));
    try std.testing.expect(isHomeRelative("~/plans/input.json"));
    try std.testing.expect(!isHomeRelative("/tmp/input.json"));
}

test "expands home path with HOME when available" {
    const home = getHome(std.testing.allocator) catch return;
    defer std.testing.allocator.free(home);
    const expanded = try expandHomePath(std.testing.allocator, "~/plans/input.json");
    defer std.testing.allocator.free(expanded);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}/plans/input.json", .{home});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, expanded);
}

test "detects parent directories" {
    try std.testing.expect(hasParentDirectory("dist/plan.html"));
    try std.testing.expect(!hasParentDirectory("plan.html"));
}

test "extracts parent directory for both separator styles" {
    try std.testing.expectEqualStrings("dist", parentDirectory("dist/plan.html").?);
    try std.testing.expectEqualStrings("out\\nested", parentDirectory("out\\nested\\plan.html").?);
}
