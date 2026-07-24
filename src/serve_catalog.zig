const std = @import("std");

/// Maximum number of bytes read from an artifact while classifying it. The
/// plan/map markers emitted by the renderers appear near the top of the file,
/// so a bounded prefix is enough and avoids loading whole files into memory.
pub const classify_prefix_bytes: usize = 4096;

/// Maximum number of bytes of the embedded JSON metadata block that the
/// scanner will decode. A single oversized or malformed HTML file cannot
/// dominate a scan because metadata beyond this limit is rejected with a
/// warning and the rest of the scan continues.
pub const metadata_max_bytes: usize = 1024 * 1024;

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

/// Optional metadata extracted from the embedded JSON block. Each field is
/// null when absent from the document. The catalog never retains the artifact
/// body, only these concise metadata fields plus path, kind, size, and time.
pub const ArtifactMetadata = struct {
    title: ?[]const u8 = null,
    project: ?[]const u8 = null,
    status: ?[]const u8 = null,
    generated_at: ?[]const u8 = null,
    /// Only present for map artifacts when the document carries `diagramKind`.
    diagram_kind: ?[]const u8 = null,
};

/// Metadata for a discovered Matcha artifact. The catalog never retains the
/// artifact body, only normalized path, kind, size, modification time, and the
/// concise metadata extracted from the embedded JSON block.
pub const CatalogEntry = struct {
    /// Normalized relative path from the serving root using forward slashes.
    rel_path: []const u8,
    kind: ArtifactKind,
    size: u64,
    mtime: std.Io.Timestamp,
    metadata: ArtifactMetadata = .{},

    /// Group used to display this artifact. Determined from non-empty embedded
    /// `project`, otherwise the first directory relative to the root, otherwise
    /// `Ungrouped`. Computed lazily from `rel_path` and `metadata.project`.
    pub fn group(self: CatalogEntry) []const u8 {
        if (self.metadata.project) |project| {
            if (project.len > 0) return project;
        }
        if (std.mem.indexOfScalar(u8, self.rel_path, '/')) |sep| {
            if (sep > 0) return self.rel_path[0..sep];
        }
        return "Ungrouped";
    }
};

/// A concise per-file warning recorded while scanning a malformed or oversized
/// Matcha artifact. The scan continues after recording a warning so a single
/// bad file cannot abort discovery.
pub const ScanWarning = struct {
    /// Normalized relative path from the serving root using forward slashes.
    rel_path: []const u8,
    /// Short human-readable reason for the warning.
    reason: []const u8,
};

/// Result of a scan: the discovered catalog entries and any per-file warnings.
/// Both slices are owned by the caller and must be released with
/// `freeScanResult`.
pub const ScanResult = struct {
    entries: []CatalogEntry,
    warnings: []ScanWarning,
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
/// retained. Per-file warnings are recorded for malformed or oversized
/// artifacts without aborting the scan.
pub fn scan(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
) ScanError!ScanResult {
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
        for (entries.items) |entry| {
            freeEntryMetadata(allocator, entry);
            allocator.free(entry.rel_path);
        }
        entries.deinit(allocator);
    }

    var warnings: std.ArrayList(ScanWarning) = .empty;
    errdefer {
        for (warnings.items) |warning| {
            allocator.free(warning.rel_path);
            allocator.free(warning.reason);
        }
        warnings.deinit(allocator);
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

        var entry: CatalogEntry = .{
            .rel_path = rel_path,
            .kind = kind,
            .size = stat.size,
            .mtime = stat.mtime,
        };

        // Extract bounded metadata from the embedded JSON block. The block
        // is decoded without executing or interpreting HTML and any malformed
        // or oversized metadata is reported as a warning without aborting.
        extractMetadata(io, allocator, walker_entry.dir, walker_entry.basename, kind, &entry, &warnings, rel_path) catch |err| switch (err) {
            error.OutOfMemory => {
                allocator.free(rel_path);
                return error.OutOfMemory;
            },
            else => {
                // Record a concise warning for malformed artifacts and keep
                // the entry without metadata so the rest of the scan proceeds.
                appendWarning(allocator, &warnings, rel_path, "metadata extraction failed") catch {};
            },
        };

        entries.append(allocator, entry) catch {
            freeEntryMetadata(allocator, entry);
            allocator.free(rel_path);
            return error.OutOfMemory;
        };
    }

    return .{
        .entries = entries.toOwnedSlice(allocator) catch return error.OutOfMemory,
        .warnings = warnings.toOwnedSlice(allocator) catch return error.OutOfMemory,
    };
}

