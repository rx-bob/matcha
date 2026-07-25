const std = @import("std");

const assets = @import("assets.zig");
const serve_options = @import("serve_options.zig");
const serve_catalog = @import("serve_catalog.zig");
const serve_routes = @import("serve_routes.zig");

const net = std.Io.net;

/// Listen socket file descriptor shared with the signal handler so SIGINT and
/// SIGTERM can close the listener and unblock the accept loop. Set once after
/// binding and cleared on shutdown.
var listen_fd: std.posix.fd_t = -1;

extern "c" fn close(fd: std.posix.fd_t) c_int;

fn signalHandler(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    const fd = listen_fd;
    if (fd != -1) {
        listen_fd = -1;
        _ = close(fd);
    }
}

fn installShutdownHandler() void {
    const handler: std.posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = 0,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &handler, null);
    std.posix.sigaction(std.posix.SIG.TERM, &handler, null);
}

/// Run the read-only HTTP server until the listener is closed or a fatal
/// request-handling error occurs.
///
/// The server binds to `options.host`:`options.port` (port 0 selects an
/// ephemeral loopback port for tests) and serves a deterministic minimal HTML
/// index at `/`. Unknown routes return 404 and non-GET methods return 405.
/// Request parsing is bounded by a fixed buffer so malformed or oversized
/// requests are rejected without unbounded buffering.
pub fn run(
    io: std.Io,
    options: serve_options.ServeOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !serve_options.ExitCode {
    const address = resolveAddress(options.host, options.port) catch |err| {
        try stderr.print("matcha serve: cannot resolve {s}: {s}\n", .{
            options.host,
            @errorName(err),
        });
        return .failure;
    };

    var server = net.IpAddress.listen(&address, io, .{ .reuse_address = true }) catch |err| {
        try stderr.print("matcha serve: cannot bind {s}:{d}: {s}\n", .{
            options.host,
            options.port,
            @errorName(err),
        });
        return .failure;
    };
    defer server.deinit(io);

    // Build the catalog scanner and run the initial scan synchronously so the
    // catalog is available before the server reports readiness. The worker
    // thread refreshes the snapshot on the configured interval. Diagnostics
    // are wired to stderr so scan warnings, failure, and recovery reach the
    // operator without flooding output.
    var scanner = serve_catalog.Scanner.init(
        io,
        std.heap.page_allocator,
        options.directory,
        options.interval_seconds,
        serve_catalog.scan,
    );
    scanner.enableDiagnostics(stderr);
    scanner.initialScan();
    defer scanner.stop();

    try scanner.start();

    listen_fd = server.socket.handle;
    installShutdownHandler();

    const bound_port = server.socket.address.getPort();
    try writeStartupReport(stdout, options, bound_port, &scanner);

    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.SocketNotListening => {
                listen_fd = -1;
                return .ok;
            },
            error.ConnectionAborted => continue,
            else => return err,
        };
        handleConnection(io, stream, &scanner) catch {};
        stream.close(io);
    }
}

fn resolveAddress(host: []const u8, port: u16) !net.IpAddress {
    if (std.mem.eql(u8, host, "0.0.0.0")) {
        return .{ .ip4 = net.Ip4Address.unspecified(port) };
    }
    if (std.mem.eql(u8, host, "127.0.0.1")) {
        return .{ .ip4 = net.Ip4Address.loopback(port) };
    }
    return net.IpAddress.parseIp4(host, port);
}

fn writeStartupReport(
    stdout: *std.Io.Writer,
    options: serve_options.ServeOptions,
    bound_port: u16,
    scanner: *serve_catalog.Scanner,
) !void {
    // Count artifacts in the current snapshot (zero when the initial scan
    // failed). The snapshot is immutable for the duration of the guard.
    var artifact_count: usize = 0;
    {
        var guard = scanner.snapshotLock();
        defer guard.release();
        if (guard.get()) |catalog| {
            artifact_count = catalog.entries.len;
        }
    }

    // The "open" URL uses a usable loopback host when the bind address is
    // all-interfaces, so an operator on the host can click through. The
    // configured bind address is reported separately so LAN exposure is clear.
    const open_host: []const u8 = if (std.mem.eql(u8, options.host, "0.0.0.0"))
        "127.0.0.1"
    else
        options.host;

    const plural: []const u8 = if (artifact_count == 1) "artifact" else "artifacts";

    try stdout.print(
        "matcha serve: root {s}\n",
        .{options.directory},
    );
    try stdout.print(
        "matcha serve: serving {d} {s} at http://{s}:{d}/\n",
        .{ artifact_count, plural, open_host, bound_port },
    );
    try stdout.print(
        "matcha serve: listening on {s}:{d} (refresh every {d}s)\n",
        .{ options.host, bound_port, options.interval_seconds },
    );
}

fn handleConnection(io: std.Io, stream: net.Stream, scanner: *serve_catalog.Scanner) !void {
    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buffer);
    var stream_writer = stream.writer(io, &write_buffer);
    const reader: *std.Io.Reader = &stream_reader.interface;
    const writer: *std.Io.Writer = &stream_writer.interface;

    const request_line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return,
        error.StreamTooLong => {
            try writeStatus(writer, .bad_request, "text/plain; charset=utf-8", "request line too long");
            try writer.flush();
            return;
        },
        else => return err,
    };

    const trimmed = std.mem.trim(u8, request_line, " \t\r");
    const method_end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse {
        try writeStatus(writer, .bad_request, "text/plain; charset=utf-8", "malformed request line");
        try writer.flush();
        return;
    };
    const method = trimmed[0..method_end];
    const rest = trimmed[method_end + 1 ..];

    const path_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    const path = rest[0..path_end];

    // Drain remaining headers (bounded by buffer capacity).
    while (true) {
        const header = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            error.StreamTooLong => {
                try writeStatus(writer, .bad_request, "text/plain; charset=utf-8", "headers too large");
                try writer.flush();
                return;
            },
            else => return err,
        };
        const header_trimmed = std.mem.trim(u8, header, " \t\r");
        if (header_trimmed.len == 0) break;
    }

    if (!std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "HEAD")) {
        try writeStatus(writer, .method_not_allowed, "text/plain; charset=utf-8", "method not allowed");
        try writer.flush();
        return;
    }

    if (std.mem.eql(u8, path, "/api/catalog")) {
        try writeCatalogResponse(writer, scanner);
        try writer.flush();
        return;
    }

    if (std.mem.startsWith(u8, path, "/artifacts/")) {
        try writeArtifactResponse(io, writer, scanner, path);
        try writer.flush();
        return;
    }

    if (!std.mem.eql(u8, path, "/")) {
        try writeStatus(writer, .not_found, "text/plain; charset=utf-8", "not found");
        try writer.flush();
        return;
    }

    try writeIndexResponse(writer);
    try writer.flush();
}

