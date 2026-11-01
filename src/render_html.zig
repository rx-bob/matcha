const std = @import("std");

const assets = @import("assets.zig");

pub const RenderTarget = enum {
    plan,
    map,
};

pub fn defaultInput(target: RenderTarget) []const u8 {
    return switch (target) {
        .plan => "sample_plan.json",
        .map => "sample_map.json",
    };
}

pub fn defaultOutput(target: RenderTarget) []const u8 {
    return switch (target) {
        .plan => "dist/plan.html",
        .map => "dist/map.html",
    };
}

fn faviconDataUrl(comptime png: []const u8) []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var encoded: [std.base64.standard.Encoder.calcSize(png.len)]u8 = undefined;
        break :blk "data:image/png;base64," ++ std.base64.standard.Encoder.encode(&encoded, png);
    };
}

const coral_favicon_url = faviconDataUrl(@embedFile("../assets/favicon-coral.png"));
const chonk_favicon_url = faviconDataUrl(@embedFile("../assets/favicon-chonk.png"));
const eva_favicon_url = faviconDataUrl(@embedFile("../assets/favicon-eva-01.png"));

const plan_boot_script =
    \\<script>
    \\  (function() {
    \\    try {
    \\      var root = document.documentElement;
    \\      var savedDesign = root.dataset.initialDesign || localStorage.getItem('matcha-plan-design');
    \\      var designs = ['coral', 'chonk', 'eva-01'];
    \\      var design = (savedDesign && designs.indexOf(savedDesign) !== -1) ? savedDesign : 'coral';
    \\      root.dataset.design = design;
    \\      var savedTheme = localStorage.getItem(root.dataset.evaThemeStorageKey || 'matcha-eva-theme');
    \\      if (savedTheme !== 'light' && savedTheme !== 'dark') savedTheme = root.dataset.initialEvaTheme;
    \\      var theme = design === 'coral' ? 'light' : design === 'chonk' ? 'dark' : (savedTheme === 'light' || savedTheme === 'dark' ? savedTheme : 'dark');
    \\      root.dataset.theme = theme;
    \\      var fav = document.getElementById('dynamic-favicon');
    \\      if (fav) {
    \\        fav.href = fav.getAttribute('data-favicon-' + design);
    \\      }
    \\    } catch (e) {}
    \\  })();
    \\</script>
;

pub fn writePlanHtml(io: std.Io, output_path: []const u8, title: []const u8, payload: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{ .truncate = true });
    defer file.close(io);

    try file.writeStreamingAll(io, "<!DOCTYPE html>\n");
    try file.writeStreamingAll(io, "<html lang=\"en\" data-design=\"coral\" data-theme=\"light\">\n");
    try file.writeStreamingAll(io, "<head>\n");
    try file.writeStreamingAll(io, "  <title>");
    try file.writeStreamingAll(io, title);
    try file.writeStreamingAll(io, "</title>\n");
    try file.writeStreamingAll(io, "  <meta charset=\"UTF-8\">\n");
    try file.writeStreamingAll(io, "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n");
    // Critical for serve_catalog.zig prefix classification:
    // Emit plan-data before the embedded favicon images and plan.css stylesheet
    // so id="plan-data" always falls well within classify_prefix_bytes (64 KB).
    try file.writeStreamingAll(io, "  <script type=\"application/json\" id=\"plan-data\">\n");
    try writeEmbeddedJson(io, file, payload);
    try file.writeStreamingAll(io, "\n  </script>\n");
    try file.writeStreamingAll(io, "  <script>\n");
    try file.writeStreamingAll(io, "    window.PLAN_DATA = JSON.parse(document.getElementById(\"plan-data\").textContent);\n");
    try file.writeStreamingAll(io, "  </script>\n");

    try file.writeStreamingAll(io, "  <link rel=\"icon\" id=\"dynamic-favicon\" type=\"image/png\" href=\"");
    try file.writeStreamingAll(io, coral_favicon_url);
    try file.writeStreamingAll(io, "\" data-favicon-coral=\"");
    try file.writeStreamingAll(io, coral_favicon_url);
    try file.writeStreamingAll(io, "\" data-favicon-chonk=\"");
    try file.writeStreamingAll(io, chonk_favicon_url);
    try file.writeStreamingAll(io, "\" data-favicon-eva-01=\"");
    try file.writeStreamingAll(io, eva_favicon_url);
    try file.writeStreamingAll(io, "\">\n");
    try file.writeStreamingAll(io, "  ");
    try file.writeStreamingAll(io, plan_boot_script);
    try file.writeStreamingAll(io, "\n");

    try file.writeStreamingAll(io, "  <style>");
    try writeStyle(io, file, &assets.plan_css);
    try file.writeStreamingAll(io, "</style>\n");
    if (assets.plan_components_css.contents.len > 0) {
        try file.writeStreamingAll(io, "  <style>");
        try writeStyle(io, file, &assets.plan_components_css);
        try file.writeStreamingAll(io, "</style>\n");
    }
    try file.writeStreamingAll(io, "</head>\n");

    try file.writeStreamingAll(io, "<body>\n");
    try file.writeStreamingAll(io, "  <div id=\"plan-root\"></div>\n");
    try file.writeStreamingAll(io, "  <script>\n");
    try file.writeStreamingAll(io, assets.plan_js.contents);
    try file.writeStreamingAll(io, "\n  </script>\n");
    try file.writeStreamingAll(io, "</body>\n");
    try file.writeStreamingAll(io, "</html>\n");
}