/// Append a warning, copying `rel_path` and `reason` into owned allocations.
/// Failure to allocate is non-fatal: the warning is dropped silently.
fn appendWarning(
    allocator: std.mem.Allocator,
    warnings: *std.ArrayList(ScanWarning),
    rel_path: []const u8,
    reason: []const u8,
) !void {
    const rel_path_owned = allocator.dupe(u8, rel_path) catch return;
    errdefer allocator.free(rel_path_owned);
    const reason_owned = allocator.dupe(u8, reason) catch {
        allocator.free(rel_path_owned);
        return;
    };
    errdefer allocator.free(reason_owned);
    warnings.append(allocator, .{
        .rel_path = rel_path_owned,
        .reason = reason_owned,
    }) catch {
        allocator.free(reason_owned);
        allocator.free(rel_path_owned);
        return;
    };
}

/// Extract bounded metadata from the embedded JSON block of an artifact. The
/// block is located between the matched marker and the closing `</script>`
/// tag. The script-safe JSON representation emitted by Matcha (which escapes
/// `<` as `\u003c`) is decoded before parsing. Only the top-level object keys
/// needed for catalog metadata are read; nested values are skipped. Malformed
/// or oversized metadata is reported through `warnings` and the entry keeps
/// whatever metadata was decoded before the failure.
fn extractMetadata(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    basename: []const u8,
    kind: ArtifactKind,
    entry: *CatalogEntry,
    warnings: *std.ArrayList(ScanWarning),
    rel_path: []const u8,
) !void {
    const marker = switch (kind) {
        .plan => plan_marker,
        .map => map_marker,
    };

    // Read the whole file into a bounded buffer so we can locate the closing
    // </script> tag. The metadata block itself is bounded by
    // `metadata_max_bytes` during decoding; files larger than the read limit
    // are still classified but metadata extraction reports a warning.
    const file_bytes = dir.readFileAlloc(io, basename, allocator, .limited(metadata_max_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try appendWarning(allocator, warnings, rel_path, "cannot read artifact for metadata");
            return;
        },
    };
    defer allocator.free(file_bytes);

    // Locate the marker within the file bytes.
    const marker_index = std.mem.indexOf(u8, file_bytes, marker) orelse {
        try appendWarning(allocator, warnings, rel_path, "embedded marker not found");
        return;
    };

    // The JSON body starts after the opening <script ...> tag.
    const tag_close = std.mem.indexOfScalarPos(u8, file_bytes, marker_index, '>') orelse {
        try appendWarning(allocator, warnings, rel_path, "malformed script tag");
        return;
    };
    const json_start = tag_close + 1;

    // The JSON body ends at the closing </script> tag.
    const script_close = std.mem.indexOfPos(u8, file_bytes, json_start, "</script>") orelse {
        try appendWarning(allocator, warnings, rel_path, "missing closing script tag");
        return;
    };
    const json_raw = std.mem.trim(u8, file_bytes[json_start..script_close], " \t\r\n");

    if (json_raw.len == 0) {
        try appendWarning(allocator, warnings, rel_path, "empty embedded metadata");
        return;
    }

    // Decode the script-safe JSON representation emitted by Matcha. The
    // renderer escapes `<` as `\u003c` so the JSON can live inside a script
    // element; we reverse that escape (and the standard `\u003e` form) before
    // parsing. The decoded text is allocated and freed here.
    const json_decoded = decodeScriptSafeJson(allocator, json_raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try appendWarning(allocator, warnings, rel_path, "cannot decode script-safe json");
            return;
        },
    };
    defer allocator.free(json_decoded);

    parseMetadata(allocator, json_decoded, kind, entry, warnings, rel_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
}

