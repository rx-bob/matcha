const std = @import("std");

const assets = @import("assets.zig");
const errors = @import("errors.zig");
const path = @import("path.zig");
const json_input = @import("json_input.zig");
const render_html = @import("render_html.zig");
const render_markdown = @import("render_markdown.zig");
const plan_read = @import("plan_read.zig");
const serve_options = @import("serve_options.zig");
const serve = @import("serve.zig");

pub const version = "0.1.0";

pub const ExitCode = serve_options.ExitCode;

pub const RenderOptions = struct {
    target: render_html.RenderTarget,
    input: []const u8,
    output: []const u8,
};

pub const RenderOptionsResult = union(enum) {
    ok: RenderOptions,
    err: errors.CliError,
};

pub fn run(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const args = if (argv.len > 0) argv[1..] else argv;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    const exit_code = runArgs(args, init.io, stdout, stderr) catch |err| blk: {
        try stderr.print("Internal error: {s}\n", .{@errorName(err)});
        break :blk ExitCode.failure;
    };
    try stdout.flush();
    try stderr.flush();

    if (exit_code != .ok) {
        std.process.exit(@backingInt(exit_code));
    }
}

pub fn runArgs(args: []const []const u8, io: std.Io, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !ExitCode {
    const command = if (args.len > 0) args[0] else "";

    if (isHelpCommand(command)) {
        try writeHelp(stdout);
        return .ok;
    }

    if (isVersionCommand(command)) {
        try writeVersion(stdout);
        return .ok;
    }

    if (std.mem.eql(u8, command, "usage")) {
        try writeUsageGuide(stdout);
        return .ok;
    }

    if (std.mem.eql(u8, command, "plan")) {
        if (args.len > 1 and std.mem.eql(u8, args[1], "read")) {
            return runPlanReadCommand(io, args[2..], stdout, stderr);
        }
        return runRenderCommand(.plan, io, args[1..], stdout, stderr);
    }

    if (std.mem.eql(u8, command, "map")) {
        return runRenderCommand(.map, io, args[1..], stdout, stderr);
    }

    if (std.mem.eql(u8, command, "serve")) {
        return runServeCommand(io, args[1..], stdout, stderr);
    }

    try writeHelp(stdout);
    try stdout.writeByte('\n');
    try stderr.print("Unknown command: {s}\n", .{command});
    return .usage;
}

fn isHelpCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "help") or
        std.mem.eql(u8, command, "--help") or
        std.mem.eql(u8, command, "-h");
}

fn isVersionCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "version") or
        std.mem.eql(u8, command, "--version") or
        std.mem.eql(u8, command, "-V");
}

pub fn writeVersion(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("matcha {s}\n", .{version});
}

