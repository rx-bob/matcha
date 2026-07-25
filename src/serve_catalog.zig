const std = @import("std");

const serve_routes = @import("serve_routes.zig");

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
        error.SystemResources => return error.OutOfMemory,
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

// ---------------------------------------------------------------------------
// E2.S3: immutable catalog snapshots, deterministic JSON, and a background
// scanner that refreshes the catalog on a configured interval.
// ---------------------------------------------------------------------------

/// An immutable, sorted catalog snapshot published by the scanner. Both
/// `entries` and `warnings` are owned by the snapshot and released with
/// `freeCatalog`. Entries are sorted by `(group, kind, rel_path)` and warnings
/// by `(rel_path, reason)` so serialized output is stable and client rendering
/// is inexpensive. Snapshots never retain artifact bodies or absolute paths.
pub const Catalog = struct {
    entries: []CatalogEntry,
    warnings: []ScanWarning,

    /// Free the snapshot and all owned strings within it.
    pub fn deinit(self: *Catalog, allocator: std.mem.Allocator) void {
        freeEntries(allocator, self.entries);
        for (self.warnings) |warning| {
            allocator.free(warning.rel_path);
            allocator.free(warning.reason);
        }
        allocator.free(self.warnings);
        allocator.destroy(self);
    }

    /// Look up the catalog entry whose normalized relative path equals
    /// `rel_path`. Returns null when the path is not a currently recognized
    /// catalog artifact. Used at request time to re-check that an artifact
    /// request targets a live catalog entry rather than an arbitrary file
    /// under the root, so the server cannot be used as a general-purpose
    /// file browser.
    pub fn findEntry(self: *const Catalog, rel_path: []const u8) ?CatalogEntry {
        // Entries are sorted by (group, kind, rel_path); the rel_path is not
        // the primary key, so a binary search would be unsound. Catalog size
        // is small and the scan is bounded, so a linear scan is fine.
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.rel_path, rel_path)) return entry;
        }
        return null;
    }
};