/// Serialize the current catalog snapshot to a JSON buffer while holding the
/// scanner mutex, then release the snapshot and write the response. The
/// snapshot is immutable so concurrent requests always receive a complete
/// prior or complete new catalog.
fn writeCatalogResponse(
    writer: *std.Io.Writer,
    scanner: *serve_catalog.Scanner,
) !void {
    var guard = scanner.snapshotLock();
    defer guard.release();

    const catalog = guard.get() orelse {
        try writeStatus(writer, .ok, "application/json; charset=utf-8", "{\"projects\":[],\"warnings\":[]}");
        return;
    };

    const json = serve_catalog.catalogJsonAlloc(std.heap.page_allocator, catalog) catch {
        try writeStatus(writer, .not_found, "text/plain; charset=utf-8", "catalog unavailable");
        return;
    };
    defer std.heap.page_allocator.free(json);

    try writer.print(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{json.len},
    );
    try writer.writeAll(json);
}

/// Maximum buffer size used while streaming an artifact body to the response.
/// The full file is never loaded into memory; data is pumped through this
/// fixed buffer so memory usage stays bounded regardless of artifact size.
const artifact_stream_buffer_len: usize = 8192;

/// Headers emitted with every artifact response. `X-Content-Type-Options:
/// nosniff` prevents browsers from MIME-sniffing the body, and `Cache-Control:
/// no-cache` lets frequently regenerated local files refresh without stale
/// browser caches holding onto a previous version.
const artifact_extra_headers: []const u8 =
    "X-Content-Type-Options: nosniff\r\n" ++
    "Cache-Control: no-cache, no-store, must-revalidate\r\n";

/// Resolve and stream the original HTML artifact bytes for a request matching
/// `/artifacts/<encoded-relative-path>`. Containment is enforced at request
/// time through three independent checks so the server cannot be used as a
/// general-purpose file browser and cannot serve files outside the root:
///
/// 1. The relative path is decoded and validated once via
///    `serve_routes.parseArtifactRoute` (rejects malformed encoding, NUL
///    bytes, absolute paths, `..` traversal, and backslash separators).
/// 2. The current catalog snapshot is consulted and the request is rejected
///    unless `rel_path` is a currently recognized catalog artifact. This
///    re-checks stale catalog data at request time and prevents serving
///    non-catalog HTML, non-HTML files, directories, device files, or special
///    files even if they happen to live under the root.
/// 3. The file is opened relative to the configured root with
///    `follow_symlinks = false` and `allow_directory = false`, and its `stat`
///    is checked to confirm `kind == .file`. This blocks time-of-check to
///    time-of-use replacement with an outside-root symlink and any non-regular
///    file that bypassed the catalog check.
///
/// All request-time validation failures return a generic 404 with a body of
/// `not found` so absolute filesystem paths and routing internals are never
/// disclosed to HTTP clients. Files that disappeared or became unreadable
/// between catalog lookup and open produce a normal 404 response without
/// affecting the server. The body is delivered byte-for-byte without
/// rewriting, header injection, or metadata insertion; Matcha outputs remain
/// independently self-contained. Ordinary regenerated files at the same safe
/// relative location are served after the next catalog refresh without a
/// server restart.
fn writeArtifactResponse(
    io: std.Io,
    writer: *std.Io.Writer,
    scanner: *serve_catalog.Scanner,
    request_path: []const u8,
) !void {
    const allocator = std.heap.page_allocator;
    const rel_path = serve_routes.parseArtifactRoute(allocator, request_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Malformed/traversal/absolute/separator/NUL/empty -> 404 (no detail).
        else => {
            try writeStatus(writer, .not_found, "text/plain; charset=utf-8", "not found");
            return;
        },
    };
    defer allocator.free(rel_path);

    // Re-check containment against the live catalog snapshot: only currently
    // recognized Matcha artifacts may be served. This prevents the server
    // from acting as a general-purpose file browser for non-catalog files
    // and closes the stale-catalog gap (a deleted file may still appear in a
    // stale snapshot; we re-verify by opening the file below).
    {
        var guard = scanner.snapshotLock();
        defer guard.release();
        if (guard.get()) |catalog| {
            if (catalog.findEntry(rel_path) == null) {
                try writeStatus(writer, .not_found, "text/plain; charset=utf-8", "not found");
                return;
            }
        } else {
            // No snapshot yet: nothing can be a recognized artifact.
            try writeStatus(writer, .not_found, "text/plain; charset=utf-8", "not found");
            return;
        }
    }

    // Open the artifact relative to the configured root. Opening via the
    // already-validated relative path under the root directory enforces
    // containment at request time independently of the catalog snapshot.
    var root_dir = std.Io.Dir.openDirAbsolute(io, scanner.root, .{
        .follow_symlinks = false,
    }) catch {
        try writeStatus(writer, .not_found, "text/plain; charset=utf-8", "not found");
        return;
    };
    defer root_dir.close(io);

    var file = root_dir.openFile(io, rel_path, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch {
        // FileNotFound, AccessDenied, IsDir, SymLinkLoop, or any other open
        // failure: respond 404 without disclosing the reason or absolute path.
        try writeStatus(writer, .not_found, "text/plain; charset=utf-8", "not found");
        return;
    };
    defer file.close(io);

    // Stat to obtain an exact content length and, critically, to confirm the
    // opened fd is a regular file. This closes the time-of-check to time-of-use
    // gap: a file swapped for an outside-root symlink between catalog lookup
    // and open is rejected here because `follow_symlinks = false` makes stat
    // report `sym_link` rather than the symlink target's kind.
    const stat = file.stat(io) catch {
        try writeStatus(writer, .not_found, "text/plain; charset=utf-8", "not found");
        return;
    };
    if (stat.kind != .file) {
        try writeStatus(writer, .not_found, "text/plain; charset=utf-8", "not found");
        return;
    }
    const content_length: u64 = stat.size;

    // Headers identify HTML safely and avoid stale regenerated artifacts.
    try writer.print(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" ++
            "Content-Length: {d}\r\n" ++
            "{s}" ++
            "Connection: close\r\n\r\n",
        .{ content_length, artifact_extra_headers },
    );

    // Stream the body through a fixed buffer so the whole file is never held in
    // memory. The reader's seek position advances on each read so concurrent
    // requests on the same fd would interfere; instead each request opens its
    // own file descriptor above.
    var read_buffer: [artifact_stream_buffer_len]u8 = undefined;
    var file_reader = file.readerStreaming(io, &read_buffer);
    const reader: *std.Io.Reader = &file_reader.interface;

    while (true) {
        const got = reader.readSliceShort(&read_buffer) catch |err| switch (err) {
            error.ReadFailed => return err,
        };
        if (got == 0) break;
        try writer.writeAll(read_buffer[0..got]);
    }
}

const StatusCode = enum {
    ok,
    not_found,
    method_not_allowed,
    bad_request,

    fn reason(self: StatusCode) []const u8 {
        return switch (self) {
            .ok => "200 OK",
            .not_found => "404 Not Found",
            .method_not_allowed => "405 Method Not Allowed",
            .bad_request => "400 Bad Request",
        };
    }
};

fn writeStatus(
    writer: *std.Io.Writer,
    status: StatusCode,
    content_type: []const u8,
    body: []const u8,
) !void {
    try writer.print(
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status.reason(), content_type, body.len },
    );
    try writer.writeAll(body);
}