fn runRenderCommand(
    target: render_html.RenderTarget,
    io: std.Io,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !ExitCode {
    if (args.len > 0 and isHelpCommand(args[0])) {
        switch (target) {
            .plan => try writePlanHelp(stdout),
            .map => try writeMapHelp(stdout),
        }
        return .ok;
    }

    var options: RenderOptions = switch (parseRenderOptions(target, args)) {
        .ok => |parsed| parsed,
        .err => |cli_error| {
            try writeCliError(stderr, cli_error);
            return .usage;
        },
    };

    switch (normalizeRenderPaths(std.heap.page_allocator, &options)) {
        .ok => {},
        .err => |cli_error| {
            try writeCliError(stderr, cli_error);
            return .usage;
        },
    }

    if (!prepareOutputDirectory(io, stderr, options.output)) {
        return .failure;
    }

    var document = json_input.readJsonDocument(io, std.heap.page_allocator, options.input) catch |err| {
        const cli_error: errors.CliError = switch (err) {
            json_input.DocumentParseError.CannotReadInput => .{ .cannot_read_input = options.input },
            json_input.DocumentParseError.InvalidJson => .{ .invalid_json = options.input },
            json_input.DocumentParseError.OutOfMemory => return error.OutOfMemory,
        };
        try writeCliError(stderr, cli_error);
        return .failure;
    };
    defer document.deinit();

    switch (target) {
        .plan => try render_html.writePlanHtml(io, options.output, document.title, document.raw),
        .map => try render_html.writeMapHtml(io, options.output, document.title, document.raw),
    }
    try stdout.print("Wrote {s}\n", .{options.output});
    return .ok;
}

fn runPlanReadCommand(
    io: std.Io,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !ExitCode {
    var document = plan_read.parsePlanReadInput(io, std.heap.page_allocator, args) catch |err| {
        switch (err) {
            plan_read.PlanReadError.missing_path, plan_read.PlanReadError.extra_arguments, plan_read.PlanReadError.invalid_argument => {
                try stderr.print("Usage: matcha plan read <path>\n", .{});
                return .usage;
            },
            plan_read.PlanReadError.missing_home => {
                try stderr.print("Cannot expand input path: HOME and USERPROFILE are not set\n", .{});
                return .failure;
            },
            plan_read.PlanReadError.cannot_read_input => {
                const input_path = if (args.len > 0) args[0] else "<path>";
                try stderr.print("Cannot read {s}\n", .{input_path});
                return .failure;
            },
            plan_read.PlanReadError.unsupported_input => {
                try stderr.print("Unsupported input: {s}\n", .{if (args.len > 0) args[0] else "<path>"});
                return .failure;
            },
            plan_read.PlanReadError.invalid_json => {
                try stderr.print("Invalid JSON in {s}\n", .{if (args.len > 0) args[0] else "<path>"});
                return .failure;
            },
            plan_read.PlanReadError.out_of_memory => {
                return .failure;
            },
        }
    };
    defer document.deinit();

    const markdown = render_markdown.renderPlanMarkdown(std.heap.page_allocator, document.data) catch |err| switch (err) {
        render_markdown.RenderError.NotAnObject => {
            try stderr.print("Invalid plan document: expected JSON object\n", .{});
            return .failure;
        },
        render_markdown.RenderError.OutOfMemory => {
            return .failure;
        },
    };
    defer std.heap.page_allocator.free(markdown);

    try stdout.print("{s}\n", .{markdown});
    return .ok;
}

fn runServeCommand(
    io: std.Io,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !ExitCode {
    if (args.len > 0 and isHelpCommand(args[0])) {
        try writeServeHelp(stdout);
        return .ok;
    }

    var stdin_acquirer = stdinDirectoryAcquirer(io);
    return runServeCommandAcquired(io, args, stdout, stderr, stdin_acquirer.acquirer(), realServerRunner());
}

/// Injectable server runner so command dispatch can be exercised without
/// starting a real blocking listener.
pub const ServerRunner = struct {
    context: *anyopaque,
    runFn: *const fn (context: *anyopaque, io: std.Io, options: serve_options.ServeOptions, stdout: *std.Io.Writer, stderr: *std.Io.Writer) anyerror!ExitCode,

    pub fn run(
        self: ServerRunner,
        io: std.Io,
        options: serve_options.ServeOptions,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) anyerror!ExitCode {
        return self.runFn(self.context, io, options, stdout, stderr);
    }
};

var real_runner_storage: RealServerRunner = .{};

fn realServerRunner() ServerRunner {
    return .{
        .context = @ptrCast(&real_runner_storage),
        .runFn = RealServerRunner.run,
    };
}

const RealServerRunner = struct {
    fn run(
        context: *anyopaque,
        io: std.Io,
        options: serve_options.ServeOptions,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) anyerror!ExitCode {
        _ = context;
        return serve.run(io, options, stdout, stderr);
    }
};

fn runServeCommandAcquired(
    io: std.Io,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    acquirer: DirectoryAcquirer,
    runner: ServerRunner,
) !ExitCode {
    if (args.len > 0 and isHelpCommand(args[0])) {
        try writeServeHelp(stdout);
        return .ok;
    }

    var options: serve_options.ServeOptions = switch (serve_options.parseServeOptions(std.heap.page_allocator, args)) {
        .ok => |parsed| parsed,
        .err => |cli_error| {
            try writeCliError(stderr, cli_error);
            try writeServeUsage(stderr);
            return .usage;
        },
    };
    _ = &options;

    if (!options.directory_set) {
        switch (acquireServeDirectory(acquirer, stdout, stderr)) {
            .ok => |entered| options.directory = entered,
            .err => |cli_error| {
                try writeCliError(stderr, cli_error);
                try writeServeUsage(stderr);
                return .usage;
            },
        }
    }

    if (!serve_options.validateDirectory(io, options.directory)) {
        try writeCliError(stderr, .{ .not_a_directory = options.directory });
        return .usage;
    }

    return runner.run(io, options, stdout, stderr);
}

/// Outcome of acquiring a serve directory interactively or from arguments.
pub const DirectoryAcquireResult = union(enum) {
    ok: []const u8,
    err: errors.CliError,
};

/// Injectable source for interactive directory acquisition.
pub const DirectoryAcquirer = struct {
    context: *anyopaque,
    isInteractiveFn: *const fn (context: *anyopaque) bool,
    readLineFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator) DirectoryAcquireResult,

    pub fn isInteractive(self: DirectoryAcquirer) bool {
        return self.isInteractiveFn(self.context);
    }

    pub fn readLine(self: DirectoryAcquirer, allocator: std.mem.Allocator) DirectoryAcquireResult {
        return self.readLineFn(self.context, allocator);
    }
};

/// Acquire a serve directory when one was not supplied on the command line.
///
/// Non-interactive invocations return a `missing_value` error immediately so the
/// caller can print usage and exit without blocking on stdin. Interactive
/// invocations prompt once, accept home-relative paths, and treat an empty
/// response or end-of-file as a clear failure rather than re-prompting.
pub fn acquireServeDirectory(
    acquirer: DirectoryAcquirer,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) DirectoryAcquireResult {
    _ = stderr;
    if (!acquirer.isInteractive()) {
        return .{ .err = .{ .missing_value = "directory" } };
    }

    stdout.writeAll("Directory to serve: ") catch return .{ .err = .{ .path_error = "" } };

    const entered = acquirer.readLine(std.heap.page_allocator);
    return switch (entered) {
        .ok => |line| blk: {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) break :blk .{ .err = .{ .missing_value = "directory" } };
            const expanded = path.expandHomePath(std.heap.page_allocator, trimmed) catch |err| switch (err) {
                error.MissingHome => break :blk .{ .err = .{ .missing_home = trimmed } },
                else => break :blk .{ .err = .{ .path_error = trimmed } },
            };
            break :blk .{ .ok = expanded };
        },
        .err => |e| .{ .err = e },
    };
}

const StdinDirectoryAcquirer = struct {
    io: std.Io,
    reader: *std.Io.File.Reader,

    fn isInteractiveImpl(context: *anyopaque) bool {
        const self: *StdinDirectoryAcquirer = @ptrCast(@alignCast(context));
        return std.Io.File.stdin().isTty(self.io) catch false;
    }

    fn readLineImpl(context: *anyopaque, allocator: std.mem.Allocator) DirectoryAcquireResult {
        const self: *StdinDirectoryAcquirer = @ptrCast(@alignCast(context));
        const line = self.reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return .{ .err = .{ .missing_value = "directory" } },
            else => return .{ .err = .{ .path_error = "" } },
        };
        return .{ .ok = allocator.dupe(u8, line) catch return .{ .err = .{ .path_error = "" } } };
    }

    fn acquirer(self: *StdinDirectoryAcquirer) DirectoryAcquirer {
        return .{
            .context = @ptrCast(self),
            .isInteractiveFn = StdinDirectoryAcquirer.isInteractiveImpl,
            .readLineFn = StdinDirectoryAcquirer.readLineImpl,
        };
    }
};

var stdin_reader_storage: std.Io.File.Reader = undefined;

fn stdinDirectoryAcquirer(io: std.Io) StdinDirectoryAcquirer {
    stdin_reader_storage = std.Io.File.Reader.init(.stdin(), io, &stdin_line_buffer);
    return .{
        .io = io,
        .reader = &stdin_reader_storage,
    };
}

var stdin_line_buffer: [4096]u8 = undefined;

fn writeServeUsage(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("Usage: matcha serve <directory> [--host <host>] [--port <port>] [--interval <seconds>]\n");
}

pub fn writeServeHelp(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(
        \\matcha serve
        \\
        \\Usage:
        \\  matcha serve <directory> [options]
        \\
        \\Serve generated Matcha HTML plans and maps from <directory> as a
        \\read-only catalog and artifact browser.
        \\
        \\Arguments:
        \\  <directory>          Root directory to scan for Matcha artifacts
        \\
        \\Behavior:
        \\  - Only regular .html files are considered.
        \\  - Markers determine artifact type:
        \\      plan:  <script id="plan-data" ...>
        \\      map:   <script id="map-data" ...>
        \\    Non-marked HTML is ignored.
        \\  - Scanning is recursive and groups entries by:
        \\      embedded project metadata, then first path segment, then Ungrouped.
        \\  - Artifact routes are read-only:
        \\      /artifacts/<url-encoded-relative-path>
        \\  - Directory is scanned at startup and every 5 seconds by default.
        \\Options:
        \\  --host <host>        Bind address (default: 0.0.0.0)
        \\  --port <port>        Bind port (default: 27004)
        \\  --interval <seconds> Catalog refresh interval in seconds (default: 5)
        \\
        \\The --host, --port, and --interval options accept either a space-separated
        \\value (--port 27004) or an equals-style value (--port=27004).
        \\
        \\By default, --host 0.0.0.0 binds every interface, so peers on your local
        \\network can browse artifacts. Use --host 127.0.0.1 for loopback-only access.
        \\
        \\If no <directory> is provided and this is an interactive terminal, the
        \\command prompts for one path. In non-interactive mode it exits immediately
        \\with usage.
        \\
        \\Examples:
        \\  matcha serve ./artifacts
        \\  matcha serve ~/artifacts --host 127.0.0.1 --port 8080 --interval 10
        \\
    );
}