pub fn writeMapHtml(io: std.Io, output_path: []const u8, title: []const u8, payload: []const u8) !void {
    try writeMapHtmlWithAssets(
        io,
        output_path,
        title,
        payload,
        assets.optionalMapCss(),
        assets.optionalMapJs(),
    );
}

fn writeMapHtmlWithAssets(
    io: std.Io,
    output_path: []const u8,
    title: []const u8,
    payload: []const u8,
    map_css: ?*const assets.TextAsset,
    map_js: ?*const assets.TextAsset,
) !void {
    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{ .truncate = true });
    defer file.close(io);

    try file.writeStreamingAll(io, "<!DOCTYPE html>\n");
    try file.writeStreamingAll(io, "<html lang=\"en\" data-theme=\"catppuccin-latte\">\n");
    try file.writeStreamingAll(io, "<head>\n");
    try file.writeStreamingAll(io, "  <title>");
    try file.writeStreamingAll(io, title);
    try file.writeStreamingAll(io, "</title>\n");
    try file.writeStreamingAll(io, "  <meta charset=\"UTF-8\">\n");
    try file.writeStreamingAll(io, "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n");
    try writeThemeBootScript(io, file, "matcha-map-theme");
    try file.writeStreamingAll(io, "\n  <style>");
    for (assets.themes) |theme_asset| {
        try file.writeStreamingAll(io, theme_asset.css);
        try file.writeStreamingAll(io, "\n");
    }
    try file.writeStreamingAll(io, "</style>\n");
    if (map_css) |css| {
        if (css.contents.len > 0) {
            try file.writeStreamingAll(io, "  <style>");
            try writeStyle(io, file, css);
            try file.writeStreamingAll(io, "</style>\n");
        }
    }
    try file.writeStreamingAll(io, "</head>\n");

    try file.writeStreamingAll(io, "<body>\n");
    try file.writeStreamingAll(io, "  <div id=\"map-root\"></div>\n");
    try file.writeStreamingAll(io, "  <script type=\"application/json\" id=\"map-data\">\n");
    try writeEmbeddedJson(io, file, payload);
    try file.writeStreamingAll(io, "\n  </script>\n");
    try file.writeStreamingAll(io, "  <script>\n");
    try file.writeStreamingAll(io, "    window.MAP_DATA = JSON.parse(document.getElementById(\"map-data\").textContent);\n");
    try file.writeStreamingAll(io, "    ;\n");
    if (map_js) |js| {
        if (js.contents.len > 0) {
            try file.writeStreamingAll(io, js.contents);
        }
    }
    try file.writeStreamingAll(io, "\n  </script>\n");
    try file.writeStreamingAll(io, "</body>\n");
    try file.writeStreamingAll(io, "</html>\n");
}

