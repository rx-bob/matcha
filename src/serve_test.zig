const std = @import("std");

const cli = @import("cli.zig");
const serve = @import("serve.zig");
const serve_catalog = @import("serve_catalog.zig");
const serve_routes = @import("serve_routes.zig");

const net = std.Io.net;

test "serve integration workflow: catalog, artifacts, and refresh without fixed-sleep" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const plan_alpha =
        \<!DOCTYPE html><html><head><title>Plan Alpha</title></head><body>
        \<script type="application/json" id="plan-data">{"title":"Alpha", "project":"Project One", "status":"ready", "generatedAt":"2026-07-24T22:14:13Z"}</script>
        \</body></html>
    ;
    const map_beta =
        \<!DOCTYPE html><html><head><title>Nested Map</title></head><body>
        \<script type="application/json" id="map-data">{"project":"", "diagramKind":"flow"}</script>
        \</body></html>
    ;
    const plan_gamma =
        \<!DOCTYPE html><html><head><title>Gamma</title></head><body>
        \<script type="application/json" id="plan-data">{"project":""}</script>
        \</body></html>
    ;

    // Initial artifacts: one explicit-project plan, one fallback-directory map,
    // and one fallback-to-filename title plan.
    try tmp.dir.makePath("nested");
    try tmp.dir.makePath("project-one");
    try tmp.dir.writeFile("project-one/plan.html", plan_alpha);
    try tmp.dir.writeFile("nested/beta-map.html", map_beta);
    try tmp.dir.writeFile("gamma.html", plan_gamma);

    var scanner = serve_catalog.Scanner.init(io, allocator, tmp.dir.path.?, 5, serve_catalog.scan);
    scanner.initialScan();

    var state = IntegrationServeState{
        .io = io,
        .scanner = &scanner,
        .expected_requests = 6,
    };

    const server_thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, IntegrationServeState.run, .{&state});
    defer server_thread.join();

    var port: u16 = 0;
    var wait: usize = 0;
    while (wait < 1000) : (wait += 1) {
        port = state.bound_port.load(.acquire);
        if (port != 0) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expect(port != 0);

    var response_buffer: [16384]u8 = undefined;

    const root_response = try sendRequest(io, port, "/", &response_buffer);
    const root_body = bodyFromResponse(root_response);
    try std.testing.expect(std.mem.indexOf(u8, root_response, "HTTP/1.1 200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, root_body, "<div id=\"serve-root\"></div>") != null);

    const catalog_initial = try sendRequest(io, port, "/api/catalog", &response_buffer);
    const catalog_initial_body = bodyFromResponse(catalog_initial);
    try std.testing.expect(std.mem.indexOf(u8, catalog_initial, "HTTP/1.1 200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog_initial_body, "\"projects\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog_initial_body, "\"relPath\":\"project-one/plan.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog_initial_body, "\"relPath\":\"nested/beta-map.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog_initial_body, "\"relPath\":\"gamma.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog_initial_body, "\"name\":\"Project One\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog_initial_body, "\"name\":\"nested\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog_initial_body, "\"name\":\"Ungrouped\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog_initial_body, "gamma") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog_initial_body, tmp.dir.path.?) == null);

    const initial_alpha_url = try serve_routes.artifactUrl(allocator, "project-one/plan.html");
    defer allocator.free(initial_alpha_url);
    const alpha_response = try sendRequest(io, port, initial_alpha_url, &response_buffer);
    const alpha_body = bodyFromResponse(alpha_response);
    try std.testing.expect(std.mem.indexOf(u8, alpha_response, "HTTP/1.1 200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, alpha_response, "Content-Type: text/html; charset=utf-8") != null);
    try std.testing.expectEqualStrings(plan_alpha, alpha_body);

    // Add a new nested map artifact and refresh the live snapshot without waiting
    // for background intervals.
    const map_delta =
        \<!DOCTYPE html><html><head><title>Added Map</title></head><body>
        \<script type="application/json" id="map-data">{"title":"Delta","project":"Project One","diagramKind":"class"}</script>
        \</body></html>
    ;
    try tmp.dir.writeFile("nested/delta-map.html", map_delta);
    scanner.runScan();

    const catalog_after_add = try sendRequest(io, port, "/api/catalog", &response_buffer);
    const catalog_after_add_body = bodyFromResponse(catalog_after_add);
    try std.testing.expect(std.mem.indexOf(u8, catalog_after_add_body, "\"relPath\":\"nested/delta-map.html\"") != null);

    const added_url = try serve_routes.artifactUrl(allocator, "nested/delta-map.html");
    defer allocator.free(added_url);
    const added_response = try sendRequest(io, port, added_url, &response_buffer);
    const added_body = bodyFromResponse(added_response);
    try std.testing.expectEqualStrings(map_delta, added_body);

    // Remove one previously discovered artifact and refresh again.
    try tmp.dir.deleteFile("nested/beta-map.html");
    scanner.runScan();

    const catalog_after_delete = try sendRequest(io, port, "/api/catalog", &response_buffer);
    const catalog_after_delete_body = bodyFromResponse(catalog_after_delete);
    try std.testing.expect(std.mem.indexOf(u8, catalog_after_delete_body, "\"relPath\":\"nested/beta-map.html\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, catalog_after_delete_body, "\"relPath\":\"nested/delta-map.html\"") != null);

    try std.testing.expectEqual(@as(usize, 6), state.handled_requests.load(.acquire));
}

test "serve command dispatch remains non-interactive-safe for missing directory" {
    var stdout_buffer: [128]u8 = undefined;
    var stderr_buffer: [256]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try cli.runArgs(
        &.{"serve"},
        std.testing.io,
        &stdout,
        &stderr,
    );
    try std.testing.expectEqual(cli.ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Missing value for directory") != null);
}

const IntegrationServeState = struct {
    io: std.Io,
    scanner: *serve_catalog.Scanner,
    expected_requests: usize,
    handled_requests: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    bound_port: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),

    fn run(self: *IntegrationServeState) void {
        const address: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(0) };
        var server = net.IpAddress.listen(&address, self.io, .{ .reuse_address = true }) catch return;
        defer server.deinit(self.io);

        self.bound_port.store(server.socket.address.getPort(), .release);

        var handled: usize = 0;
        while (handled < self.expected_requests) {
            var stream = server.accept(self.io) catch break;
            serve.handleConnection(self.io, stream, self.scanner) catch {};
            stream.close(self.io);
            handled += 1;
        }

        self.handled_requests.store(handled, .release);
        self.scanner.stop();
    }
};

fn sendRequest(
    io: std.Io,
    port: u16,
    target: []const u8,
    buffer: []u8,
) ![]const u8 {
    const address: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(port) };
    var stream = try net.IpAddress.connect(&address, io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buffer: [256]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buffer);
    try stream_writer.interface.print(
        "GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        .{target},
    );
    try stream_writer.interface.flush();

    var read_buffer: [4096]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buffer);
    const reader = &stream_reader.interface;

    var out_index: usize = 0;
    while (out_index < buffer.len) {
        const got = reader.readSliceShort(buffer[out_index..]) catch break;
        if (got == 0) break;
        out_index += got;
    }

    return buffer[0..out_index];
}

fn bodyFromResponse(response: []const u8) []const u8 {
    const body_start = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return "";
    return response[body_start + 4 ..];
}