fn normalizeRenderPaths(allocator: std.mem.Allocator, options: *RenderOptions) RenderOptionsResult {
    options.input = path.expandHomePath(allocator, options.input) catch |err| {
        switch (err) {
            error.MissingHome => return RenderOptionsResult{ .err = .{ .missing_home = options.input } },
            else => return RenderOptionsResult{ .err = .{ .path_error = options.input } },
        }
    };
    options.output = path.expandHomePath(allocator, options.output) catch |err| {
        switch (err) {
            error.MissingHome => return RenderOptionsResult{ .err = .{ .missing_home = options.output } },
            else => return RenderOptionsResult{ .err = .{ .path_error = options.output } },
        }
    };
    return RenderOptionsResult{ .ok = options.* };
}

fn prepareOutputDirectory(io: std.Io, stderr: *std.Io.Writer, output: []const u8) bool {
    const output_parent = path.parentDirectory(output) orelse return true;
    std.Io.Dir.cwd().createDirPath(io, output_parent) catch |err| {
        stderr.print("Cannot create output directory {s}: {s}\n", .{
            output_parent,
            @errorName(err),
        }) catch return false;
        return false;
    };
    return true;
}

pub fn parseRenderOptions(target: render_html.RenderTarget, args: []const []const u8) RenderOptionsResult {
    var options: RenderOptions = .{
        .target = target,
        .input = render_html.defaultInput(target),
        .output = render_html.defaultOutput(target),
    };

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-i")) {
            index += 1;
            options.input = readFlagValue(args, index) orelse return .{ .err = .{ .missing_value = arg } };
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--input=")) {
            options.input = arg["--input=".len..];
            continue;
        }

        if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            index += 1;
            options.output = readFlagValue(args, index) orelse return .{ .err = .{ .missing_value = arg } };
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--output=")) {
            options.output = arg["--output=".len..];
            continue;
        }

        return .{ .err = .{ .unknown_option = arg } };
    }

    return .{ .ok = options };
}

fn readFlagValue(args: []const []const u8, index: usize) ?[]const u8 {
    if (index >= args.len or std.mem.startsWith(u8, args[index], "-")) {
        return null;
    }

    return args[index];
}

fn writeCliError(writer: *std.Io.Writer, cli_error: errors.CliError) std.Io.Writer.Error!void {
    return errors.writeCliError(writer, cli_error);
}

pub fn writeHelp(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(
        \\matcha
        \\
        \\Usage:
        \\  matcha [command] [options]
        \\
        \\Commands:
        \\  help, --help, -h  Show this help text
        \\  usage            Explain CLI usage and input formats for LLMs
        \\  version          Show the CLI version
        \\  plan             Render a plan based on the given input
        \\  map              Render a map based on the given input
        \\  serve            Serve generated Matcha HTML artifacts on the local network
        \\
        \\Plan commands:
        \\  matcha plan --help              Show detailed help for plan rendering
        \\  matcha plan read <path>         Print a matcha plan as Markdown to stdout
        \\
        \\Map commands:
        \\  matcha map --help               Show detailed help for map rendering
        \\
        \\Serve commands:
        \\  matcha serve --help             Show detailed help for serve mode
        \\
        \\Options:
        \\  -i, --input <path>    JSON file to render
        \\  -o, --output <path>   HTML file to write
        \\
    );
}

pub fn writePlanHelp(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(
        \\matcha plan
        \\
        \\Usage:
        \\  matcha plan [options]
        \\  matcha plan read <path>
        \\
        \\Render a plan JSON file to a self-contained HTML page. Without --input, it reads
        \\sample_plan.json; without --output, it writes dist/plan.html.
        \\
        \\Options:
        \\  -i, --input <path>    Plan JSON file to render
        \\  -o, --output <path>   HTML file to write
        \\
        \\Read subcommand:
        \\  matcha plan read <path>  Print a matcha plan as Markdown to stdout. The path can be
        \\                        raw plan JSON or a matcha-generated plan HTML file.
        \\
        \\Plan input format:
        \\
    );
    try writeIndentedTrimmed(writer, assets.llm_output_format.contents);
}

pub fn writeMapHelp(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(
        \\matcha map
        \\
        \\Usage:
        \\  matcha map [options]
        \\
        \\Render a UML-style map JSON file to a self-contained HTML page. Without --input,
        \\it reads sample_map.json; without --output, it writes dist/map.html.
        \\
        \\Options:
        \\  -i, --input <path>    Map JSON file to render
        \\  -o, --output <path>   HTML file to write
        \\
        \\Map input format:
        \\
    );
    try writeIndentedTrimmed(writer, assets.llm_uml_output_format.contents);
}

pub fn writeUsageGuide(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(
        \\matcha usage for LLMs
        \\
        \\Purpose:
        \\  matcha turns structured JSON into self-contained HTML artifacts.
        \\  Use "matcha plan" for implementation plans.
        \\  Use "matcha map" for semantic UML-style diagrams.
        \\
        \\Commands:
        \\  matcha plan --input path/to/plan.json --output path/to/plan.html
        \\  matcha map --input path/to/map.json --output path/to/map.html
        \\  matcha plan read path/to/plan.json          Print Markdown to stdout
        \\  matcha plan read path/to/plan.html          Read a matcha-generated plan HTML back as Markdown
        \\
        \\Defaults:
        \\  matcha plan reads sample_plan.json and writes dist/plan.html.
        \\  matcha map reads sample_map.json and writes dist/map.html.
        \\
        \\Path rules:
        \\  --input is a JSON file matching the selected command format.
        \\  --output is the HTML file to write.
        \\  Parent directories for --output are created automatically.
        \\  Quoted home paths such as "~/clankers/file.html" are expanded by matcha.
        \\
        \\LLM workflow:
        \\  1. Decide whether the requested artifact is a plan or map.
        \\  2. Produce exactly one valid JSON object matching the format below.
        \\  3. Save that JSON to a file.
        \\  4. Run the matching matcha command with --input and --output.
        \\  5. Do not put Markdown fences or commentary in the JSON input file.
        \\  6. To read an existing plan as Markdown, run `matcha plan read <path>`.
        \\  7. No --output option exists for plan read; redirect stdout (`> plan.md`) or pipe it.
        \\
        \\Reading plans as Markdown:
        \\  Use `matcha plan read` when you need to consume an existing plan without parsing JSON or
        \\  scraping rendered HTML. The command is deterministic, offline, and writes to stdout only.
        \\
        \\Plan input format:
        \\
    );
    try writeIndentedTrimmed(writer, assets.llm_output_format.contents);
    try writer.writeAll(
        \\
        \\Map input format:
        \\
    );
    try writeIndentedTrimmed(writer, assets.llm_uml_output_format.contents);
    try writer.writeByte('\n');
}