/// Decode the script-safe JSON representation emitted by Matcha. The renderer
/// escapes `<` as the six-character sequence `\u003c` (and `>` as `\u003e`) so
/// JSON containing `</script>` does not break the embedding. This reverses
/// those escapes so a standard JSON parser can read the payload. No other
/// interpretation of HTML is performed.
fn decodeScriptSafeJson(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (i + 6 <= input.len and
            input[i] == '\\' and input[i + 1] == 'u' and
            std.ascii.eqlIgnoreCase(input[i + 2 .. i + 6], "003c"))
        {
            try out.append(allocator, '<');
            i += 6;
            continue;
        }
        if (i + 6 <= input.len and
            input[i] == '\\' and input[i + 1] == 'u' and
            std.ascii.eqlIgnoreCase(input[i + 2 .. i + 6], "003e"))
        {
            try out.append(allocator, '>');
            i += 6;
            continue;
        }
        try out.append(allocator, input[i]);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

/// Parse the decoded JSON metadata and populate `entry.metadata`. Only the
/// top-level object keys needed for the catalog are read; nested values are
/// skipped with `Scanner.skipValue`. Strings are owned by the caller and must
/// be freed via `freeEntryMetadata`. Malformed JSON records a warning and
/// leaves the entry with whatever metadata was decoded before the failure.
fn parseMetadata(
    allocator: std.mem.Allocator,
    json: []const u8,
    kind: ArtifactKind,
    entry: *CatalogEntry,
    warnings: *std.ArrayList(ScanWarning),
    rel_path: []const u8,
) !void {
    var scanner = std.json.Scanner.initCompleteInput(allocator, json);
    defer scanner.deinit();

    const first = scanner.next() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try appendWarning(allocator, warnings, rel_path, "malformed json metadata");
            return;
        },
    };
    if (first != .object_begin) {
        try appendWarning(allocator, warnings, rel_path, "embedded metadata is not a json object");
        return;
    }

    while (true) {
        const key_token = scanner.nextAlloc(allocator, .alloc_if_needed) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try appendWarning(allocator, warnings, rel_path, "malformed json metadata");
                return;
            },
        };
        switch (key_token) {
            .object_end => break,
            .end_of_document => break,
            .string => |key_slice| {
                // `alloc_if_needed` may return a slice borrowed from the input;
                // copy the ones we keep so they outlive the scanner.
                try handleMetadataKey(allocator, key_slice, kind, entry, &scanner, warnings, rel_path);
            },
            .allocated_string => |key_owned| {
                defer allocator.free(key_owned);
                try handleMetadataKey(allocator, key_owned, kind, entry, &scanner, warnings, rel_path);
            },
            else => {
                // Unexpected token in key position; skip the value and continue.
                scanner.skipValue() catch {
                    try appendWarning(allocator, warnings, rel_path, "malformed json metadata");
                    return;
                };
            },
        }
    }

    // Apply the filename title fallback when no title was present.
    if (entry.metadata.title == null or entry.metadata.title.?.len == 0) {
        const basename = std.fs.path.basename(rel_path);
        const stem = basename[0 .. basename.len - std.fs.path.extension(basename).len];
        entry.metadata.title = allocator.dupe(u8, stem) catch return error.OutOfMemory;
    }
}

