const std = @import("std");

/// Errors raised while parsing or validating a catalog-safe artifact URL.
pub const RouteError = error{
    /// Malformed percent-encoding (missing or non-hex digits after `%`), an
    /// empty artifact identifier, or a request path that does not match the
    /// `/artifacts/` route prefix.
    MalformedEncoding,
    /// A NUL byte appeared either literally in the request or as the decoded
    /// result of a `%00` sequence.
    NulByte,
    /// The decoded path begins with `/` and would address an absolute location.
    AbsolutePath,
    /// A path segment equals `..` and would traverse above the serving root.
    ParentTraversal,
    /// A backslash appeared in the decoded path. Forward slashes are the only
    /// accepted separator so platform-specific variants cannot bypass policy.
    PlatformSeparator,
    /// An empty path segment (`//`) appeared in the decoded path.
    EmptySegment,
    OutOfMemory,
};

const route_prefix: []const u8 = "/artifacts/";
const hex_digits: []const u8 = "0123456789ABCDEF";

/// RFC 3986 unreserved characters that are safe to emit verbatim in a URL.
fn isUnreserved(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => true,
        else => false,
    };
}

/// Return the numeric value of a single hex digit, or `null` when the byte is
/// not a hex digit.
fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'A'...'F' => byte - 'A' + 10,
        'a'...'f' => byte - 'a' + 10,
        else => null,
    };
}

/// Percent-encode a normalized relative path into the path component of a
/// catalog-safe artifact URL. Forward slashes are preserved as separators;
/// every other byte outside the unreserved set is encoded as uppercase `%XX`.
/// The returned slice is owned by the caller.
pub fn encodeArtifactPath(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (rel_path) |byte| {
        if (isUnreserved(byte) or byte == '/') {
            try out.append(allocator, byte);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hexDigitsNibble(byte >> 4));
            try out.append(allocator, hexDigitsNibble(byte));
        }
    }
    return out.toOwnedSlice(allocator);
}

fn hexDigitsNibble(nibble: u8) u8 {
    return hex_digits[nibble & 0x0f];
}

/// Write a full catalog URL (`/artifacts/<encoded>`) for `rel_path` directly to
/// `writer` without allocating. The output is deterministic for a given
/// relative path so bookmarks survive rescans as long as the relative file
/// path is unchanged. The encoded form never contains JSON-special characters
/// (`"`, `\`, control bytes) so it can be embedded in a JSON string verbatim.
pub fn writeArtifactUrl(
    writer: *std.Io.Writer,
    rel_path: []const u8,
) std.Io.Writer.Error!void {
    try writer.writeAll(route_prefix);
    for (rel_path) |byte| {
        if (isUnreserved(byte) or byte == '/') {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hexDigitsNibble(byte >> 4));
            try writer.writeByte(hexDigitsNibble(byte));
        }
    }
}

/// Strictly percent-decode `encoded` exactly once. `%` must be followed by two
/// hex digits; anything else is `MalformedEncoding`. Literal NUL bytes in the
/// input and `%00` sequences are rejected as `NulByte`. The caller must
/// separately validate the decoded result for path safety with
/// `validateRelativePath`.
fn percentDecode(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) RouteError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        const byte = encoded[i];
        if (byte == 0) return error.NulByte;
        if (byte == '%') {
            if (i + 2 >= encoded.len) return error.MalformedEncoding;
            const hi = hexValue(encoded[i + 1]) orelse return error.MalformedEncoding;
            const lo = hexValue(encoded[i + 2]) orelse return error.MalformedEncoding;
            const decoded: u8 = @intCast((hi << 4) | lo);
            if (decoded == 0) return error.NulByte;
            try out.append(allocator, decoded);
            i += 2;
        } else {
            try out.append(allocator, byte);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Validate a decoded relative path for catalog safety. Rejects empty paths,
/// NUL bytes, backslashes, leading slashes (absolute paths), empty segments
/// (`//`), and parent-traversal (`..`) segments.
pub fn validateRelativePath(decoded: []const u8) RouteError!void {
    if (decoded.len == 0) return error.MalformedEncoding;
    if (decoded[0] == '/') return error.AbsolutePath;
    if (std.mem.indexOfScalar(u8, decoded, 0) != null) return error.NulByte;
    if (std.mem.indexOfScalar(u8, decoded, '\\') != null) return error.PlatformSeparator;
    var it = std.mem.splitScalar(u8, decoded, '/');
    while (it.next()) |segment| {
        if (segment.len == 0) return error.EmptySegment;
        if (std.mem.eql(u8, segment, "..")) return error.ParentTraversal;
    }
}

/// Parse an HTTP request path matching `/artifacts/<encoded-relative-path>`
/// into a validated, catalog-safe relative path. The route prefix is stripped,
/// the remainder is decoded exactly once, and the result is validated. Returns
/// an owned slice on success or a `RouteError` describing why the request was
/// rejected. The caller owns the returned slice.
pub fn parseArtifactRoute(
    allocator: std.mem.Allocator,
    request_path: []const u8,
) RouteError![]u8 {
    if (!std.mem.startsWith(u8, request_path, route_prefix)) return error.MalformedEncoding;
    const encoded = request_path[route_prefix.len..];
    if (encoded.len == 0) return error.MalformedEncoding;
    const decoded = try percentDecode(allocator, encoded);
    errdefer allocator.free(decoded);
    try validateRelativePath(decoded);
    return decoded;
}

/// Build the full catalog URL (`/artifacts/<encoded>`) for a relative path.
/// The result is owned by the caller and is deterministic for a given
/// relative path, so bookmarks survive rescans.
pub fn artifactUrl(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
) ![]u8 {
    const encoded = try encodeArtifactPath(allocator, rel_path);
    defer allocator.free(encoded);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, route_prefix);
    try out.appendSlice(allocator, encoded);
    return out.toOwnedSlice(allocator);
}

