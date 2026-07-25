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
    .contents = @embedFile("../plan.js"),
};

pub const plan_css: TextAsset = .{
    .name = "plan.css",
    .contents = @embedFile("../plan.css"),
};

pub const plan_components_css: TextAsset = .{
    .name = "plan-components.css",
    .contents = @embedFile("../plan-components.css"),
};

pub const map_js: TextAsset = .{
    .name = "map.js",
    .contents = @embedFile("../map.js"),
};

pub const map_css: TextAsset = .{
    .name = "map.css",
    .contents = @embedFile("../map.css"),
};

pub const serve_js: TextAsset = .{
    .name = "serve.js",
    .contents = @embedFile("../serve.js"),
};

pub const serve_css: TextAsset = .{
    .name = "serve.css",
    .contents = @embedFile("../serve.css"),
};

pub const llm_output_format: TextAsset = .{
    .name = "llm_output_format.txt",
    .contents = @embedFile("../llm_output_format.txt"),
};

pub const llm_uml_output_format: TextAsset = .{
    .name = "llm_uml_output_format.txt",
    .contents = @embedFile("../llm_uml_output_format.txt"),
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
    try std.testing.expect(std.mem.indexOf(u8, llm_output_format.contents, "Plan input format") != null);
    try std.testing.expect(std.mem.indexOf(u8, llm_uml_output_format.contents, "Map input format") != null);
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

test "theme css can be streamed in manifest order" {
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeThemeCss(&writer);
    try std.testing.expect(writer.end > 0);
    try std.testing.expectEqual(themeCssByteLength(), writer.end);
}