fn writeIndentedTrimmed(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |line| {
        try writer.writeAll("  ");
        try writer.writeAll(std.mem.trim(u8, line, "\r"));
        try writer.writeByte('\n');
    }
}

test "command module imports all CLI responsibility modules" {
    try std.testing.expectEqualStrings("plan.js", assets.plan_js.name);
    try std.testing.expect(path.isHomeRelative("~/sample_plan.json"));
    try std.testing.expectEqualStrings("dist/plan.html", render_html.defaultOutput(.plan));
    try std.testing.expectEqualStrings("# ", render_markdown.headingPrefix(.plan));
}

test "root help aliases print help" {
    const aliases = [_][]const u8{ "help", "--help", "-h" };

    for (aliases) |alias| {
        var stdout_buffer: [2048]u8 = undefined;
        var stderr_buffer: [128]u8 = undefined;
        var stdout: std.Io.Writer = .fixed(&stdout_buffer);
        var stderr: std.Io.Writer = .fixed(&stderr_buffer);
        const code = try runArgs(&.{alias}, std.testing.io, &stdout, &stderr);
        const output = stdout_buffer[0..stdout.end];

        try std.testing.expectEqual(ExitCode.ok, code);
        try std.testing.expect(std.mem.indexOf(u8, output, "matcha plan --help") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "matcha map --help") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "help, --help, -h") != null);
        try std.testing.expectEqual(@as(usize, 0), stderr.end);
    }
}

test "root version aliases print current CLI version" {
    const aliases = [_][]const u8{ "version", "--version", "-V" };

    for (aliases) |alias| {
        var stdout_buffer: [64]u8 = undefined;
        var stderr_buffer: [128]u8 = undefined;
        var stdout: std.Io.Writer = .fixed(&stdout_buffer);
        var stderr: std.Io.Writer = .fixed(&stderr_buffer);
        const code = try runArgs(&.{alias}, std.testing.io, &stdout, &stderr);

        try std.testing.expectEqual(ExitCode.ok, code);
        try std.testing.expectEqualStrings("matcha 0.1.0\n", stdout_buffer[0..stdout.end]);
        try std.testing.expectEqual(@as(usize, 0), stderr.end);
    }
}

test "usage includes embedded plan and map format instructions" {
    var stdout_buffer: [32768]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const code = try runArgs(&.{"usage"}, std.testing.io, &stdout, &stderr);
    const output = stdout_buffer[0..stdout.end];

    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, output, "matcha usage for LLMs") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Plan input format:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  Plan input format") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Map input format:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  Map input format") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.end);
}

test "render command defaults match current CLI" {
    const plan_options = expectRenderOptions(parseRenderOptions(.plan, &.{}));
    try std.testing.expectEqual(render_html.RenderTarget.plan, plan_options.target);
    try std.testing.expectEqualStrings("sample_plan.json", plan_options.input);
    try std.testing.expectEqualStrings("dist/plan.html", plan_options.output);

    const map_options = expectRenderOptions(parseRenderOptions(.map, &.{}));
    try std.testing.expectEqual(render_html.RenderTarget.map, map_options.target);
    try std.testing.expectEqualStrings("sample_map.json", map_options.input);
    try std.testing.expectEqualStrings("dist/map.html", map_options.output);
}

test "render command parses separated input and output flags" {
    const plan_options = expectRenderOptions(parseRenderOptions(.plan, &.{
        "-i",
        "plans/input.json",
        "-o",
        "dist/custom-plan.html",
    }));
    try std.testing.expectEqualStrings("plans/input.json", plan_options.input);
    try std.testing.expectEqualStrings("dist/custom-plan.html", plan_options.output);

    const map_options = expectRenderOptions(parseRenderOptions(.map, &.{
        "--input",
        "maps/input.json",
        "--output",
        "dist/custom-map.html",
    }));
    try std.testing.expectEqualStrings("maps/input.json", map_options.input);
    try std.testing.expectEqualStrings("dist/custom-map.html", map_options.output);
}

test "render command parses equals-style input and output flags" {
    const plan_options = expectRenderOptions(parseRenderOptions(.plan, &.{
        "--input=plans/input.json",
        "--output=dist/custom-plan.html",
    }));
    try std.testing.expectEqualStrings("plans/input.json", plan_options.input);
    try std.testing.expectEqualStrings("dist/custom-plan.html", plan_options.output);

    const map_options = expectRenderOptions(parseRenderOptions(.map, &.{
        "--output=dist/custom-map.html",
        "--input=maps/input.json",
    }));
    try std.testing.expectEqualStrings("maps/input.json", map_options.input);
    try std.testing.expectEqualStrings("dist/custom-map.html", map_options.output);
}

test "plan read accepts raw JSON input path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const input_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/plan.json", .{tmp.dir.path.?});
    defer std.testing.allocator.free(input_path);
    try tmp.dir.writeFile("plan.json", "{\"title\":\"Raw JSON Plan\",\"schemaVersion\":1}\n");

    var stdout_buffer: [256]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "plan", "read", input_path }, std.testing.io, &stdout, &stderr);
    const output = stdout_buffer[0..stdout.end];

    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, output, "# Raw JSON Plan") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "- **Schema Version:** 1") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.end);
}

test "plan read accepts generated plan HTML input path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const input_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/plan.html", .{tmp.dir.path.?});
    defer std.testing.allocator.free(input_path);
    try tmp.dir.writeFile("plan.html",
        \\<html><body>
        \\  <script type="application/json" id="plan-data">
        \\    {"title":"HTML Fixture","schemaVersion":1}
        \\  </script>
        \\</body></html>
    );

    var stdout_buffer: [256]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "plan", "read", input_path }, std.testing.io, &stdout, &stderr);
    const output = stdout_buffer[0..stdout.end];

    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, output, "# HTML Fixture") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.end);
}