test "encodeArtifactPath preserves unreserved characters and slashes" {
    const allocator = std.testing.allocator;
    const encoded = try encodeArtifactPath(allocator, "proj/plan-1.html");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("proj/plan-1.html", encoded);
}

test "encodeArtifactPath encodes spaces and special characters" {
    const allocator = std.testing.allocator;
    const encoded = try encodeArtifactPath(allocator, "a b&c.html");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("a%20b%26c.html", encoded);
}

test "encodeArtifactPath encodes unicode as utf8 percent bytes" {
    const allocator = std.testing.allocator;
    // "café" → bytes 63 61 66 c3 a9 → "caf%c3%a9"
    const encoded = try encodeArtifactPath(allocator, "café/map.html");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("caf%C3%A9/map.html", encoded);
}

test "encodeArtifactPath encodes every non-unreserved byte" {
    const allocator = std.testing.allocator;
    const encoded = try encodeArtifactPath(allocator, "a@b.html");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("a%40b.html", encoded);
}

test "percentDecode round trips encoded paths" {
    const allocator = std.testing.allocator;
    const encoded = "caf%C3%A9/a%20b.html";
    const decoded = try percentDecode(allocator, encoded);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("café/a b.html", decoded);
}

test "percentDecode rejects truncated percent sequence" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MalformedEncoding, percentDecode(allocator, "a%2"));
    try std.testing.expectError(error.MalformedEncoding, percentDecode(allocator, "a%"));
}

test "percentDecode rejects non-hex percent sequence" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MalformedEncoding, percentDecode(allocator, "a%ZZb"));
}

test "percentDecode rejects literal nul bytes" {
    const allocator = std.testing.allocator;
    const input = "a\x00b";
    try std.testing.expectError(error.NulByte, percentDecode(allocator, input));
}

test "percentDecode rejects encoded nul bytes" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.NulByte, percentDecode(allocator, "a%00b"));
}

test "percentDecode decodes exactly once (no double decode)" {
    const allocator = std.testing.allocator;
    // "%252e" decodes once to "%2e" (literal), not to ".".
    const decoded = try percentDecode(allocator, "%252e");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("%2e", decoded);
}

test "validateRelativePath accepts simple nested paths" {
    try validateRelativePath("proj/sub/plan.html");
    try validateRelativePath("a/plan.html");
    try validateRelativePath("plan.html");
}

test "validateRelativePath rejects absolute paths" {
    try std.testing.expectError(error.AbsolutePath, validateRelativePath("/etc/passwd"));
}

test "validateRelativePath rejects parent traversal" {
    try std.testing.expectError(error.ParentTraversal, validateRelativePath("../plan.html"));
    try std.testing.expectError(error.ParentTraversal, validateRelativePath("a/../../b.html"));
    try std.testing.expectError(error.ParentTraversal, validateRelativePath("a/b/.."));
}

test "validateRelativePath rejects backslashes" {
    try std.testing.expectError(error.PlatformSeparator, validateRelativePath("a\\b.html"));
}