/// Ordering for entries: group, then kind (plan before map), then rel_path.
fn entryLessThan(_: void, a: CatalogEntry, b: CatalogEntry) bool {
    const ga = a.group();
    const gb = b.group();
    switch (std.mem.order(u8, ga, gb)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    return std.mem.lessThan(u8, a.rel_path, b.rel_path);
}

/// Ordering for warnings: rel_path, then reason.
fn warningLessThan(_: void, a: ScanWarning, b: ScanWarning) bool {
    switch (std.mem.order(u8, a.rel_path, b.rel_path)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    return std.mem.lessThan(u8, a.reason, b.reason);
}

/// Build an immutable sorted catalog snapshot from a `ScanResult`. The scan
/// result's owned entries and warnings are moved into the snapshot; on error
/// the scan result is still consumed via `freeScanResult`. The returned
/// `*Catalog` is heap-allocated and must be released with `Catalog.deinit`.
pub fn buildCatalog(
    allocator: std.mem.Allocator,
    result: ScanResult,
) error{OutOfMemory}!*Catalog {
    std.mem.sort(CatalogEntry, result.entries, {}, entryLessThan);
    std.mem.sort(ScanWarning, result.warnings, {}, warningLessThan);

    const catalog = allocator.create(Catalog) catch {
        freeScanResult(allocator, result);
        return error.OutOfMemory;
    };
    catalog.* = .{
        .entries = result.entries,
        .warnings = result.warnings,
    };
    return catalog;
}

/// Serialize a catalog snapshot as deterministic JSON to `writer`. The payload
/// is grouped by project with sorted artifacts and sorted warnings, uses
/// `application/json`-compatible syntax, and contains no absolute filesystem
/// paths. Optional metadata fields are omitted when absent so clients can
/// detect missing values without sentinel strings.
pub fn writeCatalogJson(
    writer: *std.Io.Writer,
    catalog: *const Catalog,
) std.Io.Writer.Error!void {
    try writer.writeAll("{\"projects\":[");

    var first_project = true;
    var i: usize = 0;
    while (i < catalog.entries.len) {
        const group_name = catalog.entries[i].group();
        if (!first_project) try writer.writeAll(",");
        first_project = false;
        try writer.writeAll("{\"name\":");
        try appendJsonStringJson(writer, group_name);
        try writer.writeAll(",\"artifacts\":[");

        var first_artifact = true;
        while (i < catalog.entries.len and
            std.mem.eql(u8, catalog.entries[i].group(), group_name))
        {
            if (!first_artifact) try writer.writeAll(",");
            first_artifact = false;
            const entry = catalog.entries[i];
            try writer.writeAll("{\"relPath\":");
            try appendJsonStringJson(writer, entry.rel_path);
            try writer.writeAll(",\"url\":");
            try serve_routes.writeArtifactUrl(writer, entry.rel_path);
            try writer.writeAll(",\"kind\":");
            try appendJsonStringJson(writer, switch (entry.kind) {
                .plan => "plan",
                .map => "map",
            });
            try writer.writeAll(",\"group\":");
            try appendJsonStringJson(writer, group_name);
            try writer.writeAll(",\"size\":");
            try writer.printInt(entry.size, 10, .lower, .{});
            try writer.writeAll(",\"mtime\":");
            try writer.printInt(entry.mtime.nanoseconds, 10, .lower, .{});
            if (entry.metadata.title) |s| {
                try writer.writeAll(",\"title\":");
                try appendJsonStringJson(writer, s);
            }
            if (entry.metadata.project) |s| {
                try writer.writeAll(",\"project\":");
                try appendJsonStringJson(writer, s);
            }
            if (entry.metadata.status) |s| {
                try writer.writeAll(",\"status\":");
                try appendJsonStringJson(writer, s);
            }
            if (entry.metadata.generated_at) |s| {
                try writer.writeAll(",\"generatedAt\":");
                try appendJsonStringJson(writer, s);
            }
            if (entry.metadata.diagram_kind) |s| {
                try writer.writeAll(",\"diagramKind\":");
                try appendJsonStringJson(writer, s);
            }
            try writer.writeAll("}");
            i += 1;
        }
        try writer.writeAll("]}");
    }
    if (first_project) {
        // Empty catalog: emit a single Ungrouped project with no artifacts so
        // clients always receive a valid projects array shape.
        try writer.writeAll("{\"name\":\"Ungrouped\",\"artifacts\":[]}");
    }

    try writer.writeAll("],\"warnings\":[");
    for (catalog.warnings, 0..) |warning, w| {
        if (w > 0) try writer.writeAll(",");
        try writer.writeAll("{\"relPath\":");
        try appendJsonStringJson(writer, warning.rel_path);
        try writer.writeAll(",\"reason\":");
        try appendJsonStringJson(writer, warning.reason);
        try writer.writeAll("}");
    }
    try writer.writeAll("]}");
}

/// Write a JSON-escaped string directly to a writer. Used by `writeCatalogJson`
/// to avoid intermediate allocation when serializing to the response stream.
fn appendJsonStringJson(writer: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (s) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x08 => try writer.writeAll("\\b"),
        0x0c => try writer.writeAll("\\f"),
        0x00...0x07, 0x0b, 0x0e...0x1f => {
            var buf: [6]u8 = undefined;
            const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{byte}) catch unreachable;
            try writer.writeAll(hex);
        },
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

/// Allocate a JSON document for `catalog` using `allocator`. The caller owns
/// the returned slice. Useful for tests and for buffering a response before
/// writing it to the network.
pub fn catalogJsonAlloc(
    allocator: std.mem.Allocator,
    catalog: *const Catalog,
) error{OutOfMemory}![]u8 {
    var list: std.ArrayList(u8) = .empty;
    var allocating = std.Io.Writer.Allocating.fromArrayList(allocator, &list);
    errdefer allocating.deinit();
    writeCatalogJson(&allocating.writer, catalog) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    allocating.writer.flush() catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    var out = allocating.toArrayList();
    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// Injectable scan function signature. Defaults to `scan` so production uses
/// the real filesystem walker while tests can substitute a controlled hook.
pub const ScanFn = *const fn (io: std.Io, allocator: std.mem.Allocator, root: []const u8) ScanError!ScanResult;

/// Background scanner that refreshes an immutable catalog snapshot on a
/// configured interval, independently of incoming HTTP requests. The scanner
/// runs a single worker so scans never overlap or accumulate queued jobs. The
/// current snapshot is published atomically under a mutex; requests always
/// observe a complete prior or complete new snapshot. Shutdown joins the
/// worker safely.
pub const Scanner = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    interval_seconds: u32,
    scan_fn: ScanFn,

    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    current: ?*Catalog = null,
    last_scan_failed: bool = false,
    thread: ?std.Thread = null,

    /// Optional operator diagnostic sink. When set, scan warnings and scan
    /// failure/recovery transitions are reported here with relative paths and
    /// concise reasons. Null keeps the scanner silent (preserving the
    /// behavior of unit tests that do not assert on diagnostics).
    stderr: ?*std.Io.Writer = null,
    /// Warnings emitted by the previous successful scan, owned by the
    /// scanner and used to deduplicate unchanged warnings across scans so a
    /// persistent malformed file does not flood output every interval. Freed
    /// and replaced after each successful scan; reset to empty on scan
    /// failure so a warning that disappeared and later reappears is reported
    /// again.
    prev_warnings: []ScanWarning = &.{},
    /// Previous scan-failure state, used to report only the
    /// success-to-failure and failure-to-success transitions instead of
    /// repeating the same diagnostic every interval.
    prev_scan_failed: bool = false,

    /// Initialize a scanner. The caller must call `start` to spawn the worker
    /// and `stop` to join it and release the current snapshot.
    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        root: []const u8,
        interval_seconds: u32,
        scan_fn: ScanFn,
    ) Scanner {
        return .{
            .io = io,
            .allocator = allocator,
            .root = root,
            .interval_seconds = interval_seconds,
            .scan_fn = scan_fn,
        };
    }

    /// Enable operator diagnostics on the given writer. Scan warnings and
    /// failure/recovery transitions are written here. Must be called before
    /// `initialScan` to capture the initial scan's diagnostics.
    pub fn enableDiagnostics(self: *Scanner, stderr: *std.Io.Writer) void {
        self.stderr = stderr;
    }

    /// Perform the initial scan synchronously so the catalog is available
    /// before the server reports readiness. On scan failure the server still
    /// starts with an empty catalog; the worker will retry on the interval.
    pub fn initialScan(self: *Scanner) void {
        self.runScan();
    }

    /// Spawn the background worker. Must be called after `initialScan`.
    pub fn start(self: *Scanner) !void {
        self.thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, worker, .{self});
    }

    /// Signal shutdown, wake the worker, and join it. Releases the current
    /// snapshot and any dedup state. Safe to call once; idempotent on the
    /// thread handle.
    pub fn stop(self: *Scanner) void {
        self.shutdown.store(true, .release);
        self.cond.broadcast(self.io);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.current) |catalog| {
            catalog.deinit(self.allocator);
            self.current = null;
        }
        self.freePrevWarnings();
    }

    fn freePrevWarnings(self: *Scanner) void {
        for (self.prev_warnings) |w| {
            self.allocator.free(w.rel_path);
            self.allocator.free(w.reason);
        }
        if (self.prev_warnings.len > 0) self.allocator.free(self.prev_warnings);
        self.prev_warnings = &.{};
    }

    /// Run a single scan, build a snapshot, and swap it in under the mutex. The
    /// previous snapshot is freed after the swap. Scan failures leave the prior
    /// catalog available and record `last_scan_failed`. When diagnostics are
    /// enabled, scan warnings, failure, and recovery are reported to the
    /// operator with relative paths and concise reasons; unchanged warnings
    /// are deduplicated against the previous scan so output does not flood.
    pub fn runScan(self: *Scanner) void {
        const result = self.scan_fn(self.io, self.allocator, self.root) catch |err| {
            self.mutex.lockUncancelable(self.io);
            self.last_scan_failed = true;
            self.mutex.unlock(self.io);
            self.reportScanFailure(err);
            return;
        };
        const new_catalog = buildCatalog(self.allocator, result) catch |err| {
            self.mutex.lockUncancelable(self.io);
            self.last_scan_failed = true;
            self.mutex.unlock(self.io);
            self.reportScanFailure(err);
            return;
        };

        self.mutex.lockUncancelable(self.io);
        const old = self.current;
        self.current = new_catalog;
        self.last_scan_failed = false;
        self.mutex.unlock(self.io);

        if (old) |c| c.deinit(self.allocator);

        self.reportScanSuccess(new_catalog);
    }

    /// Report a scan failure transition to the operator. Only the first
    /// failure in a run of failures is reported; subsequent failures stay
    /// silent until the scanner recovers. Dedup state is reset so warnings
    /// that reappear after recovery are reported fresh.
    fn reportScanFailure(self: *Scanner, err: anyerror) void {
        if (self.prev_scan_failed) return;
        self.prev_scan_failed = true;
        self.freePrevWarnings();
        if (self.stderr) |w| {
            w.print("matcha serve: scan failed: {s}\n", .{@errorName(err)}) catch {};
        }
    }

    /// Report scan recovery and any new or changed warnings to the operator.
    /// Warnings unchanged from the previous successful scan are suppressed.
    /// Disappeared warnings are simply no longer reported (no "resolved" line)
    /// to keep output concise; the dedup state is updated so a warning that
    /// disappears and later reappears is reported again.
    fn reportScanSuccess(self: *Scanner, catalog: *const Catalog) void {
        if (self.prev_scan_failed) {
            if (self.stderr) |w| {
                w.writeAll("matcha serve: scan recovered\n") catch {};
            }
        }
        self.prev_scan_failed = false;

        if (self.stderr) |w| {
            for (catalog.warnings) |warning| {
                if (!warningPresent(self.prev_warnings, warning)) {
                    w.print("matcha serve: warning: {s}: {s}\n", .{ warning.rel_path, warning.reason }) catch {};
                }
            }
        }

        // Update dedup state with the current warnings.
        self.freePrevWarnings();
        if (catalog.warnings.len == 0) {
            self.prev_warnings = &.{};
            return;
        }
        const owned = self.allocator.alloc(ScanWarning, catalog.warnings.len) catch {
            self.prev_warnings = &.{};
            return;
        };
        var count: usize = 0;
        for (catalog.warnings) |warning| {
            const rel = self.allocator.dupe(u8, warning.rel_path) catch continue;
            const reason = self.allocator.dupe(u8, warning.reason) catch {
                self.allocator.free(rel);
                continue;
            };
            owned[count] = .{ .rel_path = rel, .reason = reason };
            count += 1;
        }
        self.prev_warnings = owned[0..count];
    }

    /// Acquire the current snapshot for reading. The caller MUST hold the
    /// returned guard for the entire duration of reading the catalog; the
    /// scanner cannot swap or free the snapshot while the guard is held.
    pub fn snapshotLock(self: *Scanner) SnapshotGuard {
        self.mutex.lockUncancelable(self.io);
        return .{ .scanner = self, .catalog = self.current };
    }

    fn worker(self: *Scanner) void {
        while (true) {
            if (self.shutdown.load(.acquire)) return;
            const duration = std.Io.Clock.Duration{
                .raw = std.Io.Duration.fromSeconds(@intCast(self.interval_seconds)),
                .clock = .awake,
            };
            self.mutex.lockUncancelable(self.io);
            if (!self.shutdown.load(.acquire)) {
                self.cond.waitTimeout(self.io, &self.mutex, .{ .duration = duration }) catch {};
            }
            self.mutex.unlock(self.io);
            if (self.shutdown.load(.acquire)) return;
            self.runScan();
        }
    }
};

