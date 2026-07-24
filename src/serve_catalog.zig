const std = @import("std");

/// Maximum number of bytes read from an artifact while classifying it. The
/// plan/map markers emitted by the renderers appear near the top of the file,
/// so a bounded prefix is enough and avoids loading whole files into memory.
pub const classify_prefix_bytes: usize = 4096;

/// The embedded-data script markers emitted by the Matcha HTML renderers.
/// The renderers emit `<script type="application/json" id="plan-data">` (and
/// the matching `map-data` form), so matching the attribute pair avoids false
/// positives from marker-like text outside the embedded-data script element.
pub const plan_marker: []const u8 = "type=\"application/json\" id=\"plan-data\"";
pub const map_marker: []const u8 = "type=\"application/json\" id=\"map-data\"";

pub const ArtifactKind = enum {
    plan,
    map,
};

/// Metadata for a discovered Matcha artifact. The catalog never retains the
/// artifact body, only normalized path, kind, size, and modification time.
pub const CatalogEntry = struct {
    /// Normalized relative path from the serving root using forward slashes.
    rel_path: []const u8,
    kind: ArtifactKind,
    size: u64,
    mtime: std.Io.Timestamp,
};

pub const ScanError = error{
    OutOfMemory,
    AccessDenied,
    SystemBusy,
    Unexpected,
};

/// Recursively scan `root` for Matcha-generated plan and map HTML artifacts.
///
/// Only regular `.html` files (case-insensitive extension) are considered.
/// Classification is based on the embedded `script` element markers, not the
/// filename. Hidden directories, symlinks (both file and directory), and
/// non-regular files are skipped so traversal cannot escape the configured
/// root through `..`, absolute paths, or symlinks. The returned entries hold
/// normalized relative paths and file metadata only; artifact bodies are not
/// retained.
pub fn scan(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
) ScanError![]CatalogEntry {
    var root_dir = std.Io.Dir.openDirAbsolute(io, root, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.AccessDenied => return error.AccessDenied,
        error.SystemResources, error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unexpected,
    };
    defer root_dir.close(io);

    var walker = std.Io.Dir.walkSelectively(root_dir, allocator) catch return error.OutOfMemory;
    defer walker.deinit();

    var entries: std.ArrayList(CatalogEntry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.rel_path);
        entries.deinit(allocator);
    }

    while (true) {
        const walker_entry = walker.next(io) catch |err| switch (err) {
            error.AccessDenied => continue,
            error.SystemResources => return error.SystemBusy,
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        } orelse break;

        // Skip hidden and administrative entries.
        if (isHidden(walker_entry.basename)) continue;

        // Skip symlinks of any kind so traversal cannot escape the root.
        if (walker_entry.kind == .sym_link) continue;

        if (walker_entry.kind == .directory) {
            walker.enter(io, walker_entry) catch continue;
            continue;
        }

        if (walker_entry.kind != .file) continue;

        if (!std.ascii.endsWithIgnoreCase(walker_entry.basename, ".html")) continue;

        const stat = walker_entry.dir.statFile(io, walker_entry.basename, .{
            .follow_symlinks = false,
        }) catch continue;

        // Only regular files qualify; a symlink reported as a file is skipped
        // defensively here even though iteration already filtered sym_link.
        if (stat.kind != .file) continue;

        var prefix_buffer: [classify_prefix_bytes]u8 = undefined;
        const prefix = walker_entry.dir.readFile(io, walker_entry.basename, &prefix_buffer) catch continue;
        const kind = classify(prefix) orelse continue;

        const rel_path = allocator.dupe(u8, walker_entry.path) catch return error.OutOfMemory;

        entries.append(allocator, .{
            .rel_path = rel_path,
            .kind = kind,
            .size = stat.size,
            .mtime = stat.mtime,
        }) catch {
            allocator.free(rel_path);
            return error.OutOfMemory;
        };
    }

    return entries.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// Classify an HTML prefix by its embedded plan/map data marker. Returns null
/// for unrelated HTML, non-HTML, or false marker-like text that is not inside
/// the expected embedded-data script element.
pub fn classify(prefix: []const u8) ?ArtifactKind {
    const plan_index = std.mem.indexOf(u8, prefix, plan_marker) orelse std.math.maxInt(usize);
    const map_index = std.mem.indexOf(u8, prefix, map_marker) orelse std.math.maxInt(usize);
    if (plan_index == std.math.maxInt(usize) and map_index == std.math.maxInt(usize)) return null;
    if (plan_index <= map_index) return .plan;
    return .map;
}

fn isHidden(name: []const u8) bool {
    return name.len > 0 and name[0] == '.';
}

/// Free a slice of catalog entries returned by `scan`, including each entry's
/// owned relative path.
pub fn freeEntries(allocator: std.mem.Allocator, entries: []CatalogEntry) void {
    for (entries) |entry| allocator.free(entry.rel_path);
    allocator.free(entries);
}

test "classify detects plan marker" {
    try std.testing.expectEqual(ArtifactKind.plan, classify(
        \\<html><script type="application/json" id="plan-data">{"title":"x"}</script></html>
    ).?);
}

test "classify detects map marker" {
    try std.testing.expectEqual(ArtifactKind.map, classify(
        \\<html><script type="application/json" id="map-data">{"title":"x"}</script></html>
    ).?);
}

test "classify prefers the first marker when both appear" {
    const html =
        \\<html><script type="application/json" id="plan-data"></script><script type="application/json" id="map-data"></script></html>
    ;
    try std.testing.expectEqual(ArtifactKind.plan, classify(html).?);
}

