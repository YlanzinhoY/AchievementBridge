const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bridge = b.addModule("achievement_bridge", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "achievement-bridge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "achievement_bridge", .module = bridge },
            },
        }),
    });
    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("advapi32", .{});
        exe.root_module.linkSystemLibrary("user32", .{});
        exe.root_module.linkSystemLibrary("shell32", .{});
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run Achievement Bridge");
    run_step.dependOn(&run_cmd.step);

    const module_tests = b.addTest(.{ .root_module = bridge });
    const run_module_tests = b.addRunArtifact(module_tests);
    const cli_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_module_tests.step);
    test_step.dependOn(&run_cli_tests.step);
}