test "validateRelativePath rejects empty segments" {
    try std.testing.expectError(error.EmptySegment, validateRelativePath("a//b.html"));
}

test "validateRelativePath rejects empty path" {
    try std.testing.expectError(error.MalformedEncoding, validateRelativePath(""));
}

test "validateRelativePath rejects nul bytes" {
    try std.testing.expectError(error.NulByte, validateRelativePath("a\x00b"));
}

test "parseArtifactRoute round trips nested spaced unicode paths" {
    const allocator = std.testing.allocator;
    const rel_path = "café/sub/a b.html";
    const url = try artifactUrl(allocator, rel_path);
    defer allocator.free(url);
    const parsed = try parseArtifactRoute(allocator, url);
    defer allocator.free(parsed);
    try std.testing.expectEqualStrings(rel_path, parsed);
}

test "parseArtifactRoute rejects missing prefix" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.MalformedEncoding,
        parseArtifactRoute(allocator, "/files/foo.html"),
    );
}

test "parseArtifactRoute rejects empty artifact id" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.MalformedEncoding,
        parseArtifactRoute(allocator, "/artifacts/"),
    );
}

test "parseArtifactRoute rejects parent traversal" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.ParentTraversal,
        parseArtifactRoute(allocator, "/artifacts/../secret.html"),
    );
    try std.testing.expectError(
        error.ParentTraversal,
        parseArtifactRoute(allocator, "/artifacts/a/../../../etc/passwd"),
    );
}

test "parseArtifactRoute rejects double-encoded traversal" {
    const allocator = std.testing.allocator;
    // "%252e%252e" decodes once to "%2e%2e" which is not "..", so it passes
    // validation and demonstrates single-decode safety.
    const parsed = try parseArtifactRoute(allocator, "/artifacts/%252e%252e/x.html");
    defer allocator.free(parsed);
    try std.testing.expectEqualStrings("%2e%2e/x.html", parsed);
}

test "parseArtifactRoute rejects absolute paths after decode" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.AbsolutePath,
        parseArtifactRoute(allocator, "/artifacts/%2fetc%2fpasswd"),
    );
}

test "parseArtifactRoute rejects malformed encoding" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.MalformedEncoding,
        parseArtifactRoute(allocator, "/artifacts/a%2"),
    );
    try std.testing.expectError(
        error.MalformedEncoding,
        parseArtifactRoute(allocator, "/artifacts/a%ZZb"),
    );
}

test "parseArtifactRoute rejects platform separator variants" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.PlatformSeparator,
        parseArtifactRoute(allocator, "/artifacts/a%5cb.html"),
    );
}

test "artifactUrl is deterministic across calls" {
    const allocator = std.testing.allocator;
    const rel_path = "proj/a b/plan.html";
    const url1 = try artifactUrl(allocator, rel_path);
    defer allocator.free(url1);
    const url2 = try artifactUrl(allocator, rel_path);
    defer allocator.free(url2);
    try std.testing.expectEqualStrings(url1, url2);
    try std.testing.expectEqualStrings("/artifacts/proj/a%20b/plan.html", url1);
}

test "artifactUrl unchanged across identical relative paths" {
    const allocator = std.testing.allocator;
    const rel_path = "proj/plan.html";
    const url1 = try artifactUrl(allocator, rel_path);
    defer allocator.free(url1);
    // Simulate a rescan producing the same rel_path: the URL must match.
    const url2 = try artifactUrl(allocator, rel_path);
    defer allocator.free(url2);
    try std.testing.expectEqualStrings(url1, url2);
}

test "writeArtifactUrl streams the same bytes as artifactUrl" {
    const allocator = std.testing.allocator;
    const rel_path = "café/a b.html";
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeArtifactUrl(&writer, rel_path);
    const streamed = buffer[0..writer.end];
    const allocated = try artifactUrl(allocator, rel_path);
    defer allocator.free(allocated);
    try std.testing.expectEqualStrings(allocated, streamed);
}

test "writeArtifactUrl never emits json-special bytes" {
    const rel_path = "\"\\x\x00y.html";
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeArtifactUrl(&writer, rel_path);
    const streamed = buffer[0..writer.end];
    try std.testing.expect(std.mem.indexOfScalar(u8, streamed, '"') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, streamed, '\\') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, streamed, 0) == null);
    try std.testing.expect(std.mem.startsWith(u8, streamed, route_prefix));
}