test "classify rejects unrelated html" {
    try std.testing.expect(classify("<html><body>nothing here</body></html>") == null);
}

test "classify rejects empty input" {
    try std.testing.expect(classify("") == null);
}

test "classify rejects false marker-like text outside the script element" {
    try std.testing.expect(classify("<p>id=\"plan-data\" but not in a script</p>") == null);
}

test "scan classifies nested plan and map html regardless of filename" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("project-a/sub");
    try tmp.dir.makePath("project-b");

    const plan_html =
        \\<!DOCTYPE html><html><head></head><body>
        \\  <script type="application/json" id="plan-data">{"title":"Plan A"}</script>
        \\</body></html>
    ;
    const map_html =
        \\<!DOCTYPE html><html><head></head><body>
        \\  <script type="application/json" id="map-data">{"title":"Map B"}</script>
        \\</body></html>
    ;

    try tmp.dir.writeFile("project-a/sub/anything.html", plan_html);
    try tmp.dir.writeFile("project-b/other.html", map_html);

    const entries = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeEntries(allocator, entries);

    var saw_plan = false;
    var saw_map = false;
    for (entries) |entry| {
        if (std.mem.endsWith(u8, entry.rel_path, "anything.html")) {
            try std.testing.expectEqual(ArtifactKind.plan, entry.kind);
            saw_plan = true;
        } else if (std.mem.endsWith(u8, entry.rel_path, "other.html")) {
            try std.testing.expectEqual(ArtifactKind.map, entry.kind);
            saw_map = true;
        } else {
            try std.testing.expect(false);
        }
    }
    try std.testing.expect(saw_plan);
    try std.testing.expect(saw_map);
}

test "scan omits unrelated html and non-html files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile("unrelated.html", "<html><body>no marker</body></html>");
    try tmp.dir.writeFile("notes.txt", "id=\"plan-data\" in a text file");
    try tmp.dir.writeFile("plan.html",
        \\<html><script type="application/json" id="plan-data">{}</script></html>
    );

    const entries = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeEntries(allocator, entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("plan.html", entries[0].rel_path);
    try std.testing.expectEqual(ArtifactKind.plan, entries[0].kind);
}

test "scan rejects marker-like text outside the embedded script element" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile("decoy.html",
        \\<html><body><p>id="plan-data"</p></body></html>
    );

    const entries = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeEntries(allocator, entries);

    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "scan applies case-insensitive html extension" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile("UPPER.HTML",
        \\<html><script type="application/json" id="plan-data">{}</script></html>
    );

    const entries = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeEntries(allocator, entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("UPPER.HTML", entries[0].rel_path);
}

test "scan normalizes relative paths with forward slashes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("nested/deep");
    try tmp.dir.writeFile("nested/deep/plan.html",
        \\<html><script type="application/json" id="plan-data">{}</script></html>
    );

    const entries = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeEntries(allocator, entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("nested/deep/plan.html", entries[0].rel_path);
    try std.testing.expect(std.mem.indexOfScalar(u8, entries[0].rel_path, '\\') == null);
}

test "scan entries contain metadata only and no html body" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const body_payload = "UNIQUE_BODY_MARKER_SHOULD_NOT_LEAK";
    const html = "<html><script type=\"application/json\" id=\"plan-data\">{}</script><body>" ++
        body_payload ++ "</body></html>";
    try tmp.dir.writeFile("plan.html", html);

    const entries = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeEntries(allocator, entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expect(entries[0].size > 0);
    for (entries) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.rel_path, body_payload) == null);
    }
}

test "scan skips hidden administrative directories" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".git");
    try tmp.dir.makePath("visible");
    try tmp.dir.writeFile(".git/hidden.html",
        \\<html><script type="application/json" id="plan-data">{}</script></html>
    );
    try tmp.dir.writeFile("visible/plan.html",
        \\<html><script type="application/json" id="plan-data">{}</script></html>
    );

    const entries = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeEntries(allocator, entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("visible/plan.html", entries[0].rel_path);
}

test "scan skips symlinks that point outside the root" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try outside.dir.writeFile("outside.html",
        \\<html><script type="application/json" id="plan-data">{}</script></html>
    );

    const target = try std.fmt.allocPrint(allocator, "{s}/outside.html", .{outside.dir.path.?});
    defer allocator.free(target);

    // Symlink support is platform-dependent; skip the test if it is unavailable.
    tmp.dir.symLink(target, "link.html", .{}) catch return;
    tmp.dir.symLink(outside.dir.path.?, "linkdir", .{}) catch return;

    const entries = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeEntries(allocator, entries);

    for (entries) |entry| {
        try std.testing.expect(!std.mem.eql(u8, entry.rel_path, "link.html"));
        try std.testing.expect(!std.mem.startsWith(u8, entry.rel_path, "linkdir"));
    }
}

test "scan does not retain artifact bodies in the catalog" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const leak_marker = "LEAK_CHECK_TOKEN";
    try tmp.dir.writeFile("plan.html", "<html><script type=\"application/json\" id=\"plan-data\">{}</script>" ++
        leak_marker ++ "</html>");
    try tmp.dir.writeFile("map.html", "<html><script type=\"application/json\" id=\"map-data\">{}</script>" ++
        leak_marker ++ "</html>");

    const entries = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeEntries(allocator, entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    for (entries) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.rel_path, leak_marker) == null);
        try std.testing.expect(entry.rel_path.len > 0);
    }
}