/// True when `warning` (rel_path + reason) is present in `prev`. Both slices
/// are sorted by (rel_path, reason) so a linear scan is sufficient for the
/// small warning counts produced by a single scan.
fn warningPresent(prev: []const ScanWarning, warning: ScanWarning) bool {
    for (prev) |p| {
        if (std.mem.eql(u8, p.rel_path, warning.rel_path) and
            std.mem.eql(u8, p.reason, warning.reason))
        {
            return true;
        }
    }
    return false;
}

/// RAII guard for reading the current scanner snapshot. The mutex is held
/// while the guard is live; call `release` (or let `deinit` run) to unlock.
pub const SnapshotGuard = struct {
    scanner: *Scanner,
    catalog: ?*Catalog,

    /// The current snapshot, or null if no successful scan has completed yet.
    pub fn get(self: SnapshotGuard) ?*Catalog {
        return self.catalog;
    }

    /// Release the mutex. Must be called exactly once when reading is done.
    pub fn release(self: *SnapshotGuard) void {
        self.scanner.mutex.unlock(self.scanner.io);
    }
};

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

// ---------------------------------------------------------------------------
// E2.S3: snapshot refresh, catalog JSON, and scanner lifecycle tests.
// ---------------------------------------------------------------------------

/// Test scan hook that returns canned `ScanResult`s so scanner behavior can be
/// exercised without touching the filesystem or waiting on real intervals.
const FakeScanSource = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    /// Index of the next canned result to return.
    next: usize = 0,
    /// Owned canned results, returned in order. Each result's entries/warnings
    /// are owned by the result and freed via `freeScanResult` after the scanner
    /// consumes them into a catalog.
    results: std.ArrayList(ScanResult) = .empty,
    /// Set when a scan is running so tests can assert non-overlap.
    in_progress: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Count of scans executed.
    scan_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Set true to make the next scan block until `release` is called.
    block_until_release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    released: std.Io.Condition = .init,

    fn deinit(self: *FakeScanSource) void {
        for (self.results.items) |r| freeScanResult(self.allocator, r);
        self.results.deinit(self.allocator);
    }

    fn scanFn(io: std.Io, allocator: std.mem.Allocator, root: []const u8) ScanError!ScanResult {
        _ = root;
        // The context is recovered via a module-level pointer since the scan
        // function signature does not carry user data.
        const self = fake_scan_state orelse return error.Unexpected;
        _ = io;
        _ = allocator;

        // Detect overlapping scans: in_progress must be false when we start.
        const prev = self.in_progress.swap(true, .acq_rel);
        if (prev) {
            // Overlap detected; this is a test failure condition.
            std.debug.panic("overlapping scan detected", .{});
        }
        _ = self.scan_count.fetchAdd(1, .monotonic);

        if (self.block_until_release.load(.acquire)) {
            // Wait until the test releases us; this simulates a slow scan.
            self.released.waitUncancelable(self.io, &overlap_mutex);
        }

        self.in_progress.store(false, .release);

        const idx = self.next;
        self.next += 1;
        if (idx >= self.results.items.len) return error.Unexpected;
        const canned = self.results.items[idx];
        // Hand back a duplicate-owned copy so the scanner can consume/free it.
        return dupeScanResult(self.allocator, canned) catch return error.OutOfMemory;
    }
};