/// Compose and stream the self-contained serve index HTML response. The
/// shell inlines the embedded serve JavaScript and CSS so the catalog UI is
/// reachable without external files, CDNs, or the source checkout. The body
/// references `/api/catalog` for live data and provides a `#serve-root`
/// mount point consumed by the embedded Svelte client.
///
/// The content length is computed up front from the embedded asset lengths so
/// the response carries an exact `Content-Length` header without buffering
/// the whole body into a single allocation.
fn writeIndexResponse(writer: *std.Io.Writer) !void {
    const js = assets.optionalServeJs() orelse {
        try writeStatus(writer, .not_found, "text/plain; charset=utf-8", "serve assets unavailable");
        return;
    };
    const css = assets.optionalServeCss() orelse {
        try writeStatus(writer, .not_found, "text/plain; charset=utf-8", "serve assets unavailable");
        return;
    };

    const head =
        "<!DOCTYPE html>\n" ++
        "<html lang=\"en\">\n" ++
        "<head>\n" ++
        "<meta charset=\"UTF-8\">\n" ++
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" ++
        "<title>matcha serve</title>\n" ++
        "<style>\n";
    const css_close = "</style>\n";
    const script_open = "<script>\n";
    const script_close = "</script>\n";
    const tail =
        "</head>\n" ++
        "<body>\n" ++
        "<div id=\"serve-root\"></div>\n" ++
        "</body>\n" ++
        "</html>\n";

    const total = head.len + css.contents.len + css_close.len +
        script_open.len + js.contents.len + script_close.len + tail.len;

    try writer.print(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{total},
    );
    try writer.writeAll(head);
    try writer.writeAll(css.contents);
    try writer.writeAll(css_close);
    try writer.writeAll(script_open);
    try writer.writeAll(js.contents);
    try writer.writeAll(script_close);
    try writer.writeAll(tail);
}

/// Test helper that owns a temp directory and a scanner backed by it. Used so
/// `handleConnection`-based tests can exercise routing with a real catalog
/// snapshot without depending on the developer's filesystem.
const TestScanner = struct {
    tmp: std.testing.TmpDir,
    scanner: serve_catalog.Scanner,

    fn deinit(self: *TestScanner) void {
        self.scanner.stop();
        self.tmp.cleanup();
    }
};

fn testScanner() !TestScanner {
    const io = std.testing.io;
    const tmp = std.testing.tmpDir(.{});
    const root = try std.heap.page_allocator.dupe(u8, tmp.dir.path.?);
    errdefer std.heap.page_allocator.free(root);
    var scanner = serve_catalog.Scanner.init(
        io,
        std.heap.page_allocator,
        root,
        5,
        serve_catalog.scan,
    );
    scanner.initialScan();
    return .{ .tmp = tmp, .scanner = scanner };
}

test "resolveAddress maps 0.0.0.0 to unspecified" {
    const addr = try resolveAddress("0.0.0.0", 0);
    try std.testing.expect(addr == .ip4);
    try std.testing.expectEqual(@as(u16, 0), addr.ip4.port);
}

test "resolveAddress maps 127.0.0.1 to loopback" {
    const addr = try resolveAddress("127.0.0.1", 0);
    try std.testing.expect(addr == .ip4);
    try std.testing.expectEqual(@as(u16, 0), addr.ip4.port);
}

test "resolveAddress parses explicit ipv4 host" {
    const addr = try resolveAddress("127.0.0.1", 8123);
    try std.testing.expectEqual(@as(u16, 8123), addr.ip4.port);
}

test "writeIndexResponse emits a self-contained HTML shell with embedded assets" {
    var buffer: [65536]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeIndexResponse(&writer);
    const output = buffer[0..writer.end];

    try std.testing.expect(std.mem.startsWith(u8, output, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, output, "Content-Type: text/html; charset=utf-8") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<!DOCTYPE html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<title>matcha serve</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<div id=\"serve-root\"></div>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<style>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<script>") != null);

    const js_asset = assets.serve_js;
    const css_asset = assets.serve_css;
    try std.testing.expect(js_asset.contents.len > 0);
    try std.testing.expect(css_asset.contents.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, output, js_asset.contents) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, css_asset.contents) != null);

    const content_length_header = "Content-Length: ";
    const cl_pos = std.mem.indexOf(u8, output, content_length_header).?;
    const cl_start = cl_pos + content_length_header.len;
    const cl_end = std.mem.indexOfScalarPos(u8, output, cl_start, '\r').?;
    const cl_str = output[cl_start..cl_end];
    const expected_len = std.fmt.parseInt(usize, cl_str, 10) catch unreachable;
    const header_end = std.mem.indexOf(u8, output, "\r\n\r\n").? + 4;
    try std.testing.expectEqual(expected_len, output.len - header_end);
}