/// Inspect a single top-level metadata key and, if recognized, decode its
/// string value into `entry.metadata`. Unrecognized keys skip their value.
/// Kept strings are duplicated so they outlive the scanner's input slice.
fn handleMetadataKey(
    allocator: std.mem.Allocator,
    key: []const u8,
    kind: ArtifactKind,
    entry: *CatalogEntry,
    scanner: *std.json.Scanner,
    warnings: *std.ArrayList(ScanWarning),
    rel_path: []const u8,
) !void {
    const wants = std.mem.eql(u8, key, "title") or
        std.mem.eql(u8, key, "project") or
        std.mem.eql(u8, key, "status") or
        std.mem.eql(u8, key, "generatedAt") or
        (kind == .map and std.mem.eql(u8, key, "diagramKind"));

    if (!wants) {
        scanner.skipValue() catch {
            try appendWarning(allocator, warnings, rel_path, "malformed json metadata");
            return error.Unexpected;
        };
        return;
    }

    const value_token = scanner.nextAlloc(allocator, .alloc_if_needed) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try appendWarning(allocator, warnings, rel_path, "malformed json metadata");
            return error.Unexpected;
        },
    };

    const value_slice: ?[]const u8 = switch (value_token) {
        .string => |s| s,
        .allocated_string => |s| s,
        else => null,
    };
    if (value_slice == null) {
        // Non-string value: ignore but do not warn; the field is simply absent.
        return;
    }
    const value = value_slice.?;

    const dup = allocator.dupe(u8, value) catch return error.OutOfMemory;

    if (std.mem.eql(u8, key, "title")) {
        if (entry.metadata.title) |old| allocator.free(old);
        entry.metadata.title = dup;
    } else if (std.mem.eql(u8, key, "project")) {
        if (entry.metadata.project) |old| allocator.free(old);
        entry.metadata.project = dup;
    } else if (std.mem.eql(u8, key, "status")) {
        if (entry.metadata.status) |old| allocator.free(old);
        entry.metadata.status = dup;
    } else if (std.mem.eql(u8, key, "generatedAt")) {
        if (entry.metadata.generated_at) |old| allocator.free(old);
        entry.metadata.generated_at = dup;
    } else if (kind == .map and std.mem.eql(u8, key, "diagramKind")) {
        if (entry.metadata.diagram_kind) |old| allocator.free(old);
        entry.metadata.diagram_kind = dup;
    } else {
        allocator.free(dup);
    }
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
/// owned relative path and any owned metadata strings.
pub fn freeEntries(allocator: std.mem.Allocator, entries: []CatalogEntry) void {
    for (entries) |entry| {
        freeEntryMetadata(allocator, entry);
        allocator.free(entry.rel_path);
    }
    allocator.free(entries);
}

/// Free a `ScanResult` returned by `scan`, including entries, warnings, and
/// all owned strings within them.
pub fn freeScanResult(allocator: std.mem.Allocator, result: ScanResult) void {
    freeEntries(allocator, result.entries);
    for (result.warnings) |warning| {
        allocator.free(warning.rel_path);
        allocator.free(warning.reason);
    }
    allocator.free(result.warnings);
}

/// Free the owned metadata strings attached to a single entry. The entry's
/// `rel_path` is freed separately by the caller.
fn freeEntryMetadata(allocator: std.mem.Allocator, entry: CatalogEntry) void {
    if (entry.metadata.title) |s| allocator.free(s);
    if (entry.metadata.project) |s| allocator.free(s);
    if (entry.metadata.status) |s| allocator.free(s);
    if (entry.metadata.generated_at) |s| allocator.free(s);
    if (entry.metadata.diagram_kind) |s| allocator.free(s);
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

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);
    const entries = result.entries;

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

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);
    const entries = result.entries;

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

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);
    const entries = result.entries;

    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "scan applies case-insensitive html extension" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile("UPPER.HTML",
        \\<html><script type="application/json" id="plan-data">{}</script></html>
    );

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);
    const entries = result.entries;

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

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);
    const entries = result.entries;

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

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);
    const entries = result.entries;

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

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);
    const entries = result.entries;

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

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);
    const entries = result.entries;

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

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);
    const entries = result.entries;

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    for (entries) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.rel_path, leak_marker) == null);
        try std.testing.expect(entry.rel_path.len > 0);
    }
}