/// Module-level pointer used by `FakeScanSource.scanFn` to recover the test
/// context, since the `ScanFn` signature carries no user data.
var fake_scan_state: ?*FakeScanSource = null;
var overlap_mutex: std.Io.Mutex = .init;

/// Duplicate a `ScanResult` into independently-owned entries and warnings so
/// each scan returns fresh allocations the scanner can free.
fn dupeScanResult(allocator: std.mem.Allocator, result: ScanResult) !ScanResult {
    var entries: std.ArrayList(CatalogEntry) = .empty;
    errdefer {
        for (entries.items) |e| {
            freeEntryMetadata(allocator, e);
            allocator.free(e.rel_path);
        }
        entries.deinit(allocator);
    }
    for (result.entries) |entry| {
        const rel = try allocator.dupe(u8, entry.rel_path);
        errdefer allocator.free(rel);
        var md: ArtifactMetadata = .{};
        if (entry.metadata.title) |s| md.title = try allocator.dupe(u8, s);
        if (entry.metadata.project) |s| md.project = try allocator.dupe(u8, s);
        if (entry.metadata.status) |s| md.status = try allocator.dupe(u8, s);
        if (entry.metadata.generated_at) |s| md.generated_at = try allocator.dupe(u8, s);
        if (entry.metadata.diagram_kind) |s| md.diagram_kind = try allocator.dupe(u8, s);
        try entries.append(allocator, .{
            .rel_path = rel,
            .kind = entry.kind,
            .size = entry.size,
            .mtime = entry.mtime,
            .metadata = md,
        });
    }

    var warnings: std.ArrayList(ScanWarning) = .empty;
    errdefer {
        for (warnings.items) |w| {
            allocator.free(w.rel_path);
            allocator.free(w.reason);
        }
        warnings.deinit(allocator);
    }
    for (result.warnings) |w| {
        const rel = try allocator.dupe(u8, w.rel_path);
        errdefer allocator.free(rel);
        const reason = try allocator.dupe(u8, w.reason);
        errdefer allocator.free(reason);
        try warnings.append(allocator, .{ .rel_path = rel, .reason = reason });
    }

    return .{
        .entries = try entries.toOwnedSlice(allocator),
        .warnings = try warnings.toOwnedSlice(allocator),
    };
}

/// Build a canned `ScanResult` with the given entries (no warnings).
fn cannedResult(allocator: std.mem.Allocator, entries: []const CatalogEntry) !ScanResult {
    var owned: std.ArrayList(CatalogEntry) = .empty;
    errdefer {
        for (owned.items) |e| {
            freeEntryMetadata(allocator, e);
            allocator.free(e.rel_path);
        }
        owned.deinit(allocator);
    }
    for (entries) |entry| {
        const rel = try allocator.dupe(u8, entry.rel_path);
        errdefer allocator.free(rel);
        var md: ArtifactMetadata = .{};
        if (entry.metadata.title) |s| md.title = try allocator.dupe(u8, s);
        if (entry.metadata.project) |s| md.project = try allocator.dupe(u8, s);
        if (entry.metadata.status) |s| md.status = try allocator.dupe(u8, s);
        if (entry.metadata.generated_at) |s| md.generated_at = try allocator.dupe(u8, s);
        if (entry.metadata.diagram_kind) |s| md.diagram_kind = try allocator.dupe(u8, s);
        try owned.append(allocator, .{
            .rel_path = rel,
            .kind = entry.kind,
            .size = entry.size,
            .mtime = entry.mtime,
            .metadata = md,
        });
    }
    return .{ .entries = try owned.toOwnedSlice(allocator), .warnings = &.{} };
}

fn freeCannedResult(allocator: std.mem.Allocator, result: ScanResult) void {
    freeScanResult(allocator, result);
}

/// Build a canned `ScanResult` with the given entries and warnings. Both
/// entries and warnings are duplicated into owned allocations.
fn cannedResultWithWarnings(
    allocator: std.mem.Allocator,
    entries: []const CatalogEntry,
    warnings: []const ScanWarning,
) !ScanResult {
    var result = try cannedResult(allocator, entries);
    var owned: std.ArrayList(ScanWarning) = .empty;
    errdefer {
        for (owned.items) |w| {
            allocator.free(w.rel_path);
            allocator.free(w.reason);
        }
        owned.deinit(allocator);
    }
    for (warnings) |w| {
        const rel = try allocator.dupe(u8, w.rel_path);
        errdefer allocator.free(rel);
        const reason = try allocator.dupe(u8, w.reason);
        errdefer allocator.free(reason);
        try owned.append(allocator, .{ .rel_path = rel, .reason = reason });
    }
    result.warnings = try owned.toOwnedSlice(allocator);
    return result;
}

