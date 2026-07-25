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
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    const module_tests = b.addTest(.{
        .root_module = matcha_module,
    });
    const run_module_tests = b.addRunArtifact(module_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_module_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