test "writeIndexResponse makes no external network requests" {
    var buffer: [65536]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeIndexResponse(&writer);
    const output = buffer[0..writer.end];

    try std.testing.expect(std.mem.indexOf(u8, output, "http://") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "https://") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "src=\"http") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "href=\"http") == null);
}

test "writeStatus emits a complete HTTP response" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeStatus(&writer, .ok, "text/html; charset=utf-8", "hello");
    const output = buffer[0..writer.end];
    try std.testing.expect(std.mem.startsWith(u8, output, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, output, "Content-Length: 5") != null);
    try std.testing.expect(std.mem.endsWith(u8, output, "hello"));
}

test "run serves embedded index at slash on loopback ephemeral port" {
    const io = std.testing.io;
    var scanner_ctx = try testScanner();
    defer scanner_ctx.deinit();

    var server = try net.IpAddress.listen(
        &.{ .ip4 = net.Ip4Address.loopback(0) },
        io,
        .{ .reuse_address = true },
    );
    defer server.deinit(io);

    const bound_port = server.socket.address.getPort();

    const Harness = struct {
        port: u16,
        io: std.Io,
        status_line: [64]u8 = undefined,
        status_len: usize = 0,

        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.connectAndRequest() catch {};
        }

        fn connectAndRequest(self: *@This()) !void {
            const address: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(self.port) };
            var stream = try net.IpAddress.connect(&address, self.io, .{ .mode = .stream });

            var write_buffer: [256]u8 = undefined;
            var stream_writer = stream.writer(self.io, &write_buffer);
            try stream_writer.interface.writeAll("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
            try stream_writer.interface.flush();

            var read_buffer: [4096]u8 = undefined;
            var stream_reader = stream.reader(self.io, &read_buffer);
            const line = stream_reader.interface.takeDelimiterExclusive('\n') catch "";
            const copy_len = @min(line.len, self.status_line.len);
            @memcpy(self.status_line[0..copy_len], line[0..copy_len]);
            self.status_len = copy_len;

            stream.close(self.io);
        }
    };

    var harness: Harness = .{ .port = bound_port, .io = io };
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, Harness.run, .{&harness});

    const stream = try server.accept(io);
    try handleConnection(io, stream, &scanner_ctx.scanner);
    stream.close(io);

    thread.join();

    const status = harness.status_line[0..harness.status_len];
    try std.testing.expect(std.mem.indexOf(u8, status, "HTTP/1.1 200 OK") != null);
}

test "handleConnection returns 404 for unknown route" {
    const io = std.testing.io;
    var scanner_ctx = try testScanner();
    defer scanner_ctx.deinit();

    var server = try net.IpAddress.listen(
        &.{ .ip4 = net.Ip4Address.loopback(0) },
        io,
        .{ .reuse_address = true },
    );
    defer server.deinit(io);
    const bound_port = server.socket.address.getPort();

    const Harness = struct {
        port: u16,
        io: std.Io,
        status_line: [64]u8 = undefined,
        status_len: usize = 0,

        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.connectAndRequest() catch {};
        }

        fn connectAndRequest(self: *@This()) !void {
            const address: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(self.port) };
            var stream = try net.IpAddress.connect(&address, self.io, .{ .mode = .stream });

            var write_buffer: [256]u8 = undefined;
            var stream_writer = stream.writer(self.io, &write_buffer);
            try stream_writer.interface.writeAll("GET /missing HTTP/1.1\r\nHost: localhost\r\n\r\n");
            try stream_writer.interface.flush();

            var read_buffer: [4096]u8 = undefined;
            var stream_reader = stream.reader(self.io, &read_buffer);
            const line = stream_reader.interface.takeDelimiterExclusive('\n') catch "";
            const copy_len = @min(line.len, self.status_line.len);
            @memcpy(self.status_line[0..copy_len], line[0..copy_len]);
            self.status_len = copy_len;

            stream.close(self.io);
        }
    };

    var harness: Harness = .{ .port = bound_port, .io = io };
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, Harness.run, .{&harness});

    const stream = try server.accept(io);
    try handleConnection(io, stream, &scanner_ctx.scanner);
    stream.close(io);

    thread.join();

    const status = harness.status_line[0..harness.status_len];
    try std.testing.expect(std.mem.indexOf(u8, status, "HTTP/1.1 404 Not Found") != null);
}

test "handleConnection rejects unsupported methods" {
    const io = std.testing.io;
    var scanner_ctx = try testScanner();
    defer scanner_ctx.deinit();

    var server = try net.IpAddress.listen(
        &.{ .ip4 = net.Ip4Address.loopback(0) },
        io,
        .{ .reuse_address = true },
    );
    defer server.deinit(io);
    const bound_port = server.socket.address.getPort();

    const Harness = struct {
        port: u16,
        io: std.Io,
        status_line: [64]u8 = undefined,
        status_len: usize = 0,

        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.connectAndRequest() catch {};
        }

        fn connectAndRequest(self: *@This()) !void {
            const address: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(self.port) };
            var stream = try net.IpAddress.connect(&address, self.io, .{ .mode = .stream });

            var write_buffer: [256]u8 = undefined;
            var stream_writer = stream.writer(self.io, &write_buffer);
            try stream_writer.interface.writeAll("POST / HTTP/1.1\r\nHost: localhost\r\n\r\n");
            try stream_writer.interface.flush();

            var read_buffer: [4096]u8 = undefined;
            var stream_reader = stream.reader(self.io, &read_buffer);
            const line = stream_reader.interface.takeDelimiterExclusive('\n') catch "";
            const copy_len = @min(line.len, self.status_line.len);
            @memcpy(self.status_line[0..copy_len], line[0..copy_len]);
            self.status_len = copy_len;

            stream.close(self.io);
        }
    };

    var harness: Harness = .{ .port = bound_port, .io = io };
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, Harness.run, .{&harness});

    const stream = try server.accept(io);
    try handleConnection(io, stream, &scanner_ctx.scanner);
    stream.close(io);

    thread.join();

    const status = harness.status_line[0..harness.status_len];
    try std.testing.expect(std.mem.indexOf(u8, status, "HTTP/1.1 405 Method Not Allowed") != null);
}