// ---------------------------------------------------------------------------
// E2.S2: bounded index metadata extraction and project determination.
// ---------------------------------------------------------------------------

/// Helper that writes a plan HTML fixture with the given embedded JSON payload
/// using the exact script-safe escaping the Matcha renderer emits.
fn writePlanFixture(dir: std.Io.Dir, name: []const u8, json_payload: []const u8) !void {
    const html = "<html><head><title>x</title></head><body>" ++
        "<script type=\"application/json\" id=\"plan-data\">\n" ++
        json_payload ++
        "\n  </script></body></html>";
    try dir.writeFile(name, html);
}

fn writeMapFixture(dir: std.Io.Dir, name: []const u8, json_payload: []const u8) !void {
    const html = "<html><head><title>x</title></head><body>" ++
        "<script type=\"application/json\" id=\"map-data\">\n" ++
        json_payload ++
        "\n  </script></body></html>";
    try dir.writeFile(name, html);
}

test "scan extracts complete plan metadata" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload =
        \\{"title":"Plan Title","project":"alpha","status":"planned","generatedAt":"2026-07-24T10:00:00Z"}
    ;
    try writePlanFixture(tmp.dir, "plan.html", payload);

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);
    const entries = result.entries;

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("Plan Title", entries[0].metadata.title.?);
    try std.testing.expectEqualStrings("alpha", entries[0].metadata.project.?);
    try std.testing.expectEqualStrings("planned", entries[0].metadata.status.?);
    try std.testing.expectEqualStrings("2026-07-24T10:00:00Z", entries[0].metadata.generated_at.?);
    try std.testing.expect(entries[0].metadata.diagram_kind == null);
}

test "scan extracts complete map metadata including diagram kind" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload =
        \\{"title":"Map Title","project":"beta","status":"draft","generatedAt":"2026-07-24T11:00:00Z","diagramKind":"class","elements":[]}
    ;
    try writeMapFixture(tmp.dir, "map.html", payload);

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);
    const entries = result.entries;

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(ArtifactKind.map, entries[0].kind);
    try std.testing.expectEqualStrings("Map Title", entries[0].metadata.title.?);
    try std.testing.expectEqualStrings("beta", entries[0].metadata.project.?);
    try std.testing.expectEqualStrings("draft", entries[0].metadata.status.?);
    try std.testing.expectEqualStrings("2026-07-24T11:00:00Z", entries[0].metadata.generated_at.?);
    try std.testing.expectEqualStrings("class", entries[0].metadata.diagram_kind.?);
}

test "scan does not read diagramKind from plan artifacts" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A plan document would not normally carry diagramKind, but the scanner
    // must ignore it even if present.
    const payload =
        \\{"title":"Plan","diagramKind":"class"}
    ;
    try writePlanFixture(tmp.dir, "plan.html", payload);

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);
    const entries = result.entries;

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("Plan", entries[0].metadata.title.?);
    try std.testing.expect(entries[0].metadata.diagram_kind == null);
}

test "scan applies filename title fallback when title is missing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = "{}";
    try writePlanFixture(tmp.dir, "my-plan.html", payload);

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);
    const entries = result.entries;

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("my-plan", entries[0].metadata.title.?);
    try std.testing.expect(entries[0].metadata.project == null);
    try std.testing.expect(entries[0].metadata.status == null);
}

test "scan applies filename title fallback when title is empty string" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = "{\"title\":\"\"}";
    try writePlanFixture(tmp.dir, "empty-title.html", payload);

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);
    const entries = result.entries;

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("empty-title", entries[0].metadata.title.?);
}

