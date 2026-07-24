const std = @import("std");

const errors = @import("errors.zig");
const path = @import("path.zig");

pub const default_host: []const u8 = "0.0.0.0";
pub const default_port: u16 = 27004;
pub const default_interval_seconds: u32 = 5;

pub const ExitCode = enum(u8) {
    ok = 0,
    usage = 1,
    failure = 2,
};

pub const ServeOptions = struct {
    directory: []const u8,
    directory_set: bool = false,
    host: []const u8 = default_host,
    port: u16 = default_port,
    interval_seconds: u32 = default_interval_seconds,
};

pub const ServeOptionsResult = union(enum) {
    ok: ServeOptions,
    err: errors.CliError,
};

pub const ParseError = error{
    InvalidPort,
    InvalidInterval,
};

pub fn parsePort(text: []const u8) ParseError!u16 {
    if (text.len == 0) return ParseError.InvalidPort;
    for (text) |byte| {
        if (byte < '0' or byte > '9') return ParseError.InvalidPort;
    }
    const value = std.fmt.parseInt(u16, text, 10) catch return ParseError.InvalidPort;
    if (value == 0) return ParseError.InvalidPort;
    return value;
}

pub fn parseInterval(text: []const u8) ParseError!u32 {
    if (text.len == 0) return ParseError.InvalidInterval;
    for (text) |byte| {
        if (byte < '0' or byte > '9') return ParseError.InvalidInterval;
    }
    const value = std.fmt.parseInt(u32, text, 10) catch return ParseError.InvalidInterval;
    if (value == 0) return ParseError.InvalidInterval;
    return value;
}

pub fn parseServeOptions(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) ServeOptionsResult {
    var directory: []const u8 = "";
    var directory_set = false;
    var host: []const u8 = default_host;
    var port: u16 = default_port;
    var interval_seconds: u32 = default_interval_seconds;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "--host")) {
            index += 1;
            const value = readFlagValue(args, index) orelse
                return .{ .err = .{ .missing_value = arg } };
            host = value;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--host=")) {
            host = arg["--host=".len..];
            continue;
        }

        if (std.mem.eql(u8, arg, "--port")) {
            index += 1;
            const value = readFlagValue(args, index) orelse
                return .{ .err = .{ .missing_value = arg } };
            port = parsePort(value) catch
                return .{ .err = .{ .invalid_port = value } };
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--port=")) {
            const value = arg["--port=".len..];
            port = parsePort(value) catch
                return .{ .err = .{ .invalid_port = value } };
            continue;
        }

        if (std.mem.eql(u8, arg, "--interval")) {
            index += 1;
            const value = readFlagValue(args, index) orelse
                return .{ .err = .{ .missing_value = arg } };
            interval_seconds = parseInterval(value) catch
                return .{ .err = .{ .invalid_interval = value } };
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--interval=")) {
            const value = arg["--interval=".len..];
            interval_seconds = parseInterval(value) catch
                return .{ .err = .{ .invalid_interval = value } };
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--")) {
            return .{ .err = .{ .unknown_option = arg } };
        }

        if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            return .{ .err = .{ .unknown_option = arg } };
        }

        if (!directory_set) {
            directory = arg;
            directory_set = true;
            continue;
        }

        return .{ .err = .{ .extra_arguments = arg } };
    }

    if (directory_set) {
        const normalized = path.expandHomePath(allocator, directory) catch |err| switch (err) {
            error.MissingHome => return .{ .err = .{ .missing_home = directory } },
            else => return .{ .err = .{ .path_error = directory } },
        };

        return .{ .ok = .{
            .directory = normalized,
            .directory_set = true,
            .host = host,
            .port = port,
            .interval_seconds = interval_seconds,
        } };
    }

    // No directory provided: return options without a resolved directory. The
    // caller decides whether to prompt interactively or emit a usage error.
    return .{ .ok = .{
        .directory = "",
        .directory_set = false,
        .host = host,
        .port = port,
        .interval_seconds = interval_seconds,
    } };
}

fn readFlagValue(args: []const []const u8, index: usize) ?[]const u8 {
    if (index >= args.len or std.mem.startsWith(u8, args[index], "-")) {
        return null;
    }
    return args[index];
}

pub fn validateDirectory(io: std.Io, directory: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, directory, .{}) catch return false;
    return stat.kind == .directory;
}