test "handleConnection rejects oversized request lines" {
    const io = std.testing.io;
    var scanner_ctx = try testScanner();
    defer scanner_ctx.deinit();

    var server = try net.IpAddress.listen(
        &.{ .ip4 = net.Ip4Address.loopback(0) },
        io,
        .{ .reuse_address = true },
    );
    defer server.deinit(io);
    const bound_port = server.socket.address.getPort();

    const Harness = struct {
        port: u16,
        io: std.Io,
        status_line: [64]u8 = undefined,
        status_len: usize = 0,

        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.connectAndRequest() catch {};
        }

        fn connectAndRequest(self: *@This()) !void {
            const address: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(self.port) };
            var stream = try net.IpAddress.connect(&address, self.io, .{ .mode = .stream });

            var write_buffer: [8192]u8 = undefined;
            var stream_writer = stream.writer(self.io, &write_buffer);
            // Send a request line longer than the 4096 byte read buffer.
            const long_path: [5000]u8 = @splat('A');
            const request = try std.fmt.bufPrint(&write_buffer, "GET /{s} HTTP/1.1\r\nHost: localhost\r\n\r\n", .{long_path});
            try stream_writer.interface.writeAll(request);
            try stream_writer.interface.flush();

            var read_buffer: [4096]u8 = undefined;
            var stream_reader = stream.reader(self.io, &read_buffer);
            const line = stream_reader.interface.takeDelimiterExclusive('\n') catch "";
            const copy_len = @min(line.len, self.status_line.len);
            @memcpy(self.status_line[0..copy_len], line[0..copy_len]);
            self.status_len = copy_len;

            stream.close(self.io);
        }
    };

    var harness: Harness = .{ .port = bound_port, .io = io };
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, Harness.run, .{&harness});

    const stream = try server.accept(io);
    try handleConnection(io, stream, &scanner_ctx.scanner);
    stream.close(io);

    thread.join();

    const status = harness.status_line[0..harness.status_len];
    try std.testing.expect(std.mem.indexOf(u8, status, "HTTP/1.1 400 Bad Request") != null);
}

test "run reports bind failure and exits non-zero" {
    const io = std.testing.io;

    var stdout_buffer: [256]u8 = undefined;
    var stderr_buffer: [512]u8 = undefined;
    const stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    // An invalid IPv4 literal forces resolveAddress to fail before binding.
    const options: serve_options.ServeOptions = .{
        .directory = "/tmp",
        .host = "not.an.ipv4.address",
        .port = 0,
        .interval_seconds = 5,
    };

    const code = try run(io, options, @constCast(&stdout), &stderr);
    try std.testing.expectEqual(serve_options.ExitCode.failure, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "cannot bind") != null);
}

test "writeStartupReport prints root, artifact count, open url, bind, and interval" {
    var scanner_ctx = try testScanner();
    defer scanner_ctx.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);

    const options: serve_options.ServeOptions = .{
        .directory = "/tmp/example",
        .host = "0.0.0.0",
        .port = 27004,
        .interval_seconds = 5,
    };

    try writeStartupReport(&stdout, options, 27004, &scanner_ctx.scanner);
    const out = stdout_buffer[0..stdout.end];

    // Root is reported.
    try std.testing.expect(std.mem.indexOf(u8, out, "matcha serve: root /tmp/example") != null);
    // Artifact count is reported (testScanner creates an empty directory).
    try std.testing.expect(std.mem.indexOf(u8, out, "serving 0 artifacts") != null);
    // Open URL uses loopback when bound to all interfaces.
    try std.testing.expect(std.mem.indexOf(u8, out, "http://127.0.0.1:27004/") != null);
    // Configured bind address is reported separately.
    try std.testing.expect(std.mem.indexOf(u8, out, "listening on 0.0.0.0:27004") != null);
    // Refresh interval is reported.
    try std.testing.expect(std.mem.indexOf(u8, out, "refresh every 5s") != null);
}

test "writeStartupReport uses singular 'artifact' for one entry" {
    // Build a scanner with one fake artifact by writing a plan fixture.
    var scanner_ctx = try testScannerWithOneArtifact();
    defer scanner_ctx.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);

    const options: serve_options.ServeOptions = .{
        .directory = scanner_ctx.scanner.root,
        .host = "127.0.0.1",
        .port = 27004,
        .interval_seconds = 5,
    };

    try writeStartupReport(&stdout, options, 27004, &scanner_ctx.scanner);
    const out = stdout_buffer[0..stdout.end];
    try std.testing.expect(std.mem.indexOf(u8, out, "serving 1 artifact at") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "http://127.0.0.1:27004/") != null);
}

/// Test helper that creates a temp directory containing one plan HTML fixture
/// so the scanner has a non-empty catalog for startup-report assertions.
fn testScannerWithOneArtifact() !TestScanner {
    const io = std.testing.io;
    const tmp = std.testing.tmpDir(.{});
    const root = try std.heap.page_allocator.dupe(u8, tmp.dir.path.?);
    errdefer std.heap.page_allocator.free(root);
    try tmp.dir.writeFile("plan.html", minimalPlanHtml());
    var scanner = serve_catalog.Scanner.init(
        io,
        std.heap.page_allocator,
        root,
        5,
        serve_catalog.scan,
    );
    scanner.initialScan();
    return .{ .tmp = tmp, .scanner = scanner };
}

fn minimalPlanHtml() []const u8 {
    return "<!DOCTYPE html><html><head></head><body>" ++
        "<script type=\"application/json\" id=\"plan-data\">{\"title\":\"x\"}</script>" ++
        "</body></html>";
}

