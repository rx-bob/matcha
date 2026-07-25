const std = @import("std");

const serve_options = @import("serve_options.zig");
const serve_catalog = @import("serve_catalog.zig");

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
