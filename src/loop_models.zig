const std = @import("std");
const options = @import("loop_options.zig");

pub const Model = struct {
    id: []const u8,
    name: []const u8,
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Model) = .empty,

    pub fn deinit(self: *Catalog) void {
        for (self.items.items) |model| {
            self.allocator.free(model.id);
            self.allocator.free(model.name);
        }
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    fn append(self: *Catalog, id: []const u8, name: []const u8) !void {
        const owned_id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned_id);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.items.append(self.allocator, .{ .id = owned_id, .name = owned_name });
    }
};

pub fn load(allocator: std.mem.Allocator, io: std.Io, backend: options.BackendKind, backend_bin: ?[]const u8) !Catalog {
    var catalog: Catalog = .{ .allocator = allocator };
    errdefer catalog.deinit();

    const executable = backend_bin orelse @tagName(backend);
    const argv: []const []const u8 = switch (backend) {
        .codex => &.{ executable, "debug", "models" },
        .droid => &.{ executable, "exec", "--help" },
        .agy => &.{ executable, "models" },
    };
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch return catalog;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return catalog;

    switch (backend) {
        .codex => try parseCodex(&catalog, result.stdout),
        .droid => try parseDroid(&catalog, result.stdout),
        .agy => try parseAgy(&catalog, result.stdout),
    }
    return catalog;
}

fn parseCodex(catalog: *Catalog, bytes: []const u8) !void {
    const Parsed = struct {
        models: []const struct {
            slug: []const u8,
            display_name: []const u8,
            visibility: []const u8 = "list",
        },
    };
    var parsed = std.json.parseFromSlice(Parsed, catalog.allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();
    for (parsed.value.models) |model| {
        if (std.mem.eql(u8, model.visibility, "list")) try catalog.append(model.slug, model.display_name);
    }
}

fn parseAgy(catalog: *Catalog, bytes: []const u8) !void {
    var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const id = std.mem.trim(u8, line[0..tab], " \t");
        const name = std.mem.trim(u8, line[tab + 1 ..], " \t");
        if (id.len > 0 and name.len > 0) try catalog.append(id, name);
    }
}

fn parseDroid(catalog: *Catalog, bytes: []const u8) !void {
    var in_catalog = false;
    var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.eql(u8, trimmed, "Available Models:") or std.mem.eql(u8, trimmed, "Custom Models:")) {
            in_catalog = true;
            continue;
        }
        if (!in_catalog) continue;
        if (trimmed.len == 0) continue;
        if (std.mem.endsWith(u8, trimmed, ":")) {
            if (std.mem.eql(u8, trimmed, "Reasoning Effort:") or
                std.mem.eql(u8, trimmed, "Pinning the Latest Model:") or
                std.mem.eql(u8, trimmed, "Authentication:") or
                std.mem.eql(u8, trimmed, "Examples:") or
                std.mem.eql(u8, trimmed, "Stream JSON-RPC Mode:") or
                std.mem.eql(u8, trimmed, "Mission Mode:") or
                std.mem.eql(u8, trimmed, "Autonomy Levels:") or
                std.mem.eql(u8, trimmed, "Session Flags:") or
                std.mem.eql(u8, trimmed, "Tool Controls:")) break;
            continue;
        }
        const leading = line.len - std.mem.trimStart(u8, line, " \t").len;
        if (leading == 0) continue;
        const content = line[leading..];
        var split: ?usize = null;
        var i: usize = 0;
        while (i + 1 < content.len) : (i += 1) {
            if (content[i] == ' ' and content[i + 1] == ' ') {
                split = i;
                break;
            }
        }
        const separator = split orelse continue;
        const id = std.mem.trim(u8, content[0..separator], " ");
        const name = std.mem.trim(u8, content[separator..], " ");
        if (id.len > 0 and name.len > 0) try catalog.append(id, name);
    }
}

test "codex model parsing releases partial allocations" {
    const json = "{\"models\":[{\"slug\":\"model-a\",\"display_name\":\"Model A\"},{\"slug\":\"model-b\",\"display_name\":\"Model B\"}]}";
    var saw_success = false;
    for (0..32) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var catalog: Catalog = .{ .allocator = failing.allocator() };
        parseCodex(&catalog, json) catch {};
        catalog.deinit();
        if (!failing.has_induced_failure) saw_success = true;
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (saw_success) break;
    }
    try std.testing.expect(saw_success);
}

test "custom executable model discovery preserves literal path and adapter arguments" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const filename = "discovery helper; literal 'quote' $dollar";
    {
        const file = try tmp.dir.createFile(io, filename, .{ .permissions = .executable_file });
        defer file.close(io);
        try file.writeStreamingAll(io,
            \\#!/bin/sh
            \\if [ "$#" = 2 ] && [ "$1" = debug ] && [ "$2" = models ]; then
            \\  printf '%s\n' '{"models":[{"slug":"custom-codex","display_name":"Custom Codex"}]}'
            \\elif [ "$#" = 2 ] && [ "$1" = exec ] && [ "$2" = --help ]; then
            \\  printf 'Available Models:\n  custom-droid  Custom Droid\n'
            \\elif [ "$#" = 1 ] && [ "$1" = models ]; then
            \\  printf 'custom-agy\tCustom Agy\n'
            \\else
            \\  exit 4
            \\fi
            \\
        );
    }
    const executable = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, filename });
    defer allocator.free(executable);
    const cases = [_]struct { backend: options.BackendKind, expected: []const u8 }{
        .{ .backend = .codex, .expected = "custom-codex" },
        .{ .backend = .droid, .expected = "custom-droid" },
        .{ .backend = .agy, .expected = "custom-agy" },
    };
    for (cases) |case| {
        var catalog = try load(allocator, io, case.backend, executable);
        defer catalog.deinit();
        try std.testing.expectEqual(@as(usize, 1), catalog.items.items.len);
        try std.testing.expectEqualStrings(case.expected, catalog.items.items[0].id);
    }
}