/// Test harness that captures the full response (status line + headers + body)
/// rather than just the status line. Used by artifact-delivery tests so the
/// body bytes can be compared byte-for-byte against the fixture on disk.
const FullResponseHarness = struct {
    port: u16,
    io: std.Io,
    request: []const u8,
    response: [16384]u8 = undefined,
    response_len: usize = 0,

    fn run(ctx: *anyopaque) void {
        const self: *FullResponseHarness = @ptrCast(@alignCast(ctx));
        self.connectAndRequest() catch {};
    }

    fn connectAndRequest(self: *FullResponseHarness) !void {
        const address: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(self.port) };
        var stream = try net.IpAddress.connect(&address, self.io, .{ .mode = .stream });

        var write_buffer: [256]u8 = undefined;
        var stream_writer = stream.writer(self.io, &write_buffer);
        try stream_writer.interface.writeAll(self.request);
        try stream_writer.interface.flush();

        var read_buffer: [4096]u8 = undefined;
        var stream_reader = stream.reader(self.io, &read_buffer);
        var total: usize = 0;
        while (total < self.response.len) {
            const got = stream_reader.interface.readSliceShort(self.response[total..]) catch break;
            if (got == 0) break;
            total += got;
        }
        self.response_len = total;

        stream.close(self.io);
    }
};

/// Write a minimal Matcha plan HTML fixture into `dir` so the scanner
/// classifies it as a plan artifact and the response body can be compared
/// against the on-disk bytes.
fn writePlanArtifactFixture(dir: std.Io.Dir, name: []const u8) !void {
    const html =
        \\<!DOCTYPE html><html><head><title>Plan Fixture</title></head><body>
        \\<script type="application/json" id="plan-data">{"title":"Fixture","project":"demo"}</script>
        \\</body></html>
    ;
    try dir.writeFile(name, html);
}

test "handleConnection streams artifact bytes exactly at /artifacts/<rel>" {
    const io = std.testing.io;
    var scanner_ctx = try testScanner();
    defer scanner_ctx.deinit();

    // Create a fixture file the scanner will discover and serve.
    try writePlanArtifactFixture(scanner_ctx.tmp.dir, "plan.html");
    // Re-run scan so the catalog picks up the new fixture.
    scanner_ctx.scanner.runScan();

    var server = try net.IpAddress.listen(
        &.{ .ip4 = net.Ip4Address.loopback(0) },
        io,
        .{ .reuse_address = true },
    );
    defer server.deinit(io);
    const bound_port = server.socket.address.getPort();

    var harness: FullResponseHarness = .{
        .port = bound_port,
        .io = io,
        .request = "GET /artifacts/plan.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
    };
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, FullResponseHarness.run, .{&harness});

    const stream = try server.accept(io);
    try handleConnection(io, stream, &scanner_ctx.scanner);
    stream.close(io);
    thread.join();

    const response = harness.response[0..harness.response_len];
    try std.testing.expect(std.mem.indexOf(u8, response, "HTTP/1.1 200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Content-Type: text/html; charset=utf-8") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Content-Length: 168") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "X-Content-Type-Options: nosniff") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Cache-Control: no-cache, no-store, must-revalidate") != null);

    // Body must be byte-for-byte identical to the fixture on disk.
    const body_start = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.NoBodyDelimiter;
    const body = response[body_start + 4 ..];
    var file_bytes: [256]u8 = undefined;
    const n = scanner_ctx.tmp.dir.readFile(io, "plan.html", &file_bytes) catch return error.ReadFixtureFailed;
    try std.testing.expectEqualStrings(file_bytes[0..n], body);
}

test "handleConnection streams nested artifact with spaces and unicode" {
    const io = std.testing.io;
    var scanner_ctx = try testScanner();
    defer scanner_ctx.deinit();

    // Build a nested directory containing a spaced + unicode filename.
    const sub_dir = scanner_ctx.tmp.dir.makeOpenPath(io, "café sub", .{}) catch return error.MakePathFailed;
    _ = sub_dir;
    try writePlanArtifactFixture(scanner_ctx.tmp.dir, "café sub/plan.html");
    scanner_ctx.scanner.runScan();

    var server = try net.IpAddress.listen(
        &.{ .ip4 = net.Ip4Address.loopback(0) },
        io,
        .{ .reuse_address = true },
    );
    defer server.deinit(io);
    const bound_port = server.socket.address.getPort();

    // URL-encoded form of "café sub/plan.html".
    const url = "GET /artifacts/caf%C3%A9%20sub/plan.html HTTP/1.1\r\nHost: localhost\r\n\r\n";
    var harness: FullResponseHarness = .{
        .port = bound_port,
        .io = io,
        .request = url,
    };
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, FullResponseHarness.run, .{&harness});

    const stream = try server.accept(io);
    try handleConnection(io, stream, &scanner_ctx.scanner);
    stream.close(io);
    thread.join();

    const response = harness.response[0..harness.response_len];
    try std.testing.expect(std.mem.indexOf(u8, response, "HTTP/1.1 200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Content-Type: text/html; charset=utf-8") != null);

    const body_start = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.NoBodyDelimiter;
    const body = response[body_start + 4 ..];
    var file_bytes: [256]u8 = undefined;
    const n = scanner_ctx.tmp.dir.readFile(io, "café sub/plan.html", &file_bytes) catch return error.ReadFixtureFailed;
    try std.testing.expectEqualStrings(file_bytes[0..n], body);
}

test "handleConnection returns 404 for missing artifact" {
    const io = std.testing.io;
    var scanner_ctx = try testScanner();
    defer scanner_ctx.deinit();

    var server = try net.IpAddress.listen(
        &.{ .ip4 = net.Ip4Address.loopback(0) },
        io,
        .{ .reuse_address = true },
    );
    defer server.deinit(io);
    const bound_port = server.socket.address.getPort();

    var harness: FullResponseHarness = .{
        .port = bound_port,
        .io = io,
        .request = "GET /artifacts/does-not-exist.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
    };
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, FullResponseHarness.run, .{&harness});

    const stream = try server.accept(io);
    try handleConnection(io, stream, &scanner_ctx.scanner);
    stream.close(io);
    thread.join();

    const response = harness.response[0..harness.response_len];
    try std.testing.expect(std.mem.indexOf(u8, response, "HTTP/1.1 404 Not Found") != null);
}