test "parseServeOptions accepts directory with defaults" {
    const allocator = std.testing.allocator;
    const result = parseServeOptions(allocator, &.{"~/matcha"});
    const options = switch (result) {
        .ok => |options| options,
        .err => unreachable,
    };

    const home = path.expandHomePath(allocator, "~") catch unreachable;
    defer allocator.free(home);
    try std.testing.expectEqualStrings(home ++ "/matcha", options.directory);
    try std.testing.expect(options.directory_set);
    try std.testing.expectEqualStrings(default_host, options.host);
    try std.testing.expectEqual(default_port, options.port);
    try std.testing.expectEqual(default_interval_seconds, options.interval_seconds);
}

test "parseServeOptions accepts explicit directory without home marker" {
    const allocator = std.testing.allocator;
    const result = parseServeOptions(allocator, &.{"/tmp/matcha"});
    const options = switch (result) {
        .ok => |options| options,
        .err => unreachable,
    };
    try std.testing.expectEqualStrings("/tmp/matcha", options.directory);
    try std.testing.expect(options.directory_set);
}

test "parseServeOptions parses separated flag overrides" {
    const allocator = std.testing.allocator;
    const result = parseServeOptions(allocator, &.{
        "/tmp/matcha",
        "--host",
        "127.0.0.1",
        "--port",
        "8123",
        "--interval",
        "10",
    });
    const options = switch (result) {
        .ok => |options| options,
        .err => unreachable,
    };
    try std.testing.expectEqualStrings("/tmp/matcha", options.directory);
    try std.testing.expectEqualStrings("127.0.0.1", options.host);
    try std.testing.expectEqual(@as(u16, 8123), options.port);
    try std.testing.expectEqual(@as(u32, 10), options.interval_seconds);
}

test "parseServeOptions parses equals-style flag overrides" {
    const allocator = std.testing.allocator;
    const result = parseServeOptions(allocator, &.{
        "--host=127.0.0.1",
        "--port=8123",
        "--interval=10",
        "/tmp/matcha",
    });
    const options = switch (result) {
        .ok => |options| options,
        .err => unreachable,
    };
    try std.testing.expectEqualStrings("/tmp/matcha", options.directory);
    try std.testing.expectEqualStrings("127.0.0.1", options.host);
    try std.testing.expectEqual(@as(u16, 8123), options.port);
    try std.testing.expectEqual(@as(u32, 10), options.interval_seconds);
}

test "parseServeOptions rejects missing flag values" {
    const allocator = std.testing.allocator;
    try expectError(.missing_value, "--host", parseServeOptions(allocator, &.{"--host"}));
    try expectError(.missing_value, "--port", parseServeOptions(allocator, &.{"--port"}));
    try expectError(.missing_value, "--interval", parseServeOptions(allocator, &.{"--interval"}));
    try expectError(
        .missing_value,
        "--host",
        parseServeOptions(allocator, &.{ "/tmp/matcha", "--host", "--port", "80" }),
    );
}

test "parseServeOptions rejects unknown flags" {
    const allocator = std.testing.allocator;
    try expectError(.unknown_option, "--theme", parseServeOptions(allocator, &.{ "--theme", "dracula" }));
    try expectError(.unknown_option, "-x", parseServeOptions(allocator, &.{"-x"}));
}

test "parseServeOptions rejects extra positional arguments" {
    const allocator = std.testing.allocator;
    try expectError(
        .extra_arguments,
        "/tmp/other",
        parseServeOptions(allocator, &.{ "/tmp/matcha", "/tmp/other" }),
    );
}

test "parseServeOptions leaves directory unset when missing" {
    const allocator = std.testing.allocator;
    const result = parseServeOptions(allocator, &.{});
    const options = switch (result) {
        .ok => |options| options,
        .err => unreachable,
    };
    try std.testing.expectEqualStrings("", options.directory);
    try std.testing.expect(!options.directory_set);
    try std.testing.expectEqualStrings(default_host, options.host);
    try std.testing.expectEqual(default_port, options.port);
    try std.testing.expectEqual(default_interval_seconds, options.interval_seconds);
}