test "group follows embedded project before directory before ungrouped" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("nested/dir");

    // Embedded project wins.
    try writePlanFixture(tmp.dir, "nested/dir/a.html",
        \\{"title":"A","project":"embedded-project"}
    );
    // No embedded project: first directory wins.
    try writePlanFixture(tmp.dir, "nested/dir/b.html",
        \\{"title":"B"}
    );
    // No project and top-level file: Ungrouped.
    try writePlanFixture(tmp.dir, "c.html",
        \\{"title":"C"}
    );

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);
    const entries = result.entries;

    try std.testing.expectEqual(@as(usize, 3), entries.len);
    for (entries) |entry| {
        if (std.mem.endsWith(u8, entry.rel_path, "a.html")) {
            try std.testing.expectEqualStrings("embedded-project", entry.group());
        } else if (std.mem.endsWith(u8, entry.rel_path, "b.html")) {
            try std.testing.expectEqualStrings("nested", entry.group());
        } else if (std.mem.eql(u8, entry.rel_path, "c.html")) {
            try std.testing.expectEqualStrings("Ungrouped", entry.group());
        }
    }
}

test "group ignores empty embedded project and falls back to directory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("real-dir");
    try writePlanFixture(tmp.dir, "real-dir/a.html",
        \\{"title":"A","project":""}
    );

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);
    const entries = result.entries;

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("real-dir", entries[0].group());
}

test "scan records a warning for malformed json metadata and keeps the entry" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = "{not valid json";
    try writePlanFixture(tmp.dir, "bad.html", payload);
    try writePlanFixture(tmp.dir, "good.html",
        \\{"title":"Good"}
    );

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.entries.len);
    // The malformed file produces a warning but both files are cataloged.
    try std.testing.expect(result.warnings.len >= 1);
    var saw_bad_warning = false;
    for (result.warnings) |warning| {
        if (std.mem.endsWith(u8, warning.rel_path, "bad.html")) {
            try std.testing.expect(warning.reason.len > 0);
            saw_bad_warning = true;
        }
    }
    try std.testing.expect(saw_bad_warning);
}

test "scan records a warning for missing closing script tag" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Marker present but no closing </script>.
    const html = "<html><script type=\"application/json\" id=\"plan-data\">{\"title\":\"X\"";
    try tmp.dir.writeFile("unclosed.html", html);

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expect(result.warnings.len >= 1);
}

test "scan decodes script-safe escaped less-than characters" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The renderer escapes `<` as \u003c inside the JSON payload.
    const payload = "{\"title\":\"has \\u003cscript\\u003e tag\",\"project\":\"p\"}";
    try writePlanFixture(tmp.dir, "escaped.html", payload);

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);
    const entries = result.entries;

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("has <script> tag", entries[0].metadata.title.?);
    try std.testing.expectEqualStrings("p", entries[0].metadata.project.?);
}

test "scan ignores deceptive duplicate markers outside the metadata block" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The first marker is inside the real script tag; a second marker-like
    // string appears later in the body text but must not confuse extraction.
    const payload = "{\"title\":\"Real Title\"}";
    const html = "<html><body>" ++
        "<script type=\"application/json\" id=\"plan-data\">\n" ++ payload ++ "\n</script>" ++
        "<p>type=\"application/json\" id=\"plan-data\"</p></body></html>";
    try tmp.dir.writeFile("dup.html", html);

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);
    const entries = result.entries;

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("Real Title", entries[0].metadata.title.?);
}

test "scan rejects oversized embedded metadata with a warning" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Build a JSON metadata block larger than metadata_max_bytes by repeating
    // a key/value pair. The scan should classify the file (marker is in the
    // prefix) but record a warning instead of decoding the whole block.
    var huge_payload: std.ArrayList(u8) = .empty;
    defer huge_payload.deinit(allocator);
    try huge_payload.appendSlice(allocator, "{\"title\":\"Big\",\"junk\":\"");
    while (huge_payload.items.len < metadata_max_bytes + 1024) {
        try huge_payload.appendSlice(allocator, "x");
    }
    try huge_payload.appendSlice(allocator, "\"}");

    const html = "<html><body>" ++
        "<script type=\"application/json\" id=\"plan-data\">\n" ++
        huge_payload.items ++ "\n</script></body></html>";
    try tmp.dir.writeFile("huge.html", html);

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);

    // The file is classified but metadata extraction fails with a warning.
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expect(result.warnings.len >= 1);
}

