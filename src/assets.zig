const std = @import("std");

pub const TextAsset = struct {
    name: []const u8,
    contents: []const u8,
};

pub const ThemeAsset = struct {
    name: []const u8,
    path: []const u8,
    css: []const u8,
};

pub const plan_js: TextAsset = .{
    .name = "plan.js",
    .contents = @embedFile("../assets/client/plan.js"),
};

pub const plan_css: TextAsset = .{
    .name = "plan.css",
    .contents = @embedFile("../assets/plan.css"),
};

pub const plan_components_css: TextAsset = .{
    .name = "plan-components.css",
    .contents = @embedFile("../assets/client/plan-components.css"),
};

pub const map_js: TextAsset = .{
    .name = "map.js",
    .contents = @embedFile("../assets/client/map.js"),
};

pub const map_css: TextAsset = .{
    .name = "map.css",
    .contents = @embedFile("../assets/client/map.css"),
};

pub const serve_js: TextAsset = .{
    .name = "serve.js",
    .contents = @embedFile("../assets/client/serve.js"),
};

pub const serve_css: TextAsset = .{
    .name = "serve.css",
    .contents = @embedFile("../assets/client/serve.css"),
};

pub const llm_output_format: TextAsset = .{
    .name = "llm_output_format.txt",
    .contents = @embedFile("../schemas/llm_output_format.txt"),
};

pub const llm_uml_output_format: TextAsset = .{
    .name = "llm_uml_output_format.txt",
    .contents = @embedFile("../schemas/llm_uml_output_format.txt"),
};

pub const loop_initial: TextAsset = .{
    .name = "loop_initial.md",
    .contents = @embedFile("../prompts/loop_initial.md"),
};

pub const loop_continuation: TextAsset = .{
    .name = "loop_continuation.md",
    .contents = @embedFile("../prompts/loop_continuation.md"),
};

pub const loop_verifier: TextAsset = .{
    .name = "loop_verifier.md",
    .contents = @embedFile("../prompts/loop_verifier.md"),
};

pub const loop_objective_updated: TextAsset = .{
    .name = "loop_objective_updated.md",
    .contents = @embedFile("../prompts/loop_objective_updated.md"),
};

pub const loop_budget_limit: TextAsset = .{
    .name = "loop_budget_limit.md",
    .contents = @embedFile("../prompts/loop_budget_limit.md"),
};

pub const required_assets = [_]TextAsset{
    plan_js,
    plan_css,
    plan_components_css,
    map_js,
    map_css,
    serve_js,
    serve_css,
    llm_output_format,
    llm_uml_output_format,
    loop_initial,
    loop_continuation,
    loop_verifier,
    loop_objective_updated,
    loop_budget_limit,
};

pub const themes = [_]ThemeAsset{
    theme("catppuccin-latte"),
    theme("catppuccin"),
    theme("dracula"),
    theme("gruvbox"),
    theme("gruvbox-light"),
    theme("kanagawa"),
    theme("kanagawa-lotus"),
    theme("nord"),
    theme("one-dark"),
    theme("one-light"),
    theme("rose-pine"),
    theme("rose-pine-dawn"),
    theme("solarized"),
    theme("solarized-light"),
    theme("terminal"),
    theme("tokyo-night"),
    theme("tokyo-night-day"),
    theme("vesper"),
};

pub fn assetByName(name: []const u8) ?TextAsset {
    for (required_assets) |asset| {
        if (std.mem.eql(u8, asset.name, name)) {
            return asset;
        }
    }

    return null;
}

pub fn themeByName(name: []const u8) ?ThemeAsset {
    for (themes) |theme_asset| {
        if (std.mem.eql(u8, theme_asset.name, name)) {
            return theme_asset;
        }
    }

    return null;
}

pub fn optionalMapCss() ?*const TextAsset {
    if (map_css.contents.len == 0) {
        return null;
    }

    return &map_css;
}

pub fn optionalMapJs() ?*const TextAsset {
    if (map_js.contents.len == 0) {
        return null;
    }

    return &map_js;
}

pub fn optionalServeJs() ?*const TextAsset {
    if (serve_js.contents.len == 0) {
        return null;
    }

    return &serve_js;
}

pub fn optionalServeCss() ?*const TextAsset {
    if (serve_css.contents.len == 0) {
        return null;
    }

    return &serve_css;
}

pub fn writeThemeCss(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (themes) |theme_asset| {
        try writer.writeAll(theme_asset.css);
        try writer.writeByte('\n');
    }
}

pub fn themeCssByteLength() usize {
    var total: usize = 0;

    for (themes) |theme_asset| {
        total += theme_asset.css.len + 1;
    }

    return total;
}