test "plan read rejects missing and extra arguments with usage" {
    var stdout_buffer: [256]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const missing_arg_code = try runArgs(&.{ "plan", "read" }, std.testing.io, &stdout, &stderr);
    try std.testing.expectEqual(ExitCode.usage, missing_arg_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Usage: matcha plan read <path>") != null);

    stdout.end = 0;
    stderr.end = 0;
    const extra_arg_code = try runArgs(
        &.{ "plan", "read", "one.json", "two.json" },
        std.testing.io,
        &stdout,
        &stderr,
    );
    try std.testing.expectEqual(ExitCode.usage, extra_arg_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Usage: matcha plan read <path>") != null);
    try std.testing.expectEqual(@as(usize, 0), stdout.end);
}

test "plan read rejects unsupported non-json non-plan-html input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const input_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/unsupported.txt", .{tmp.dir.path.?});
    defer std.testing.allocator.free(input_path);
    try tmp.dir.writeFile("unsupported.txt", "this is not json or plan html");

    var stdout_buffer: [256]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "plan", "read", input_path }, std.testing.io, &stdout, &stderr);
    try std.testing.expectEqual(ExitCode.failure, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Unsupported input:") != null);
    try std.testing.expectEqual(@as(usize, 0), stdout.end);
}

test "plan read rejects flag-like arguments" {
    var stdout_buffer: [256]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "plan", "read", "--output", "ignored.md" }, std.testing.io, &stdout, &stderr);

    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Usage: matcha plan read <path>") != null);
    try std.testing.expectEqual(@as(usize, 0), stdout.end);
}

test "plan read fixture output is stable and stdout-only" {
    const allocator = std.testing.allocator;

    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);

    const sample_plan_path = try std.fmt.allocPrint(allocator, "{s}/sample_plan.json", .{cwd});
    defer allocator.free(sample_plan_path);

    const expected_path = try std.fmt.allocPrint(allocator, "{s}/testdata/sample_plan.md", .{cwd});
    defer allocator.free(expected_path);

    const expected_markdown = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        expected_path,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(expected_markdown);

    const plan_contents = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        sample_plan_path,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(plan_contents);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const input_path = try std.fmt.allocPrint(allocator, "{s}/sample_plan.json", .{tmp.dir.path.?});
    defer allocator.free(input_path);
    try tmp.dir.writeFile("sample_plan.json", plan_contents);

    var start_count: usize = 0;
    var initial_entry_iterator = tmp.dir.iterate();
    while (try initial_entry_iterator.next()) |_| {
        start_count += 1;
    }

    var stdout_buffer: [131072]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    try std.testing.expect(expected_markdown.len < stdout_buffer.len);

    const first_code = try runArgs(&.{ "plan", "read", input_path }, std.testing.io, &stdout, &stderr);
    const first_output = stdout_buffer[0..stdout.end];
    try std.testing.expectEqual(ExitCode.ok, first_code);
    try std.testing.expectEqual(@as(usize, 0), stderr.end);
    try std.testing.expectEqualStrings(expected_markdown, first_output);

    stdout.end = 0;
    stderr.end = 0;
    const second_code = try runArgs(&.{ "plan", "read", input_path }, std.testing.io, &stdout, &stderr);
    const second_output = stdout_buffer[0..stdout.end];
    try std.testing.expectEqual(ExitCode.ok, second_code);
    try std.testing.expectEqualStrings(first_output, second_output);
    try std.testing.expectEqual(@as(usize, 0), stderr.end);

    var final_entry_iterator = tmp.dir.iterate();
    var final_count: usize = 0;
    while (try final_entry_iterator.next()) |_| {
        final_count += 1;
    }

    try std.testing.expectEqual(start_count, final_count);
}

test "render command rejects missing flag values" {
    try expectMissingValue("-i", parseRenderOptions(.plan, &.{"-i"}));
    try expectMissingValue("--input", parseRenderOptions(.plan, &.{ "--input", "--output", "dist/plan.html" }));
    try expectMissingValue("-o", parseRenderOptions(.map, &.{"-o"}));
    try expectMissingValue("--output", parseRenderOptions(.map, &.{ "--output", "-i", "sample_map.json" }));
}

test "render command rejects unknown options" {
    try expectUnknownOption("--theme", parseRenderOptions(.plan, &.{ "--theme", "dracula" }));
    try expectUnknownOption("sample_map.json", parseRenderOptions(.map, &.{"sample_map.json"}));
}

test "runArgs reports render option errors to stderr" {
    var stdout_buffer: [2048]u8 = undefined;
    var stderr_buffer: [256]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "plan", "--wat" }, std.testing.io, &stdout, &stderr);

    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expectEqual(@as(usize, 0), stdout.end);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Unknown option: --wat") != null);
}

test "render command help aliases print subcommand help" {
    var stdout_buffer: [32768]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const plan_code = try runArgs(&.{ "plan", "--help" }, std.testing.io, &stdout, &stderr);
    const plan_output = stdout_buffer[0..stdout.end];
    try std.testing.expectEqual(ExitCode.ok, plan_code);
    try std.testing.expect(std.mem.indexOf(u8, plan_output, "matcha plan") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_output, "Plan input format:") != null);

    stdout = .fixed(&stdout_buffer);
    stderr = .fixed(&stderr_buffer);
    const map_code = try runArgs(&.{ "map", "-h" }, std.testing.io, &stdout, &stderr);
    const map_output = stdout_buffer[0..stdout.end];
    try std.testing.expectEqual(ExitCode.ok, map_code);
    try std.testing.expect(std.mem.indexOf(u8, map_output, "matcha map") != null);
    try std.testing.expect(std.mem.indexOf(u8, map_output, "Map input format:") != null);
}

test "unknown root command prints help then error and exits non-zero" {
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [256]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{"nope"}, std.testing.io, &stdout, &stderr);
    const output = stdout_buffer[0..stdout.end];
    const error_output = stderr_buffer[0..stderr.end];

    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, output, "Commands:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "usage            Explain CLI usage and input formats for LLMs") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_output, "Unknown command: nope") != null);
}

test "runArgs validates input file JSON before writing output" {
    const work_dir = "/tmp/matcha-zig-e2s4";
    const valid_input = "/tmp/matcha-zig-e2s4/valid.json";
    const output_path = "/tmp/matcha-zig-e2s4/nested/plan.html";

    defer std.fs.cwd().deleteTree(work_dir) catch {};
    std.fs.cwd().deleteTree(work_dir) catch {};
    try std.fs.cwd().makePath(work_dir);

    var input_file = try std.fs.cwd().createFile(valid_input, .{ .truncate = true });
    defer input_file.close();
    try input_file.writeAll("{}");

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "plan", "--input", valid_input, "--output", output_path }, std.testing.io, &stdout, &stderr);

    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer[0..stdout.end], "Wrote " ++ output_path) != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.end);
}

