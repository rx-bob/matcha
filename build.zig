const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const matcha_module = b.addModule("matcha", .{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "matcha",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "matcha", .module = matcha_module },
            },
        }),
    });
    b.installArtifact(exe);

    const release_module = b.addModule("matcha-release", .{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });

    const release_exe = b.addExecutable(.{
        .name = "matcha",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "matcha", .module = release_module },
            },
        }),
    });

    const release_install = b.addInstallArtifact(release_exe, .{
        .dest_sub_path = "matcha-release",
    });
    const release_step = b.step("release", "Build the release executable");
    release_step.dependOn(&release_install.step);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const module_tests = b.addTest(.{
        .root_module = matcha_module,
    });
    const run_module_tests = b.addRunArtifact(module_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const ownership_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/scan_ownership.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_ownership_tests = b.addRunArtifact(ownership_tests);

    const markdown_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/render_markdown.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_markdown_tests = b.addRunArtifact(markdown_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_module_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_ownership_tests.step);
    test_step.dependOn(&run_markdown_tests.step);

    const leak_sensitive_test_roots = .{
        "src/loop_backend.zig",
        "src/loop_log.zig",
        "src/loop_stream.zig",
        "src/loop_store.zig",
        "src/loop_options.zig",
        "src/loop_config.zig",
        "src/loop_models.zig",
        "src/loop_summary.zig",
        "src/path.zig",
        "src/serve_routes.zig",
    };
    inline for (leak_sensitive_test_roots) |source| {
        const module_tests_for_source = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(source),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        const run_module_tests_for_source = b.addRunArtifact(module_tests_for_source);
        test_step.dependOn(&run_module_tests_for_source.step);
    }

    const leak_audit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("leak_audit_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .filters = &.{
            "markdown rendering releases partial allocations",
            "prompt rendering releases allocations",
            "route encoding and parsing release allocations",
            "home path expansion releases allocations",
            "backend argument construction releases partial allocations",
            "loop option parsing releases partial prompt allocations",
            "JSON document reading releases allocations",
            "plan read parsing releases allocations",
            "catalog scanning releases partial allocations",
            "catalog JSON rendering releases the transferred buffer on OOM",
            "JSONL stream processing releases partial allocations",
            "loop config path allocation releases partial allocations",
            "loop summary rendering releases partial allocations",
        },
    });
    const run_leak_audit_tests = b.addRunArtifact(leak_audit_tests);
    test_step.dependOn(&run_leak_audit_tests.step);
}
