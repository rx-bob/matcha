pub const assets = @import("assets.zig");
pub const cli = @import("cli.zig");
pub const errors = @import("errors.zig");
pub const path = @import("path.zig");
pub const json_input = @import("json_input.zig");
pub const plan_read = @import("plan_read.zig");
pub const render_html = @import("render_html.zig");
pub const render_toon = @import("render_toon.zig");
pub const serve_options = @import("serve_options.zig");
pub const serve_catalog = @import("serve_catalog.zig");
pub const serve_routes = @import("serve_routes.zig");
pub const serve = @import("serve.zig");
pub const serve_test = @import("serve_test.zig");
pub const loop = @import("loop.zig");
pub const loop_backend = @import("loop_backend.zig");
pub const loop_options = @import("loop_options.zig");
pub const loop_prompts = @import("loop_prompts.zig");
pub const loop_config = @import("loop_config.zig");
pub const loop_summary = @import("loop_summary.zig");
pub const loop_store = @import("loop_store.zig");
pub const loop_stream = @import("loop_stream.zig");

pub const version = cli.version;

test "root cli module exposes placeholder version" {
    const std = @import("std");

    try std.testing.expect(version.len > 0);
}

test "root imports CLI modules without dependency cycles" {
    const std = @import("std");

    std.testing.refAllDecls(render_html);
    try std.testing.expectEqualStrings("map.css", assets.map_css.name);
    try std.testing.expect(path.hasParentDirectory("dist/map.html"));
    try std.testing.expectEqualStrings("examples/sample_map.json", render_html.defaultInput(.map));
    try std.testing.expectEqual(@as(usize, 256), render_toon.MAX_DEPTH);
    try std.testing.expectEqual(@as(u16, 27004), serve_options.default_port);
}