test "parseServeOptions rejects invalid ports" {
    const allocator = std.testing.allocator;
    try expectError(.invalid_port, "0", parseServeOptions(allocator, &.{ "--port", "0", "/tmp/matcha" }));
    try expectError(.invalid_port, "abc", parseServeOptions(allocator, &.{ "--port", "abc", "/tmp/matcha" }));
    try expectError(.invalid_port, "65536", parseServeOptions(allocator, &.{ "--port=65536", "/tmp/matcha" }));
    try expectError(.invalid_port, "", parseServeOptions(allocator, &.{ "--port=", "/tmp/matcha" }));
    try expectError(.invalid_port, "-1", parseServeOptions(allocator, &.{ "--port", "-1", "/tmp/matcha" }));
}

test "parseServeOptions rejects invalid intervals" {
    const allocator = std.testing.allocator;
    try expectError(.invalid_interval, "0", parseServeOptions(allocator, &.{ "--interval", "0", "/tmp/matcha" }));
    try expectError(.invalid_interval, "abc", parseServeOptions(allocator, &.{ "--interval", "abc", "/tmp/matcha" }));
    try expectError(.invalid_interval, "", parseServeOptions(allocator, &.{ "--interval=", "/tmp/matcha" }));
    try expectError(.invalid_interval, "-5", parseServeOptions(allocator, &.{ "--interval", "-5", "/tmp/matcha" }));
}

test "parseServeOptions expands home marker in directory" {
    const allocator = std.testing.allocator;
    const result = parseServeOptions(allocator, &.{"~/plans"});
    const options = switch (result) {
        .ok => |options| options,
        .err => unreachable,
    };
    const home = path.expandHomePath(allocator, "~") catch unreachable;
    defer allocator.free(home);
    try std.testing.expectEqualStrings(home ++ "/plans", options.directory);
}

test "parsePort accepts valid ports" {
    try std.testing.expectEqual(@as(u16, 1), try parsePort("1"));
    try std.testing.expectEqual(@as(u16, 27004), try parsePort("27004"));
    try std.testing.expectEqual(@as(u16, 65535), try parsePort("65535"));
}

test "parsePort rejects invalid ports" {
    try std.testing.expectError(ParseError.InvalidPort, parsePort(""));
    try std.testing.expectError(ParseError.InvalidPort, parsePort("0"));
    try std.testing.expectError(ParseError.InvalidPort, parsePort("abc"));
    try std.testing.expectError(ParseError.InvalidPort, parsePort("12a"));
    try std.testing.expectError(ParseError.InvalidPort, parsePort("-1"));
}

test "parseInterval accepts valid intervals" {
    try std.testing.expectEqual(@as(u32, 1), try parseInterval("1"));
    try std.testing.expectEqual(@as(u32, 5), try parseInterval("5"));
    try std.testing.expectEqual(@as(u32, 3600), try parseInterval("3600"));
}

test "parseInterval rejects invalid intervals" {
    try std.testing.expectError(ParseError.InvalidInterval, parseInterval(""));
    try std.testing.expectError(ParseError.InvalidInterval, parseInterval("0"));
    try std.testing.expectError(ParseError.InvalidInterval, parseInterval("abc"));
    try std.testing.expectError(ParseError.InvalidInterval, parseInterval("12a"));
    try std.testing.expectError(ParseError.InvalidInterval, parseInterval("-5"));
}

test "validateDirectory accepts real directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expect(validateDirectory(std.testing.io, tmp.dir.path.?));
}

test "validateDirectory rejects missing path" {
    try std.testing.expect(!validateDirectory(std.testing.io, "/tmp/matcha-nonexistent-12345"));
}

test "validateDirectory rejects file path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/file.txt", .{tmp.dir.path.?});
    defer std.testing.allocator.free(file_path);
    try tmp.dir.writeFile("file.txt", "data");
    try std.testing.expect(!validateDirectory(std.testing.io, file_path));
}

fn expectError(
    expected_tag: std.meta.Tag(errors.CliError),
    expected_value: []const u8,
    result: ServeOptionsResult,
) !void {
    switch (result) {
        .ok => return error.ExpectedError,
        .err => |cli_error| {
            try std.testing.expectEqual(expected_tag, std.meta.activeTag(cli_error));
            const actual = switch (cli_error) {
                .missing_value => |v| v,
                .unknown_option => |v| v,
                .extra_arguments => |v| v,
                .invalid_port => |v| v,
                .invalid_interval => |v| v,
                else => return error.WrongError,
            };
            try std.testing.expectEqualStrings(expected_value, actual);
        },
    }
}