test "handleConnection returns 404 for parent traversal in artifact route" {
    const io = std.testing.io;
    var scanner_ctx = try testScanner();
    defer scanner_ctx.deinit();

    try writePlanArtifactFixture(scanner_ctx.tmp.dir, "plan.html");
    scanner_ctx.scanner.runScan();

    var server = try net.IpAddress.listen(
        &.{ .ip4 = net.Ip4Address.loopback(0) },
        io,
        .{ .reuse_address = true },
    );
    defer server.deinit(io);
    const bound_port = server.socket.address.getPort();

    var harness: FullResponseHarness = .{
        .port = bound_port,
        .io = io,
        .request = "GET /artifacts/../secret.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
    };
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, FullResponseHarness.run, .{&harness});

    const stream = try server.accept(io);
    try handleConnection(io, stream, &scanner_ctx.scanner);
    stream.close(io);
    thread.join();

    const response = harness.response[0..harness.response_len];
    try std.testing.expect(std.mem.indexOf(u8, response, "HTTP/1.1 404 Not Found") != null);
}

test "handleConnection returns 404 for malformed encoding in artifact route" {
    const io = std.testing.io;
    var scanner_ctx = try testScanner();
    defer scanner_ctx.deinit();

    var server = try net.IpAddress.listen(
        &.{ .ip4 = net.Ip4Address.loopback(0) },
        io,
        .{ .reuse_address = true },
    );
    defer server.deinit(io);
    const bound_port = server.socket.address.getPort();

    var harness: FullResponseHarness = .{
        .port = bound_port,
        .io = io,
        .request = "GET /artifacts/a%ZZb.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
    };
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, FullResponseHarness.run, .{&harness});

    const stream = try server.accept(io);
    try handleConnection(io, stream, &scanner_ctx.scanner);
    stream.close(io);
    thread.join();

    const response = harness.response[0..harness.response_len];
    try std.testing.expect(std.mem.indexOf(u8, response, "HTTP/1.1 404 Not Found") != null);
}

test "handleConnection serves empty artifact file with zero content length" {
    const io = std.testing.io;
    var scanner_ctx = try testScanner();
    defer scanner_ctx.deinit();

    // Write a minimal-but-empty plan fixture. The classifier requires the
    // marker so the scanner picks it up, but the file body can be tiny.
    try scanner_ctx.tmp.dir.writeFile(
        "empty.html",
        "<script type=\"application/json\" id=\"plan-data\">{\"title\":\"x\"}</script>",
    );
    scanner_ctx.scanner.runScan();

    var server = try net.IpAddress.listen(
        &.{ .ip4 = net.Ip4Address.loopback(0) },
        io,
        .{ .reuse_address = true },
    );
    defer server.deinit(io);
    const bound_port = server.socket.address.getPort();

    var harness: FullResponseHarness = .{
        .port = bound_port,
        .io = io,
        .request = "GET /artifacts/empty.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
    };
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, FullResponseHarness.run, .{&harness});

    const stream = try server.accept(io);
    try handleConnection(io, stream, &scanner_ctx.scanner);
    stream.close(io);
    thread.join();

    const response = harness.response[0..harness.response_len];
    try std.testing.expect(std.mem.indexOf(u8, response, "HTTP/1.1 200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Content-Length: 69") != null);

    const body_start = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.NoBodyDelimiter;
    const body = response[body_start + 4 ..];
    try std.testing.expectEqual(@as(usize, 69), body.len);
    try std.testing.expectEqualStrings(
        "<script type=\"application/json\" id=\"plan-data\">{\"title\":\"x\"}</script>",
        body,
    );
}

test "handleConnection refuses non-catalog HTML under root" {
    // A plain HTML file without the plan/map marker is not a catalog artifact
    // and must not be served even though it lives under the root.
    const io = std.testing.io;
    var scanner_ctx = try testScanner();
    defer scanner_ctx.deinit();

    try scanner_ctx.tmp.dir.writeFile(
        "plain.html",
        "<html><body>not a matcha artifact</body></html>",
    );
    scanner_ctx.scanner.runScan();

    var server = try net.IpAddress.listen(
        &.{ .ip4 = net.Ip4Address.loopback(0) },
        io,
        .{ .reuse_address = true },
    );
    defer server.deinit(io);
    const bound_port = server.socket.address.getPort();

    var harness: FullResponseHarness = .{
        .port = bound_port,
        .io = io,
        .request = "GET /artifacts/plain.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
    };
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, FullResponseHarness.run, .{&harness});

    const stream = try server.accept(io);
    try handleConnection(io, stream, &scanner_ctx.scanner);
    stream.close(io);
    thread.join();

    const response = harness.response[0..harness.response_len];
    try std.testing.expect(std.mem.indexOf(u8, response, "HTTP/1.1 404 Not Found") != null);
    // The plain HTML body must not leak through.
    try std.testing.expect(std.mem.indexOf(u8, response, "not a matcha artifact") == null);
}

test "handleConnection refuses non-HTML file under root" {
    const io = std.testing.io;
    var scanner_ctx = try testScanner();
    defer scanner_ctx.deinit();

    try scanner_ctx.tmp.dir.writeFile("notes.txt", "secret notes");
    scanner_ctx.scanner.runScan();

    var server = try net.IpAddress.listen(
        &.{ .ip4 = net.Ip4Address.loopback(0) },
        io,
        .{ .reuse_address = true },
    );
    defer server.deinit(io);
    const bound_port = server.socket.address.getPort();

    var harness: FullResponseHarness = .{
        .port = bound_port,
        .io = io,
        .request = "GET /artifacts/notes.txt HTTP/1.1\r\nHost: localhost\r\n\r\n",
    };
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, FullResponseHarness.run, .{&harness});

    const stream = try server.accept(io);
    try handleConnection(io, stream, &scanner_ctx.scanner);
    stream.close(io);
    thread.join();

    const response = harness.response[0..harness.response_len];
    try std.testing.expect(std.mem.indexOf(u8, response, "HTTP/1.1 404 Not Found") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "secret notes") == null);
}