test "runArgs reports missing input files as user-facing errors" {
    const missing_input = "/tmp/matcha-zig-e2s4/missing.json";
    const output_path = "/tmp/matcha-zig-e2s4/output.html";

    defer std.fs.cwd().deleteTree("/tmp/matcha-zig-e2s4") catch {};
    try std.fs.cwd().makePath("/tmp/matcha-zig-e2s4");

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [256]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "plan", "--input", missing_input, "--output", output_path }, std.testing.io, &stdout, &stderr);

    try std.testing.expectEqual(ExitCode.failure, code);
    try std.testing.expectEqual(@as(usize, 0), stdout.end);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Cannot read ") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], missing_input) != null);
}

test "runArgs reports invalid JSON as user-facing errors" {
    const work_dir = "/tmp/matcha-zig-e2s4";
    const invalid_input = "/tmp/matcha-zig-e2s4/invalid.json";
    const output_path = "/tmp/matcha-zig-e2s4/invalid-output.html";

    defer std.fs.cwd().deleteTree(work_dir) catch {};
    std.fs.cwd().deleteTree(work_dir) catch {};
    try std.fs.cwd().makePath(work_dir);

    var input_file = try std.fs.cwd().createFile(invalid_input, .{ .truncate = true });
    defer input_file.close();
    try input_file.writeAll("not json");

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [256]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "plan", "--input", invalid_input, "--output", output_path }, std.testing.io, &stdout, &stderr);

    try std.testing.expectEqual(ExitCode.failure, code);
    try std.testing.expectEqual(@as(usize, 0), stdout.end);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Invalid JSON in ") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], invalid_input) != null);
}

test "runArgs uses default plan path contract in temporary working directory" {
    const allocator = std.testing.allocator;

    const original_cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(original_cwd);

    const sample_plan_path = try std.fmt.allocPrint(allocator, "{s}/sample_plan.json", .{original_cwd});
    defer allocator.free(sample_plan_path);
    const sample_plan = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        sample_plan_path,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(sample_plan);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}", .{tmp.dir.path.?});
    defer allocator.free(tmp_path);

    try tmp.dir.writeFile("sample_plan.json", sample_plan);
    defer _ = std.Io.chdir(original_cwd) catch {};
    try std.Io.chdir(tmp_path);

    var stdout_buffer: [256]u8 = undefined;
    var stderr_buffer: [64]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{"plan"}, std.testing.io, &stdout, &stderr);
    const output = stdout_buffer[0..stdout.end];

    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, output, "Wrote dist/plan.html") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.end);

    var file = try std.Io.Dir.cwd().openFile("dist/plan.html", .{});
    defer file.close();
    const html = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "<title>SwiftUI Calculator Implementation Plan</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"plan-data\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "window.PLAN_DATA") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "matcha-plan-theme") != null);
}

test "runArgs uses default map path contract in temporary working directory" {
    const allocator = std.testing.allocator;

    const original_cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(original_cwd);

    const sample_map_path = try std.fmt.allocPrint(allocator, "{s}/sample_map.json", .{original_cwd});
    defer allocator.free(sample_map_path);
    const sample_map = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        sample_map_path,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(sample_map);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}", .{tmp.dir.path.?});
    defer allocator.free(tmp_path);

    try tmp.dir.writeFile("sample_map.json", sample_map);
    defer _ = std.Io.chdir(original_cwd) catch {};
    try std.Io.chdir(tmp_path);

    var stdout_buffer: [256]u8 = undefined;
    var stderr_buffer: [64]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{"map"}, std.testing.io, &stdout, &stderr);
    const output = stdout_buffer[0..stdout.end];

    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, output, "Wrote dist/map.html") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.end);

    var file = try std.Io.Dir.cwd().openFile("dist/map.html", .{});
    defer file.close();
    const html = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "<title>Matcha Plan And Map Renderer</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"map-data\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "window.MAP_DATA") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "matcha-map-theme") != null);
}

test "runArgs explicit input/output paths for plan and map write expected HTML markers" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = tmp.dir.path.?;
    const plan_input = try std.fmt.allocPrint(allocator, "{s}/plan-input.json", .{root});
    defer allocator.free(plan_input);
    const plan_output = try std.fmt.allocPrint(allocator, "{s}/nested/plan-output.html", .{root});
    defer allocator.free(plan_output);
    const map_input = try std.fmt.allocPrint(allocator, "{s}/map-input.json", .{root});
    defer allocator.free(map_input);
    const map_output = try std.fmt.allocPrint(allocator, "{s}/nested/map-output.html", .{root});
    defer allocator.free(map_output);

    const plan_input_file = try tmp.dir.createFile("plan-input.json", .{ .truncate = true });
    defer plan_input_file.close();
    try plan_input_file.writeAll("{\"title\":\"Plan Explicit Fixture\",\"schemaVersion\":1}\n");

    const map_input_file = try tmp.dir.createFile("map-input.json", .{ .truncate = true });
    defer map_input_file.close();
    try map_input_file.writeAll("{\"title\":\"Map Explicit Fixture\",\"schemaVersion\":1,\"diagramKind\":\"mixed\"}\n");

    var stdout_buffer: [256]u8 = undefined;
    var stderr_buffer: [64]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const plan_code = try runArgs(&.{ "plan", "--input", plan_input, "--output", plan_output }, std.testing.io, &stdout, &stderr);
    try std.testing.expectEqual(ExitCode.ok, plan_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer[0..stdout.end], "Wrote " ++ plan_output) != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.end);

    const plan_file = try std.Io.Dir.openFileAbsolute(std.testing.io, plan_output, .{});
    defer plan_file.close();
    const plan_html = try plan_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(plan_html);
    try std.testing.expect(std.mem.indexOf(u8, plan_html, "<title>Plan Explicit Fixture</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_html, "id=\"sidebar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_html, "window.PLAN_DATA") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_html, "matcha-plan-theme") != null);

    stdout = .fixed(&stdout_buffer);
    stderr = .fixed(&stderr_buffer);
    const map_code = try runArgs(&.{ "map", "--input", map_input, "--output", map_output }, std.testing.io, &stdout, &stderr);
    try std.testing.expectEqual(ExitCode.ok, map_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer[0..stdout.end], "Wrote " ++ map_output) != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.end);

    const map_file = try std.Io.Dir.openFileAbsolute(std.testing.io, map_output, .{});
    defer map_file.close();
    const map_html = try map_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(map_html);
    try std.testing.expect(std.mem.indexOf(u8, map_html, "<title>Map Explicit Fixture</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, map_html, "id=\"map-root\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, map_html, "window.MAP_DATA") != null);
    try std.testing.expect(std.mem.indexOf(u8, map_html, "matcha-map-theme") != null);
}

test "serve --help prints subcommand help" {
    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "serve", "--help" }, std.testing.io, &stdout, &stderr);
    const output = stdout_buffer[0..stdout.end];
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, output, "matcha serve") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Usage:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--host") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--port") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--interval") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "27004") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "default: 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "plan-data") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "map-data") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "0.0.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "127.0.0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "read-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Ungrouped") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.end);
}