fn writeEmbeddedJson(io: std.Io, file: std.Io.File, payload: []const u8) !void {
    for (payload, 0..) |byte, index| {
        if (byte == '<') {
            try file.writeStreamingAll(io, "\\u003c");
        } else {
            try file.writeStreamingAll(io, payload[index .. index + 1]);
        }
    }
}

fn writeStyle(io: std.Io, file: std.Io.File, text_asset: *const assets.TextAsset) !void {
    try file.writeStreamingAll(io, text_asset.contents);
}

fn writeThemeBootScript(io: std.Io, file: std.Io.File, storage_key: []const u8) !void {
    try file.writeStreamingAll(io, "<script>\n");
    try file.writeStreamingAll(io, "  (function () {\n");
    try file.writeStreamingAll(io, "    var themes = new Set([");
    for (assets.themes, 0..) |theme_asset, index| {
        if (index > 0) {
            try file.writeStreamingAll(io, ",");
        }
        try file.writeStreamingAll(io, "\"");
        try file.writeStreamingAll(io, theme_asset.name);
        try file.writeStreamingAll(io, "\"");
    }
    try file.writeStreamingAll(io, "]);\n");
    try file.writeStreamingAll(io, "    try {\n");
    try file.writeStreamingAll(io, "      var saved = localStorage.getItem(\"");
    try file.writeStreamingAll(io, storage_key);
    try file.writeStreamingAll(io, "\");\n");
    try file.writeStreamingAll(io, "      if (themes.has(saved)) {\n");
    try file.writeStreamingAll(io, "        document.documentElement.setAttribute(\"data-theme\", saved);\n");
    try file.writeStreamingAll(io, "      }\n");
    try file.writeStreamingAll(io, "    } catch {}\n");
    try file.writeStreamingAll(io, "  })();\n");
    try file.writeStreamingAll(io, "</script>");
}

test "html renderer defaults match current CLI" {
    try std.testing.expectEqualStrings("sample_plan.json", defaultInput(.plan));
    try std.testing.expectEqualStrings("dist/map.html", defaultOutput(.map));
}

test "plan HTML render emits required markers and title" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/plan.html", .{tmp.sub_path});
    defer allocator.free(output_path);

    try writePlanHtml(
        std.testing.io,
        output_path,
        "Plan Fixture",
        "{\"title\":\"Plan Fixture\",\"extra_field\":\"kept\"}",
    );

    var file = try tmp.dir.openFile(std.testing.io, "plan.html", .{});
    defer file.close(std.testing.io);

    const html = try file.readToEndAlloc(std.testing.io, allocator, 2 * 1024 * 1024);
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "<title>Plan Fixture</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<html lang=\"en\" data-design=\"coral\" data-theme=\"light\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<div id=\"plan-root\"></div>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"plan-data\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "window.PLAN_DATA") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"dynamic-favicon\"") != null);
    inline for (.{ "coral", "chonk", "eva-01" }) |design| {
        try std.testing.expect(std.mem.indexOf(u8, html, "data-favicon-" ++ design ++ "=\"data:image/png;base64,") != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, html, "matcha-plan-design") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "matcha-eva-theme") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "\"extra_field\":\"kept\"") != null);

    // Plan HTML must not inline flat theme stylesheets or legacy plan theme key
    try std.testing.expect(std.mem.indexOf(u8, html, "matcha-plan-theme") == null);
    for (assets.themes) |theme| {
        try std.testing.expect(std.mem.indexOf(u8, html, theme.name) == null);
    }

    // id="plan-data" must be placed before <style> and reside within the first 4 KB
    const plan_data_pos = std.mem.indexOf(u8, html, "id=\"plan-data\"").?;
    try std.testing.expect(plan_data_pos < 4096);
    const style_pos = std.mem.indexOf(u8, html, "<style>").?;
    try std.testing.expect(plan_data_pos < style_pos);
}

