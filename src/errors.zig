const std = @import("std");

pub const CliError = union(enum) {
    missing_value: []const u8,
    unknown_option: []const u8,
    missing_home: []const u8,
    path_error: []const u8,
    cannot_read_input: []const u8,
    invalid_json: []const u8,
    extra_arguments: []const u8,
    invalid_port: []const u8,
    invalid_interval: []const u8,
    not_a_directory: []const u8,
    missing_backend,
    unknown_backend: []const u8,
    missing_prompt,
    invalid_number: []const u8,
    invalid_duration: []const u8,
    invalid_loop_arguments: []const u8,
};

pub fn writeCliError(writer: *std.Io.Writer, cli_error: CliError) std.Io.Writer.Error!void {
    switch (cli_error) {
        .missing_value => |flag| try writer.print("Missing value for {s}\n", .{flag}),
        .unknown_option => |option| try writer.print("Unknown option: {s}\n", .{option}),
        .missing_home => |value| try writer.print("Cannot expand {s}: HOME and USERPROFILE are not set\n", .{value}),
        .path_error => |value| try writer.print("Cannot process path: {s}\n", .{value}),
        .cannot_read_input => |value| try writer.print("Cannot read {s}\n", .{value}),
        .invalid_json => |value| try writer.print("Invalid JSON in {s}\n", .{value}),
        .extra_arguments => |value| try writer.print("Unexpected argument: {s}\n", .{value}),
        .invalid_port => |value| try writer.print("Invalid port: {s}\n", .{value}),
        .invalid_interval => |value| try writer.print("Invalid interval: {s}\n", .{value}),
        .not_a_directory => |value| try writer.print("Not a directory: {s}\n", .{value}),
        .missing_backend => try writer.writeAll("A backend is required; use -b <codex|droid|agy>\n"),
        .unknown_backend => |value| try writer.print("Unknown backend: {s}\n", .{value}),
        .missing_prompt => try writer.writeAll("A prompt is required (provide an argument or pipe stdin)\n"),
        .invalid_number => |value| try writer.print("Invalid number: {s}\n", .{value}),
        .invalid_duration => |value| try writer.print("Invalid duration: {s}\n", .{value}),
        .invalid_loop_arguments => |value| try writer.print("Invalid loop arguments: {s}\n", .{value}),
    }
}