test "serve -h alias prints subcommand help" {
    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "serve", "-h" }, std.testing.io, &stdout, &stderr);
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer[0..stdout.end], "matcha serve") != null);
}

test "serve accepts a real directory and reports validation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var runner = FakeServerRunner{};
    const code = try runServeCommandAcquired(
        std.testing.io,
        &.{tmp.dir.path.?},
        &stdout,
        &stderr,
        nonInteractiveAcquirer().acquirer(),
        runner.runner(),
    );
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(runner.last_options != null);
    try std.testing.expect(runner.last_options.?.directory_set);
    try std.testing.expectEqualStrings(tmp.dir.path.?, runner.last_options.?.directory);
}

test "serve rejects a missing directory with usage in non-interactive mode" {
    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var harness = nonInteractiveAcquirer();
    var runner = FakeServerRunner{};
    const code = try runServeCommandAcquired(
        std.testing.io,
        &.{},
        &stdout,
        &stderr,
        harness.acquirer(),
        runner.runner(),
    );
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Missing value for directory") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Usage: matcha serve") != null);
    try std.testing.expectEqual(@as(usize, 0), stdout.end);
    try std.testing.expect(!harness.readLineCalled());
    try std.testing.expect(runner.last_options == null);
}

test "serve non-interactive missing directory returns usage without reading input" {
    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var harness = nonInteractiveAcquirer();
    harness.line = "should-not-be-read";
    var runner = FakeServerRunner{};
    const code = try runServeCommandAcquired(
        std.testing.io,
        &.{},
        &stdout,
        &stderr,
        harness.acquirer(),
        runner.runner(),
    );
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(!harness.readLineCalled());
}

test "serve prompts interactively and accepts a valid entered directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var harness = interactiveAcquirer(std.testing.allocator);
    defer harness.deinit(std.testing.allocator);
    harness.line = try std.testing.allocator.dupe(u8, tmp.dir.path.?);
    defer std.testing.allocator.free(harness.line.?);

    var runner = FakeServerRunner{};
    const code = try runServeCommandAcquired(
        std.testing.io,
        &.{},
        &stdout,
        &stderr,
        harness.acquirer(),
        runner.runner(),
    );
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(harness.readLineCalled());
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer[0..stdout.end], "Directory to serve:") != null);
    try std.testing.expect(runner.last_options != null);
    try std.testing.expectEqualStrings(tmp.dir.path.?, runner.last_options.?.directory);
}

test "serve prompted path supports home expansion" {
    const allocator = std.testing.allocator;
    const home = path.expandHomePath(allocator, "~") catch return;
    defer allocator.free(home);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var harness = interactiveAcquirer(allocator);
    defer harness.deinit(allocator);

    const tmp_name = try std.fs.path.basename(allocator, tmp.dir.path.?);
    defer allocator.free(tmp_name);
    const prompted_path = try std.fmt.allocPrint(allocator, "~/{s}", .{tmp_name});
    defer allocator.free(prompted_path);

    // Make a matching path under home so validation passes.
    const home_target = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, tmp_name });
    defer allocator.free(home_target);
    std.fs.cwd().deletePath(home_target) catch {};
    defer std.fs.cwd().deletePath(home_target) catch {};
    try std.fs.cwd().makePath(home_target);
    defer std.fs.cwd().deletePath(home_target) catch {};

    harness.line = try allocator.dupe(u8, prompted_path);
    defer allocator.free(harness.line.?);

    var runner = FakeServerRunner{};
    const code = try runServeCommandAcquired(
        std.testing.io,
        &.{},
        &stdout,
        &stderr,
        harness.acquirer(),
        runner.runner(),
    );
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(runner.last_options != null);
    try std.testing.expectEqualStrings(home_target, runner.last_options.?.directory);
}

test "serve interactive empty response fails without re-prompting" {
    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var harness = interactiveAcquirer(std.testing.allocator);
    defer harness.deinit(std.testing.allocator);
    harness.line = try std.testing.allocator.dupe(u8, "");
    defer std.testing.allocator.free(harness.line.?);

    var runner = FakeServerRunner{};
    const code = try runServeCommandAcquired(
        std.testing.io,
        &.{},
        &stdout,
        &stderr,
        harness.acquirer(),
        runner.runner(),
    );
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(harness.readLineCalled());
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Missing value for directory") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Usage: matcha serve") != null);
}

test "serve interactive end-of-file fails without re-prompting" {
    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var harness = interactiveAcquirer(std.testing.allocator);
    defer harness.deinit(std.testing.allocator);
    harness.end_of_file = true;

    var runner = FakeServerRunner{};
    const code = try runServeCommandAcquired(
        std.testing.io,
        &.{},
        &stdout,
        &stderr,
        harness.acquirer(),
        runner.runner(),
    );
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(harness.readLineCalled());
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Missing value for directory") != null);
}

test "serve interactive invalid entered directory fails with not a directory" {
    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var harness = interactiveAcquirer(std.testing.allocator);
    defer harness.deinit(std.testing.allocator);
    harness.line = try std.testing.allocator.dupe(u8, "/tmp/matcha-interactive-nonexistent-xyz");
    defer std.testing.allocator.free(harness.line.?);

    var runner = FakeServerRunner{};
    const code = try runServeCommandAcquired(
        std.testing.io,
        &.{},
        &stdout,
        &stderr,
        harness.acquirer(),
        runner.runner(),
    );
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Not a directory:") != null);
}

test "serve explicit directory never triggers a prompt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var harness = nonInteractiveAcquirer();
    harness.line = "should-not-be-read";
    var runner = FakeServerRunner{};
    const code = try runServeCommandAcquired(
        std.testing.io,
        &.{tmp.dir.path.?},
        &stdout,
        &stderr,
        harness.acquirer(),
        runner.runner(),
    );
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(!harness.readLineCalled());
    try std.testing.expectEqual(@as(usize, 0), stdout.end);
    try std.testing.expect(runner.last_options != null);
    try std.testing.expectEqualStrings(tmp.dir.path.?, runner.last_options.?.directory);
}