test "buildCatalog sorts entries by group, kind, then rel_path" {
    const allocator = std.testing.allocator;
    // Deliberately unsorted input.
    const result = try cannedResult(allocator, &.{
        .{ .rel_path = "z/top.html", .kind = .plan, .size = 1, .mtime = .zero },
        .{ .rel_path = "a/sub/plan.html", .kind = .plan, .size = 1, .mtime = .zero, .metadata = .{ .project = "alpha" } },
        .{ .rel_path = "a/sub/map.html", .kind = .map, .size = 1, .mtime = .zero, .metadata = .{ .project = "alpha" } },
        .{ .rel_path = "a/plan.html", .kind = .plan, .size = 1, .mtime = .zero },
    });
    const catalog = try buildCatalog(allocator, result);
    defer catalog.deinit(allocator);

    // Expected: alpha/plan, alpha/map, a/plan, Ungrouped/z.
    try std.testing.expectEqualStrings("alpha", catalog.entries[0].group());
    try std.testing.expectEqual(ArtifactKind.plan, catalog.entries[0].kind);
    try std.testing.expectEqualStrings("a/sub/plan.html", catalog.entries[0].rel_path);

    try std.testing.expectEqualStrings("alpha", catalog.entries[1].group());
    try std.testing.expectEqual(ArtifactKind.map, catalog.entries[1].kind);
    try std.testing.expectEqualStrings("a/sub/map.html", catalog.entries[1].rel_path);

    try std.testing.expectEqualStrings("a", catalog.entries[2].group());
    try std.testing.expectEqualStrings("a/plan.html", catalog.entries[2].rel_path);

    try std.testing.expectEqualStrings("Ungrouped", catalog.entries[3].group());
    try std.testing.expectEqualStrings("z/top.html", catalog.entries[3].rel_path);
}

test "writeCatalogJson produces sorted JSON with no absolute paths" {
    const allocator = std.testing.allocator;
    const result = try cannedResult(allocator, &.{
        .{ .rel_path = "proj/plan.html", .kind = .plan, .size = 4096, .mtime = .{ .nanoseconds = 1753000000000000000 }, .metadata = .{ .title = "Plan One", .project = "proj", .status = "planned", .generated_at = "2026-07-24T00:00:00Z" } },
        .{ .rel_path = "proj/map.html", .kind = .map, .size = 8192, .mtime = .{ .nanoseconds = 1753000000000000001 }, .metadata = .{ .title = "Map One", .project = "proj", .diagram_kind = "class" } },
    });
    const catalog = try buildCatalog(allocator, result);
    defer catalog.deinit(allocator);

    const json = try catalogJsonAlloc(allocator, catalog);
    defer allocator.free(json);

    // No absolute filesystem paths appear (the temp root never leaks).
    try std.testing.expect(std.mem.indexOf(u8, json, "/tmp/") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/Users/") == null);

    // Deterministic ordering: plan before map within the project.
    const plan_pos = std.mem.indexOf(u8, json, "plan.html").?;
    const map_pos = std.mem.indexOf(u8, json, "map.html").?;
    try std.testing.expect(plan_pos < map_pos);

    // Required fields present.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"projects\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"proj\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"plan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"map\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"diagramKind\":\"class\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"generatedAt\":\"2026-07-24T00:00:00Z\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"warnings\":[]") != null);
    // Stable catalog-safe URL is emitted for each artifact.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"url\":\"/artifacts/proj/plan.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"url\":\"/artifacts/proj/map.html\"") != null);
}

test "writeCatalogJson emits a valid empty projects shape" {
    const allocator = std.testing.allocator;
    const result = try cannedResult(allocator, &.{});
    const catalog = try buildCatalog(allocator, result);
    defer catalog.deinit(allocator);

    const json = try catalogJsonAlloc(allocator, catalog);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"Ungrouped\",\"artifacts\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"warnings\":[]") != null);
}

test "writeCatalogJson omits absent optional metadata" {
    const allocator = std.testing.allocator;
    const result = try cannedResult(allocator, &.{
        .{ .rel_path = "x/plan.html", .kind = .plan, .size = 1, .mtime = .zero },
    });
    const catalog = try buildCatalog(allocator, result);
    defer catalog.deinit(allocator);

    const json = try catalogJsonAlloc(allocator, catalog);
    defer allocator.free(json);
    // title falls back to filename stem, but project/status/generatedAt/diagramKind absent.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"title\":\"plan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"project\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"generatedAt\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"diagramKind\"") == null);
}

test "Catalog.findEntry locates recognized artifacts and rejects others" {
    const allocator = std.testing.allocator;
    const result = try cannedResult(allocator, &.{
        .{ .rel_path = "proj/plan.html", .kind = .plan, .size = 1, .mtime = .zero },
        .{ .rel_path = "proj/map.html", .kind = .map, .size = 1, .mtime = .zero },
        .{ .rel_path = "other/x.html", .kind = .plan, .size = 1, .mtime = .zero },
    });
    const catalog = try buildCatalog(allocator, result);
    defer catalog.deinit(allocator);

    try std.testing.expect(catalog.findEntry("proj/plan.html") != null);
    try std.testing.expect(catalog.findEntry("proj/map.html") != null);
    try std.testing.expect(catalog.findEntry("other/x.html") != null);
    // Non-catalog paths return null even if they look plausible.
    try std.testing.expect(catalog.findEntry("plain.html") == null);
    try std.testing.expect(catalog.findEntry("proj/missing.html") == null);
    try std.testing.expect(catalog.findEntry("") == null);
    try std.testing.expect(catalog.findEntry("../escape.html") == null);
}

test "scanner publishes initial catalog before start" {
    const allocator = std.testing.allocator;
    var source: FakeScanSource = .{ .io = std.testing.io, .allocator = allocator };
    defer source.deinit();
    fake_scan_state = &source;
    defer fake_scan_state = null;

    const r0 = try cannedResult(allocator, &.{
        .{ .rel_path = "a/plan.html", .kind = .plan, .size = 1, .mtime = .zero },
    });
    try source.results.append(allocator, r0);

    var scanner = Scanner.init(std.testing.io, allocator, "/tmp/test", 1, FakeScanSource.scanFn);
    scanner.initialScan();
    defer scanner.stop();

    var guard = scanner.snapshotLock();
    defer guard.release();
    const catalog = guard.get() orelse return error.NoCatalog;
    try std.testing.expectEqual(@as(usize, 1), catalog.entries.len);
    try std.testing.expectEqualStrings("a/plan.html", catalog.entries[0].rel_path);
}