test "scan extracts metadata against renderer-produced plan fixture" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_path = try std.fmt.allocPrint(allocator, "{s}/rendered-plan.html", .{tmp.dir.path.?});
    defer allocator.free(output_path);

    const render_html = @import("render_html.zig");
    try render_html.writePlanHtml(
        std.testing.io,
        output_path,
        "Rendered Plan Title",
        "{\"title\":\"Rendered Plan Title\",\"project\":\"matcha\",\"status\":\"planned\",\"generatedAt\":\"2026-07-24T00:00:00Z\"}",
    );

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);
    const entries = result.entries;

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(ArtifactKind.plan, entries[0].kind);
    try std.testing.expectEqualStrings("Rendered Plan Title", entries[0].metadata.title.?);
    try std.testing.expectEqualStrings("matcha", entries[0].metadata.project.?);
    try std.testing.expectEqualStrings("planned", entries[0].metadata.status.?);
    try std.testing.expectEqualStrings("2026-07-24T00:00:00Z", entries[0].metadata.generated_at.?);
}

test "scan extracts metadata against renderer-produced map fixture" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_path = try std.fmt.allocPrint(allocator, "{s}/rendered-map.html", .{tmp.dir.path.?});
    defer allocator.free(output_path);

    const render_html = @import("render_html.zig");
    try render_html.writeMapHtml(
        std.testing.io,
        output_path,
        "Rendered Map Title",
        "{\"title\":\"Rendered Map Title\",\"project\":\"matcha\",\"status\":\"draft\",\"generatedAt\":\"2026-07-24T01:00:00Z\",\"diagramKind\":\"class\",\"elements\":[]}",
    );

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);
    const entries = result.entries;

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(ArtifactKind.map, entries[0].kind);
    try std.testing.expectEqualStrings("Rendered Map Title", entries[0].metadata.title.?);
    try std.testing.expectEqualStrings("matcha", entries[0].metadata.project.?);
    try std.testing.expectEqualStrings("draft", entries[0].metadata.status.?);
    try std.testing.expectEqualStrings("2026-07-24T01:00:00Z", entries[0].metadata.generated_at.?);
    try std.testing.expectEqualStrings("class", entries[0].metadata.diagram_kind.?);
}

test "scan skips nested arrays and objects while reading top-level keys" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A large nested structure under an unrelated key must not dominate the
    // scan; the scanner skips it and still reads the catalog fields.
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    try payload.appendSlice(allocator,
        \\{"title":"Top","project":"p","status":"ready","generatedAt":"2026-01-01T00:00:00Z","bigNested":
    );
    try payload.appendSlice(allocator, "{\"a\":[");
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        if (i > 0) try payload.appendSlice(allocator, ",");
        try payload.appendSlice(allocator, "{\"k\":[1,2,3]}");
    }
    try payload.appendSlice(allocator, "]} }");

    try writePlanFixture(tmp.dir, "nested.html", payload.items);

    const result = try scan(std.testing.io, allocator, tmp.dir.path.?);
    defer freeScanResult(allocator, result);
    const entries = result.entries;

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("Top", entries[0].metadata.title.?);
    try std.testing.expectEqualStrings("p", entries[0].metadata.project.?);
    try std.testing.expectEqualStrings("ready", entries[0].metadata.status.?);
}

test "decodeScriptSafeJson reverses matcha escapes" {
    const allocator = std.testing.allocator;
    const input = "before\\u003cmid\\u003eafter\\u003C/script\\u003E";
    const decoded = try decodeScriptSafeJson(allocator, input);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("before<mid>after</script>", decoded);
}

test "decodeScriptSafeJson passes through non-escaped content" {
    const allocator = std.testing.allocator;
    const input = "plain text with unicode \u{1f600} and backslash-n \\n";
    const decoded = try decodeScriptSafeJson(allocator, input);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings(input, decoded);
}