test "plan HTML renderer escapes script-like JSON" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/plan.html", .{tmp.sub_path});
    defer allocator.free(output_path);

    try writePlanHtml(
        std.testing.io,
        output_path,
        "</script><script>alert(1)</script>",
        "{\"title\":\"</script><script>alert(1)</script>\"}",
    );

    var file = try tmp.dir.openFile(std.testing.io, "plan.html", .{});
    defer file.close(std.testing.io);

    const html = try file.readToEndAlloc(std.testing.io, allocator, 2 * 1024 * 1024);
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "\\u003c/script\\u003e\\u003cscript\\u003ealert(1)\\u003c/script\\u003e") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<script>alert(1)</script>") == null);
}

test "map HTML render emits required markers and title" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/map.html", .{tmp.sub_path});
    defer allocator.free(output_path);

    try writeMapHtml(
        std.testing.io,
        output_path,
        "Map Fixture",
        "{\"title\":\"Map Fixture\",\"kind\":\"class\",\"elements\":[]}",
    );

    var file = try tmp.dir.openFile(std.testing.io, "map.html", .{});
    defer file.close(std.testing.io);

    const html = try file.readToEndAlloc(std.testing.io, allocator, 1024 * 1024);
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "<title>Map Fixture</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<div id=\"map-root\"></div>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"map-data\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "window.MAP_DATA") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "matcha-map-theme") != null);
    // Maps continue to inline assets.themes
    try std.testing.expect(std.mem.indexOf(u8, html, assets.themes[0].name) != null);
}

test "map HTML renderer escapes script-like JSON" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/map.html", .{tmp.sub_path});
    defer allocator.free(output_path);

    try writeMapHtml(
        std.testing.io,
        output_path,
        "Scripty Map",
        "{\"title\":\"</script><script>alert(1)</script>\",\"kind\":\"class\"}",
    );

    var file = try tmp.dir.openFile(std.testing.io, "map.html", .{});
    defer file.close(std.testing.io);

    const html = try file.readToEndAlloc(std.testing.io, allocator, 1024 * 1024);
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "\\u003c/script\\u003e\\u003cscript\\u003ealert(1)\\u003c/script\\u003e") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<script>alert(1)</script>") == null);
}

test "map renderer supports optional map assets" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/map.html", .{tmp.sub_path});
    defer allocator.free(output_path);

    const css_fixture = assets.TextAsset{
        .name = "map-fixture.css",
        .contents = ".fixture-map-style { color: red; }",
    };
    const js_fixture = assets.TextAsset{
        .name = "map-fixture.js",
        .contents = "window.__MATCHA_MAP_FIXTURE__ = true;",
    };

    try writeMapHtmlWithAssets(
        std.testing.io,
        output_path,
        "Optional Asset Map",
        "{\"title\":\"Optional Asset Map\",\"kind\":\"class\"}",
        &css_fixture,
        &js_fixture,
    );

    var file = try tmp.dir.openFile(std.testing.io, "map.html", .{});
    defer file.close(std.testing.io);

    const with_fixture = try file.readToEndAlloc(std.testing.io, allocator, 1024 * 1024);
    defer allocator.free(with_fixture);

    try std.testing.expect(std.mem.indexOf(u8, with_fixture, "window.__MATCHA_MAP_FIXTURE__ = true;") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_fixture, ".fixture-map-style { color: red; }") != null);

    try writeMapHtmlWithAssets(
        std.testing.io,
        output_path,
        "Optional Asset Map",
        "{\"title\":\"Optional Asset Map\",\"kind\":\"class\"}",
        null,
        null,
    );

    file = try tmp.dir.openFile(std.testing.io, "map.html", .{});
    const without_fixture = try file.readToEndAlloc(std.testing.io, allocator, 1024 * 1024);
    defer allocator.free(without_fixture);

    try std.testing.expect(std.mem.indexOf(u8, without_fixture, ".fixture-map-style { color: red; }") == null);
    try std.testing.expect(std.mem.indexOf(u8, without_fixture, "window.__MATCHA_MAP_FIXTURE__ = true;") == null);
    try std.testing.expect(std.mem.indexOf(u8, without_fixture, ".map-viewport.svelte-o9f9lq") == null);
    try std.testing.expect(std.mem.indexOf(u8, without_fixture, "window.__svelte") == null);
}