test "scanner reflects added, changed, and deleted artifacts across scans" {
    const allocator = std.testing.allocator;
    var source: FakeScanSource = .{ .io = std.testing.io, .allocator = allocator };
    defer source.deinit();
    fake_scan_state = &source;
    defer fake_scan_state = null;

    // Initial: one plan.
    const r0 = try cannedResult(allocator, &.{
        .{ .rel_path = "p/a.html", .kind = .plan, .size = 10, .mtime = .zero, .metadata = .{ .title = "A" } },
    });
    try source.results.append(allocator, r0);
    // After first refresh: add a map, keep the plan (changed size).
    const r1 = try cannedResult(allocator, &.{
        .{ .rel_path = "p/a.html", .kind = .plan, .size = 99, .mtime = .zero, .metadata = .{ .title = "A" } },
        .{ .rel_path = "p/b.html", .kind = .map, .size = 20, .mtime = .zero, .metadata = .{ .title = "B" } },
    });
    try source.results.append(allocator, r1);
    // After second refresh: delete the plan, keep the map.
    const r2 = try cannedResult(allocator, &.{
        .{ .rel_path = "p/b.html", .kind = .map, .size = 20, .mtime = .zero, .metadata = .{ .title = "B" } },
    });
    try source.results.append(allocator, r2);

    var scanner = Scanner.init(std.testing.io, allocator, "/tmp/test", 1, FakeScanSource.scanFn);
    scanner.initialScan();
    defer scanner.stop();

    // Initial: one entry.
    {
        var guard = scanner.snapshotLock();
        defer guard.release();
        const catalog = guard.get().?;
        try std.testing.expectEqual(@as(usize, 1), catalog.entries.len);
        try std.testing.expectEqual(@as(u64, 10), catalog.entries[0].size);
    }

    // After first manual refresh: two entries, plan size updated, map added.
    scanner.runScan();
    {
        var guard = scanner.snapshotLock();
        defer guard.release();
        const catalog = guard.get().?;
        try std.testing.expectEqual(@as(usize, 2), catalog.entries.len);
        // plan before map within same group.
        try std.testing.expectEqual(ArtifactKind.plan, catalog.entries[0].kind);
        try std.testing.expectEqual(@as(u64, 99), catalog.entries[0].size);
        try std.testing.expectEqual(ArtifactKind.map, catalog.entries[1].kind);
    }

    // After second manual refresh: plan deleted, only map remains.
    scanner.runScan();
    {
        var guard = scanner.snapshotLock();
        defer guard.release();
        const catalog = guard.get().?;
        try std.testing.expectEqual(@as(usize, 1), catalog.entries.len);
        try std.testing.expectEqual(ArtifactKind.map, catalog.entries[0].kind);
    }
}

test "scanner keeps prior catalog when a scan fails" {
    const allocator = std.testing.allocator;
    var source: FakeScanSource = .{ .io = std.testing.io, .allocator = allocator };
    defer source.deinit();
    fake_scan_state = &source;
    defer fake_scan_state = null;

    const r0 = try cannedResult(allocator, &.{
        .{ .rel_path = "p/a.html", .kind = .plan, .size = 1, .mtime = .zero },
    });
    try source.results.append(allocator, r0);
    // The next scan will run past the canned results and return error.Unexpected.
    var scanner = Scanner.init(std.testing.io, allocator, "/tmp/test", 1, FakeScanSource.scanFn);
    scanner.initialScan();
    defer scanner.stop();

    // Force a failing scan by running past the canned list.
    scanner.runScan();
    try std.testing.expect(scanner.last_scan_failed);

    // Prior catalog still available.
    var guard = scanner.snapshotLock();
    defer guard.release();
    const catalog = guard.get().?;
    try std.testing.expectEqual(@as(usize, 1), catalog.entries.len);
}

test "scanner does not overlap slow scans" {
    const allocator = std.testing.allocator;
    var source: FakeScanSource = .{ .io = std.testing.io, .allocator = allocator };
    defer source.deinit();
    fake_scan_state = &source;
    defer fake_scan_state = null;

    const r0 = try cannedResult(allocator, &.{
        .{ .rel_path = "p/a.html", .kind = .plan, .size = 1, .mtime = .zero },
    });
    try source.results.append(allocator, r0);
    // Provide a second result for the worker to consume after release.
    const r1 = try cannedResult(allocator, &.{
        .{ .rel_path = "p/a.html", .kind = .plan, .size = 2, .mtime = .zero },
    });
    try source.results.append(allocator, r1);

    var scanner = Scanner.init(std.testing.io, allocator, "/tmp/test", 1, FakeScanSource.scanFn);
    scanner.initialScan();
    defer scanner.stop();

    // Block the next scan so it appears "slow" and in-progress.
    source.block_until_release.store(true, .release);

    // Start the worker. It will sleep a short interval then enter a blocked scan.
    try scanner.start();

    // Wait until the slow scan is in progress (scan_count >= 2 means worker ran).
    // Use a bounded spin so the test does not hang forever.
    var waited: usize = 0;
    while (source.scan_count.load(.monotonic) < 2 and waited < 1000) : (waited += 1) {
        std.Thread.yield() catch {};
    }
    try std.testing.expect(source.in_progress.load(.acquire));

    // Releasing the blocked scan lets the worker finish without overlap.
    source.released.broadcast(std.testing.io);
    scanner.stop();

    // If overlap had occurred, the scan hook would have panicked above.
    try std.testing.expect(source.scan_count.load(.monotonic) >= 2);
}

