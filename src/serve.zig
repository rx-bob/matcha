const std = @import("std");

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
    // thread refreshes the snapshot on the configured interval.
    var scanner = serve_catalog.Scanner.init(
        io,
        std.heap.page_allocator,
        options.directory,
        options.interval_seconds,
        serve_catalog.scan,
    );
    scanner.initialScan();
    defer scanner.stop();

    try scanner.start();

    listen_fd = server.socket.handle;
    installShutdownHandler();

    const bound_port = server.socket.address.getPort();
    try writeStartupReport(stdout, options, bound_port);

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
) !void {
    try stdout.print(
        "matcha serve: root {s}\nmatcha serve: listening on {s}:{d} (scan interval {d}s)\n",
        .{ options.directory, options.host, bound_port, options.interval_seconds },
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

    const body = indexBody(scanner);
    try writeStatus(writer, .ok, "text/html; charset=utf-8", body);
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
/// `/artifacts/<encoded-relative-path>`. The relative path is decoded and
/// validated once via `serve_routes.parseArtifactRoute` so the request cannot
/// address files outside the configured root. The file is opened relative to
/// the scanner's root directory, sized via `stat`, and streamed through a
/// bounded buffer so memory stays bounded regardless of artifact size. The
/// body is delivered byte-for-byte without rewriting, header injection, or
/// metadata insertion; Matcha outputs remain independently self-contained.
///
/// Files that disappeared or became unreadable between catalog lookup and open
/// produce a normal 404 (or read-failure) response without affecting the
/// server. Request-time validation failures (malformed encoding, traversal,
/// absolute paths, platform separators) return 404 to avoid disclosing
/// security-sensitive routing details.
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
    }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.IsDir, error.SymLinkLoop => {
            try writeStatus(writer, .not_found, "text/plain; charset=utf-8", "not found");
            return;
        },
        else => {
            try writeStatus(writer, .not_found, "text/plain; charset=utf-8", "not found");
            return;
        },
    };
    defer file.close(io);

    // Stat to obtain an exact content length when known. If stat fails, fall
    // back to a chunked-style stream without a Content-Length header.
    const maybe_stat = file.stat(io) catch null;
    const content_length_known = maybe_stat != null;
    const content_length: u64 = if (maybe_stat) |s| s.size else 0;

    // Headers identify HTML safely and avoid stale regenerated artifacts.
    if (content_length_known) {
        try writer.print(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" ++
                "Content-Length: {d}\r\n" ++
                "{s}" ++
                "Connection: close\r\n\r\n",
            .{ content_length, artifact_extra_headers },
        );
    } else {
        try writer.print(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" ++
                "{s}" ++
                "Connection: close\r\n\r\n",
            .{artifact_extra_headers},
        );
    }

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

fn indexBody(scanner: *serve_catalog.Scanner) []const u8 {
    _ = scanner;
    return "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"UTF-8\">" ++
        "<title>matcha serve</title></head><body>" ++
        "<h1>matcha serve</h1>" ++
        "<p>Catalog is not yet available.</p>" ++
        "</body></html>";
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

test "indexBody is deterministic HTML" {
    var scanner_ctx = try testScanner();
    defer scanner_ctx.deinit();
    const body = indexBody(&scanner_ctx.scanner);
    try std.testing.expect(std.mem.startsWith(u8, body, "<!DOCTYPE html>"));
    try std.testing.expect(std.mem.indexOf(u8, body, "matcha serve") != null);
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

test "run serves minimal index at slash on loopback ephemeral port" {
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