fn theme(comptime name: []const u8) ThemeAsset {
    return .{
        .name = name,
        .path = "themes/" ++ name ++ ".css",
        .css = @embedFile("../themes/" ++ name ++ ".css"),
    };
}

test "required embedded assets are non-empty" {
    for (required_assets) |asset| {
        try std.testing.expect(asset.name.len > 0);
        try std.testing.expect(asset.contents.len > 0);
    }
}

test "theme assets are non-empty and in CLI order" {
    const expected = [_][]const u8{
        "catppuccin-latte",
        "catppuccin",
        "dracula",
        "gruvbox",
        "gruvbox-light",
        "kanagawa",
        "kanagawa-lotus",
        "nord",
        "one-dark",
        "one-light",
        "rose-pine",
        "rose-pine-dawn",
        "solarized",
        "solarized-light",
        "terminal",
        "tokyo-night",
        "tokyo-night-day",
        "vesper",
    };

    try std.testing.expectEqual(expected.len, themes.len);
    for (expected, themes) |expected_name, theme_asset| {
        try std.testing.expectEqualStrings(expected_name, theme_asset.name);
        try std.testing.expect(theme_asset.css.len > 0);
    }
}

test "format documents are available without file IO" {
    try std.testing.expect(std.mem.indexOf(u8, llm_output_format.contents, "schemaVersion") != null);
    try std.testing.expect(std.mem.indexOf(u8, llm_output_format.contents, "Output exactly one JSON object") != null);
    try std.testing.expect(std.mem.indexOf(u8, llm_output_format.contents, "\"heroTitle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, llm_output_format.contents, "\"firstStorySummary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, llm_output_format.contents, "\"shortTitle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, llm_output_format.contents, "\"workflows\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, llm_output_format.contents, "\"commandsToRun\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, llm_output_format.contents, "\"blockers\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, llm_uml_output_format.contents, "diagramKind") != null);
    try std.testing.expect(std.mem.indexOf(u8, llm_uml_output_format.contents, "Output exactly one JSON object") != null);
}

test "embedded serve assets are non-empty and lookup-able" {
    try std.testing.expect(serve_js.contents.len > 0);
    try std.testing.expect(serve_css.contents.len > 0);
    try std.testing.expectEqualStrings("serve.js", serve_js.name);
    try std.testing.expectEqualStrings("serve.css", serve_css.name);

    const looked_up_js = assetByName("serve.js").?;
    try std.testing.expectEqualStrings(serve_js.contents, looked_up_js.contents);
    const looked_up_css = assetByName("serve.css").?;
    try std.testing.expectEqualStrings(serve_css.contents, looked_up_css.contents);

    try std.testing.expect(optionalServeJs() != null);
    try std.testing.expect(optionalServeCss() != null);
}

test "embedded loop prompts are non-empty, registered, and contain required guardrails" {
    const prompts = [_]TextAsset{
        loop_initial,
        loop_continuation,
        loop_verifier,
        loop_objective_updated,
        loop_budget_limit,
    };
    for (prompts) |prompt| {
        try std.testing.expect(prompt.contents.len > 0);
        const registered = assetByName(prompt.name).?;
        try std.testing.expectEqualStrings(prompt.contents, registered.contents);
    }
    try std.testing.expect(std.mem.indexOf(u8, loop_initial.contents, "<loop_objective>") != null);
    try std.testing.expect(std.mem.indexOf(u8, loop_continuation.contents, "<loop_objective>") != null);
    try std.testing.expect(std.mem.indexOf(u8, loop_continuation.contents, "{{ budget_section }}") != null);
    try std.testing.expect(std.mem.indexOf(u8, loop_continuation.contents, "{{ verifier_section }}") != null);
    try std.testing.expect(std.mem.indexOf(u8, loop_continuation.contents, "<verifier_rejection>") != null);
    try std.testing.expect(std.mem.indexOf(u8, loop_continuation.contents, "{{ blocked_strikes }}/50") != null);
    try std.testing.expect(std.mem.indexOf(u8, loop_initial.contents, "matcha loop update") != null);
    try std.testing.expect(std.mem.indexOf(u8, loop_continuation.contents, "matcha loop update") != null);
    try std.testing.expect(std.mem.indexOf(u8, loop_verifier.contents, "matcha loop verify --pass") != null);
    try std.testing.expect(std.mem.indexOf(u8, loop_verifier.contents, "matcha loop verify --fail --reason") != null);
    try std.testing.expect(std.mem.indexOf(u8, loop_verifier.contents, "Do not modify tracked project files") != null);
}

test "theme css can be streamed in manifest order" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try writeThemeCss(&output.writer);
    try std.testing.expect(output.written().len > 0);
    try std.testing.expectEqual(themeCssByteLength(), output.written().len);
}