test "scanner stop joins the worker and releases the snapshot" {
    const allocator = std.testing.allocator;
    var source: FakeScanSource = .{ .io = std.testing.io, .allocator = allocator };
    defer source.deinit();
    fake_scan_state = &source;
    defer fake_scan_state = null;

    const r0 = try cannedResult(allocator, &.{
        .{ .rel_path = "p/a.html", .kind = .plan, .size = 1, .mtime = .zero },
    });
    try source.results.append(allocator, r0);

    var scanner = Scanner.init(std.testing.io, allocator, "/tmp/test", 1, FakeScanSource.scanFn);
    scanner.initialScan();
    try scanner.start();
    scanner.stop();

    // After stop, current is null and the thread handle is cleared.
    try std.testing.expect(scanner.current == null);
    try std.testing.expect(scanner.thread == null);
}

// ---------------------------------------------------------------------------
// E5.S1: scanner diagnostics — warning dedup, failure, and recovery.
// ---------------------------------------------------------------------------

/// Test harness capturing scanner diagnostics into a fixed buffer so tests
/// can assert on the exact stderr output without touching real streams.
const DiagCapture = struct {
    buffer: [4096]u8 = undefined,
    writer: std.Io.Writer = .{ .context = undefined },

    fn init() DiagCapture {
        var cap: DiagCapture = .{};
        cap.writer = .fixed(&cap.buffer);
        return cap;
    }

    fn written(self: *const DiagCapture) []const u8 {
        return self.buffer[0..self.writer.end];
    }
};

test "scanner reports new warnings on first successful scan" {
    const allocator = std.testing.allocator;
    var source: FakeScanSource = .{ .io = std.testing.io, .allocator = allocator };
    defer source.deinit();
    fake_scan_state = &source;
    defer fake_scan_state = null;

    const r0 = try cannedResultWithWarnings(allocator, &.{
        .{ .rel_path = "p/a.html", .kind = .plan, .size = 1, .mtime = .zero },
    }, &.{
        .{ .rel_path = "bad.html", .reason = "malformed json metadata" },
    });
    try source.results.append(allocator, r0);

    var cap = DiagCapture.init();
    var scanner = Scanner.init(std.testing.io, allocator, "/tmp/test", 1, FakeScanSource.scanFn);
    scanner.enableDiagnostics(&cap.writer);
    scanner.initialScan();
    defer scanner.stop();

    const out = cap.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "matcha serve: warning: bad.html: malformed json metadata") != null);
}

test "scanner deduplicates unchanged warnings across scans" {
    const allocator = std.testing.allocator;
    var source: FakeScanSource = .{ .io = std.testing.io, .allocator = allocator };
    defer source.deinit();
    fake_scan_state = &source;
    defer fake_scan_state = null;

    // First scan: one warning.
    const r0 = try cannedResultWithWarnings(allocator, &.{
        .{ .rel_path = "p/a.html", .kind = .plan, .size = 1, .mtime = .zero },
    }, &.{
        .{ .rel_path = "bad.html", .reason = "malformed json metadata" },
    });
    try source.results.append(allocator, r0);
    // Second scan: same warning (unchanged).
    const r1 = try cannedResultWithWarnings(allocator, &.{
        .{ .rel_path = "p/a.html", .kind = .plan, .size = 1, .mtime = .zero },
    }, &.{
        .{ .rel_path = "bad.html", .reason = "malformed json metadata" },
    });
    try source.results.append(allocator, r1);

    var cap = DiagCapture.init();
    var scanner = Scanner.init(std.testing.io, allocator, "/tmp/test", 1, FakeScanSource.scanFn);
    scanner.enableDiagnostics(&cap.writer);
    scanner.initialScan();
    defer scanner.stop();

    const after_first = cap.writer.end;
    scanner.runScan();
    const after_second = cap.writer.end;

    // The second scan must not re-emit the same warning.
    const second_output = cap.buffer[after_first..after_second];
    try std.testing.expectEqual(@as(usize, 0), second_output.len);
}

test "scanner reports a warning that changes reason" {
    const allocator = std.testing.allocator;
    var source: FakeScanSource = .{ .io = std.testing.io, .allocator = allocator };
    defer source.deinit();
    fake_scan_state = &source;
    defer fake_scan_state = null;

    const r0 = try cannedResultWithWarnings(allocator, &.{
        .{ .rel_path = "p/a.html", .kind = .plan, .size = 1, .mtime = .zero },
    }, &.{
        .{ .rel_path = "bad.html", .reason = "malformed json metadata" },
    });
    try source.results.append(allocator, r0);
    const r1 = try cannedResultWithWarnings(allocator, &.{
        .{ .rel_path = "p/a.html", .kind = .plan, .size = 1, .mtime = .zero },
    }, &.{
        .{ .rel_path = "bad.html", .reason = "missing closing script tag" },
    });
    try source.results.append(allocator, r1);

    var cap = DiagCapture.init();
    var scanner = Scanner.init(std.testing.io, allocator, "/tmp/test", 1, FakeScanSource.scanFn);
    scanner.enableDiagnostics(&cap.writer);
    scanner.initialScan();
    defer scanner.stop();

    const after_first = cap.writer.end;
    scanner.runScan();
    const second_output = cap.buffer[after_first..cap.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, second_output, "missing closing script tag") != null);
}