test "handleConnection refuses request for a directory under root" {
    const io = std.testing.io;
    var scanner_ctx = try testScanner();
    defer scanner_ctx.deinit();

    // A directory is not a catalog artifact and must not be served.
    _ = scanner_ctx.tmp.dir.makeOpenPath(io, "subdir", .{}) catch return error.MakePathFailed;
    scanner_ctx.scanner.runScan();

    var server = try net.IpAddress.listen(
        &.{ .ip4 = net.Ip4Address.loopback(0) },
        io,
        .{ .reuse_address = true },
    );
    defer server.deinit(io);
    const bound_port = server.socket.address.getPort();

    var harness: FullResponseHarness = .{
        .port = bound_port,
        .io = io,
        .request = "GET /artifacts/subdir HTTP/1.1\r\nHost: localhost\r\n\r\n",
    };
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, FullResponseHarness.run, .{&harness});

    const stream = try server.accept(io);
    try handleConnection(io, stream, &scanner_ctx.scanner);
    stream.close(io);
    thread.join();

    const response = harness.response[0..harness.response_len];
    try std.testing.expect(std.mem.indexOf(u8, response, "HTTP/1.1 404 Not Found") != null);
}

test "handleConnection refuses artifact replaced by outside-root symlink" {
    // Time-of-check/time-of-use: the scanner cataloged a real plan.html, but
    // before the request opens it the file is replaced with a symlink that
    // points outside the root. The response must be 404, not the target's
    // contents, because openFile uses follow_symlinks=false and stat reports
    // sym_link (not file) so the kind check rejects it.
    const io = std.testing.io;
    var scanner_ctx = try testScanner();
    defer scanner_ctx.deinit();

    // Catalog the real plan artifact first.
    try writePlanArtifactFixture(scanner_ctx.tmp.dir, "plan.html");
    scanner_ctx.scanner.runScan();

    // Replace the file with a symlink pointing outside the root. Use a
    // second temp directory as the symlink target so the link definitely
    // escapes the served root.
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try outside.dir.writeFile("secret.txt", "outside-root secret");

    // Remove the cataloged file then create a symlink at the same path.
    scanner_ctx.tmp.dir.deleteFile(io, "plan.html") catch return error.DeleteFailed;
    scanner_ctx.tmp.dir.symLink(
        io,
        // Absolute path to the outside-root target so the link escapes the root.
        try std.fmt.allocPrint(
            std.heap.page_allocator,
            "{s}/secret.txt",
            .{outside.dir.path.?},
        ),
        "plan.html",
        .{},
    ) catch return; // symlinks may be unavailable on some platforms; skip silently.

    var server = try net.IpAddress.listen(
        &.{ .ip4 = net.Ip4Address.loopback(0) },
        io,
        .{ .reuse_address = true },
    );
    defer server.deinit(io);
    const bound_port = server.socket.address.getPort();

    var harness: FullResponseHarness = .{
        .port = bound_port,
        .io = io,
        .request = "GET /artifacts/plan.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
    };
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, FullResponseHarness.run, .{&harness});

    const stream = try server.accept(io);
    try handleConnection(io, stream, &scanner_ctx.scanner);
    stream.close(io);
    thread.join();

    const response = harness.response[0..harness.response_len];
    try std.testing.expect(std.mem.indexOf(u8, response, "HTTP/1.1 404 Not Found") != null);
    // The outside-root secret must never appear in the response.
    try std.testing.expect(std.mem.indexOf(u8, response, "outside-root secret") == null);
}

test "handleConnection serves regenerated artifact at same relative path" {
    // A valid artifact regenerated at the same safe relative path is served
    // after the next catalog refresh, without a server restart.
    const io = std.testing.io;
    var scanner_ctx = try testScanner();
    defer scanner_ctx.deinit();

    try writePlanArtifactFixture(scanner_ctx.tmp.dir, "plan.html");
    scanner_ctx.scanner.runScan();

    // Regenerate the file at the same path with different content.
    const regenerated =
        \\<!DOCTYPE html><html><head><title>Regenerated</title></head><body>
        \\<script type="application/json" id="plan-data">{"title":"New","project":"demo"}</script>
        \\</body></html>
    ;
    try scanner_ctx.tmp.dir.writeFile("plan.html", regenerated);
    scanner_ctx.scanner.runScan();

    var server = try net.IpAddress.listen(
        &.{ .ip4 = net.Ip4Address.loopback(0) },
        io,
        .{ .reuse_address = true },
    );
    defer server.deinit(io);
    const bound_port = server.socket.address.getPort();

    var harness: FullResponseHarness = .{
        .port = bound_port,
        .io = io,
        .request = "GET /artifacts/plan.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
    };
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, FullResponseHarness.run, .{&harness});

    const stream = try server.accept(io);
    try handleConnection(io, stream, &scanner_ctx.scanner);
    stream.close(io);
    thread.join();

    const response = harness.response[0..harness.response_len];
    try std.testing.expect(std.mem.indexOf(u8, response, "HTTP/1.1 200 OK") != null);

    const body_start = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.NoBodyDelimiter;
    const body = response[body_start + 4 ..];
    try std.testing.expectEqualStrings(regenerated, body);
}

test "handleConnection artifact errors omit the absolute root" {
    // No client-facing error body may disclose the configured absolute root.
    const io = std.testing.io;
    var scanner_ctx = try testScanner();
    defer scanner_ctx.deinit();

    const root_abs = scanner_ctx.tmp.dir.path.?;

    var server = try net.IpAddress.listen(
        &.{ .ip4 = net.Ip4Address.loopback(0) },
        io,
        .{ .reuse_address = true },
    );
    defer server.deinit(io);
    const bound_port = server.socket.address.getPort();

    var harness: FullResponseHarness = .{
        .port = bound_port,
        .io = io,
        .request = "GET /artifacts/missing.html HTTP/1.1\r\nHost: localhost\r\n\r\n",
    };
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, FullResponseHarness.run, .{&harness});

    const stream = try server.accept(io);
    try handleConnection(io, stream, &scanner_ctx.scanner);
    stream.close(io);
    thread.join();

    const response = harness.response[0..harness.response_len];
    try std.testing.expect(std.mem.indexOf(u8, response, "HTTP/1.1 404 Not Found") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, root_abs) == null);
}
