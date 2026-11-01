const root = @import("src/root.zig");
const std = @import("std");

pub const assets = root.assets;
pub const cli = root.cli;
pub const errors = root.errors;
pub const path = root.path;
pub const json_input = root.json_input;
pub const plan_read = root.plan_read;
pub const render_html = root.render_html;
pub const render_toon = root.render_toon;
pub const serve_options = root.serve_options;
pub const serve_catalog = root.serve_catalog;
pub const serve_routes = root.serve_routes;
pub const serve = root.serve;
pub const loop = root.loop;
pub const loop_backend = root.loop_backend;
pub const loop_options = root.loop_options;
pub const loop_prompts = root.loop_prompts;
pub const loop_config = root.loop_config;
pub const loop_summary = root.loop_summary;
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