test "scanner reports a warning that reappears after disappearing" {
    const allocator = std.testing.allocator;
    var source: FakeScanSource = .{ .io = std.testing.io, .allocator = allocator };
    defer source.deinit();
    fake_scan_state = &source;
    defer fake_scan_state = null;

    // Scan 0: warning present.
    const r0 = try cannedResultWithWarnings(allocator, &.{
        .{ .rel_path = "p/a.html", .kind = .plan, .size = 1, .mtime = .zero },
    }, &.{
        .{ .rel_path = "bad.html", .reason = "malformed json metadata" },
    });
    try source.results.append(allocator, r0);
    // Scan 1: warning gone.
    const r1 = try cannedResultWithWarnings(allocator, &.{
        .{ .rel_path = "p/a.html", .kind = .plan, .size = 1, .mtime = .zero },
    }, &.{});
    try source.results.append(allocator, r1);
    // Scan 2: warning reappears.
    const r2 = try cannedResultWithWarnings(allocator, &.{
        .{ .rel_path = "p/a.html", .kind = .plan, .size = 1, .mtime = .zero },
    }, &.{
        .{ .rel_path = "bad.html", .reason = "malformed json metadata" },
    });
    try source.results.append(allocator, r2);

    var cap = DiagCapture.init();
    var scanner = Scanner.init(std.testing.io, allocator, "/tmp/test", 1, FakeScanSource.scanFn);
    scanner.enableDiagnostics(&cap.writer);
    scanner.initialScan();
    defer scanner.stop();

    const after_first = cap.writer.end;
    scanner.runScan(); // warning disappears
    const after_second = cap.writer.end;
    scanner.runScan(); // warning reappears
    const after_third = cap.writer.end;

    // The disappearing scan emits nothing; the reappearing scan re-emits.
    try std.testing.expectEqual(@as(usize, 0), cap.buffer[after_first..after_second].len);
    const third = cap.buffer[after_second..after_third];
    try std.testing.expect(std.mem.indexOf(u8, third, "warning: bad.html: malformed json metadata") != null);
}

test "scanner reports scan failure once and recovery once" {
    const allocator = std.testing.allocator;
    var source: FakeScanSource = .{ .io = std.testing.io, .allocator = allocator };
    defer source.deinit();
    fake_scan_state = &source;
    defer fake_scan_state = null;

    // Scan 0: success.
    const r0 = try cannedResult(allocator, &.{
        .{ .rel_path = "p/a.html", .kind = .plan, .size = 1, .mtime = .zero },
    });
    try source.results.append(allocator, r0);
    // Scans 1 and 2: failure (run past canned list returns error.Unexpected).
    // Scan 3: success (we add one more canned result).
    const r3 = try cannedResult(allocator, &.{
        .{ .rel_path = "p/a.html", .kind = .plan, .size = 2, .mtime = .zero },
    });
    try source.results.append(allocator, r3);

    var cap = DiagCapture.init();
    var scanner = Scanner.init(std.testing.io, allocator, "/tmp/test", 1, FakeScanSource.scanFn);
    scanner.enableDiagnostics(&cap.writer);
    scanner.initialScan();
    defer scanner.stop();

    const after_initial = cap.writer.end;
    scanner.runScan(); // first failure
    const after_first_failure = cap.writer.end;
    scanner.runScan(); // second failure (no new output)
    const after_second_failure = cap.writer.end;
    scanner.runScan(); // recovery
    const after_recovery = cap.writer.end;

    // First failure is reported.
    const failure_out = cap.buffer[after_initial..after_first_failure];
    try std.testing.expect(std.mem.indexOf(u8, failure_out, "matcha serve: scan failed") != null);
    // Second failure is silent (dedup).
    try std.testing.expectEqual(@as(usize, 0), cap.buffer[after_first_failure..after_second_failure].len);
    // Recovery is reported.
    const recovery_out = cap.buffer[after_second_failure..after_recovery];
    try std.testing.expect(std.mem.indexOf(u8, recovery_out, "matcha serve: scan recovered") != null);
}

test "scanner keeps prior catalog on scan failure and recovers automatically" {
    const allocator = std.testing.allocator;
    var source: FakeScanSource = .{ .io = std.testing.io, .allocator = allocator };
    defer source.deinit();
    fake_scan_state = &source;
    defer fake_scan_state = null;

    const r0 = try cannedResult(allocator, &.{
        .{ .rel_path = "p/a.html", .kind = .plan, .size = 1, .mtime = .zero },
    });
    try source.results.append(allocator, r0);
    // Recovery scan with a new size.
    const r1 = try cannedResult(allocator, &.{
        .{ .rel_path = "p/a.html", .kind = .plan, .size = 42, .mtime = .zero },
    });
    try source.results.append(allocator, r1);

    var cap = DiagCapture.init();
    var scanner = Scanner.init(std.testing.io, allocator, "/tmp/test", 1, FakeScanSource.scanFn);
    scanner.enableDiagnostics(&cap.writer);
    scanner.initialScan();
    defer scanner.stop();

    // Force a failing scan by running past the canned list.
    scanner.runScan();
    try std.testing.expect(scanner.last_scan_failed);

    // Prior catalog still available.
    {
        var guard = scanner.snapshotLock();
        defer guard.release();
        const catalog = guard.get().?;
        try std.testing.expectEqual(@as(usize, 1), catalog.entries.len);
    }

    // Recovery scan replaces the catalog.
    scanner.runScan();
    try std.testing.expect(!scanner.last_scan_failed);
    {
        var guard = scanner.snapshotLock();
        defer guard.release();
        const catalog = guard.get().?;
        try std.testing.expectEqual(@as(u64, 42), catalog.entries[0].size);
    }
}

test "scanner diagnostics never print embedded document contents" {
    const allocator = std.testing.allocator;
    var source: FakeScanSource = .{ .io = std.testing.io, .allocator = allocator };
    defer source.deinit();
    fake_scan_state = &source;
    defer fake_scan_state = null;

    // Warning reason is a short diagnostic string, never the file contents.
    const r0 = try cannedResultWithWarnings(allocator, &.{
        .{ .rel_path = "p/a.html", .kind = .plan, .size = 1, .mtime = .zero },
    }, &.{
        .{ .rel_path = "bad.html", .reason = "malformed json metadata" },
    });
    try source.results.append(allocator, r0);

    var cap = DiagCapture.init();
    var scanner = Scanner.init(std.testing.io, allocator, "/tmp/test", 1, FakeScanSource.scanFn);
    scanner.enableDiagnostics(&cap.writer);
    scanner.initialScan();
    defer scanner.stop();

    const out = cap.written();
    // Diagnostic must not contain the absolute root.
    try std.testing.expect(std.mem.indexOf(u8, out, "/tmp/test") == null);
    // Diagnostic must not contain a JSON object body from an embedded doc.
    try std.testing.expect(std.mem.indexOf(u8, out, "{\"title\"") == null);
}