const FakeDirectoryAcquirer = struct {
    interactive: bool,
    line: ?[]const u8 = null,
    end_of_file: bool = false,
    read_line_called: bool = false,

    fn isInteractiveImpl(context: *anyopaque) bool {
        const self: *FakeDirectoryAcquirer = @ptrCast(@alignCast(context));
        return self.interactive;
    }

    fn readLineImpl(context: *anyopaque, allocator: std.mem.Allocator) DirectoryAcquireResult {
        const self: *FakeDirectoryAcquirer = @ptrCast(@alignCast(context));
        self.read_line_called = true;
        if (self.end_of_file) return .{ .err = .{ .missing_value = "directory" } };
        if (self.line) |line| return .{ .ok = allocator.dupe(u8, line) catch return .{ .err = .{ .path_error = "" } } };
        return .{ .err = .{ .missing_value = "directory" } };
    }

    fn acquirer(self: *FakeDirectoryAcquirer) DirectoryAcquirer {
        return .{
            .context = @ptrCast(self),
            .isInteractiveFn = FakeDirectoryAcquirer.isInteractiveImpl,
            .readLineFn = FakeDirectoryAcquirer.readLineImpl,
        };
    }

    fn readLineCalled(self: *FakeDirectoryAcquirer) bool {
        return self.read_line_called;
    }

    fn deinit(self: *FakeDirectoryAcquirer, allocator: std.mem.Allocator) void {
        if (self.line) |line| allocator.free(line);
    }
};

fn nonInteractiveAcquirer() FakeDirectoryAcquirer {
    return .{ .interactive = false };
}

fn interactiveAcquirer(_: std.mem.Allocator) FakeDirectoryAcquirer {
    return .{ .interactive = true };
}

const FakeServerRunner = struct {
    last_options: ?serve_options.ServeOptions = null,
    last_stdout: ?*std.Io.Writer = null,
    last_stderr: ?*std.Io.Writer = null,
    exit_code: ExitCode = .ok,

    fn run(
        context: *anyopaque,
        io: std.Io,
        options: serve_options.ServeOptions,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) anyerror!ExitCode {
        _ = io;
        const self: *FakeServerRunner = @ptrCast(@alignCast(context));
        self.last_options = options;
        self.last_stdout = stdout;
        self.last_stderr = stderr;
        return self.exit_code;
    }

    fn runner(self: *FakeServerRunner) ServerRunner {
        return .{
            .context = @ptrCast(self),
            .runFn = FakeServerRunner.run,
        };
    }
};

test "serve rejects an invalid directory with not a directory error" {
    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "serve", "/tmp/matcha-nonexistent-xyz-12345" }, std.testing.io, &stdout, &stderr);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Not a directory:") != null);
    try std.testing.expectEqual(@as(usize, 0), stdout.end);
}

test "serve rejects extra positional arguments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "serve", tmp.dir.path.?, "/extra" }, std.testing.io, &stdout, &stderr);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Unexpected argument:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Usage: matcha serve") != null);
}

test "serve rejects invalid port" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "serve", "--port", "abc", tmp.dir.path.? }, std.testing.io, &stdout, &stderr);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Invalid port:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Usage: matcha serve") != null);
}

test "serve rejects invalid interval" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "serve", "--interval", "0", tmp.dir.path.? }, std.testing.io, &stdout, &stderr);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Invalid interval:") != null);
}

test "serve rejects unknown flag" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "serve", "--theme", "dracula", tmp.dir.path.? }, std.testing.io, &stdout, &stderr);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Unknown option:") != null);
}

test "serve rejects a file path as directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/not-a-dir.txt", .{tmp.dir.path.?});
    defer std.testing.allocator.free(file_path);
    try tmp.dir.writeFile("not-a-dir.txt", "data");

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{ "serve", file_path }, std.testing.io, &stdout, &stderr);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Not a directory:") != null);
}

test "root help mentions serve command" {
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const code = try runArgs(&.{"help"}, std.testing.io, &stdout, &stderr);
    const output = stdout_buffer[0..stdout.end];
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, output, "serve            Serve generated Matcha HTML artifacts on the local network") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "matcha serve --help") != null);
}

test "existing plan and map behavior unchanged by serve addition" {
    {
        var stdout_buffer: [64]u8 = undefined;
        var stderr_buffer: [128]u8 = undefined;
        var stdout: std.Io.Writer = .fixed(&stdout_buffer);
        var stderr: std.Io.Writer = .fixed(&stderr_buffer);
        const code = try runArgs(&.{"version"}, std.testing.io, &stdout, &stderr);
        try std.testing.expectEqual(ExitCode.ok, code);
        try std.testing.expectEqualStrings("matcha 0.1.0\n", stdout_buffer[0..stdout.end]);
    }

    {
        var stdout_buffer: [4096]u8 = undefined;
        var stderr_buffer: [128]u8 = undefined;
        var stdout: std.Io.Writer = .fixed(&stdout_buffer);
        var stderr: std.Io.Writer = .fixed(&stderr_buffer);
        const code = try runArgs(&.{ "plan", "--wat" }, std.testing.io, &stdout, &stderr);
        try std.testing.expectEqual(ExitCode.usage, code);
        try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Unknown option: --wat") != null);
    }

    {
        var stdout_buffer: [4096]u8 = undefined;
        var stderr_buffer: [128]u8 = undefined;
        var stdout: std.Io.Writer = .fixed(&stdout_buffer);
        var stderr: std.Io.Writer = .fixed(&stderr_buffer);
        const code = try runArgs(&.{ "map", "--wat" }, std.testing.io, &stdout, &stderr);
        try std.testing.expectEqual(ExitCode.usage, code);
        try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Unknown option: --wat") != null);
    }

    {
        var stdout_buffer: [4096]u8 = undefined;
        var stderr_buffer: [128]u8 = undefined;
        var stdout: std.Io.Writer = .fixed(&stdout_buffer);
        var stderr: std.Io.Writer = .fixed(&stderr_buffer);
        const code = try runArgs(&.{"nope"}, std.testing.io, &stdout, &stderr);
        try std.testing.expectEqual(ExitCode.usage, code);
        try std.testing.expect(std.mem.indexOf(u8, stderr_buffer[0..stderr.end], "Unknown command: nope") != null);
    }
}

fn expectRenderOptions(result: RenderOptionsResult) RenderOptions {
    return switch (result) {
        .ok => |options| options,
        .err => unreachable,
    };
}

fn expectMissingValue(expected_flag: []const u8, result: RenderOptionsResult) !void {
    switch (result) {
        .ok => return error.ExpectedError,
        .err => |cli_error| switch (cli_error) {
            .missing_value => |flag| {
                try std.testing.expectEqualStrings(expected_flag, flag);
                return;
            },
            .unknown_option => return error.WrongError,
        },
    }
}

fn expectUnknownOption(expected_option: []const u8, result: RenderOptionsResult) !void {
    switch (result) {
        .ok => return error.ExpectedError,
        .err => |cli_error| switch (cli_error) {
            .missing_value => return error.WrongError,
            .unknown_option => |option| {
                try std.testing.expectEqualStrings(expected_option, option);
                return;
            },
        },
    }
}
