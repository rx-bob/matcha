const root = @import("src/root.zig");
const std = @import("std");

pub const assets = root.assets;
pub const cli = root.cli;
pub const errors = root.errors;
pub const path = root.path;
pub const render_html = root.render_html;
pub const render_markdown = root.render_markdown;
pub const serve_options = root.serve_options;
pub const serve_catalog = root.serve_catalog;
pub const serve = root.serve;
pub const loop = root.loop;
pub const loop_backend = root.loop_backend;
pub const loop_options = root.loop_options;
pub const loop_prompts = root.loop_prompts;
pub const loop_store = root.loop_store;
pub const loop_stream = root.loop_stream;
pub const version = root.version;

test "loop runtime declarations are included" {
    std.testing.refAllDecls(@import("src/loop.zig"));
}

test "CLI loop declarations are included when enabled" {
    if (@import("cli_test_gate").enabled) {
        std.testing.refAllDecls(@import("src/cli.zig"));
    }
}
