const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = setupCore(b, target, optimize);
    const mod = b.addModule("blox", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core },
        },
    });

    const volt = b.dependency("volt", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("volt", volt.module("volt"));

    const exe = b.addExecutable(.{
        .name = "blox",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "blox", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const core_tests = b.addTest(.{
        .root_module = core,
    });

    const run_core_tests = b.addRunArtifact(core_tests);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");

    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

fn setupCore(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const core = b.addModule("core", .{
        .root_source_file = b.path("src/core/blockchain.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core_options = b.addOptions();
    core_options.addOption(u8, "DIFFICULTY", 2);
    core_options.addOption([]const u8, "GENESIS_DATA", "GENESIS");
    core_options.addOption(i64, "GENESIS_TIMESTAMP", 199204);
    core_options.addOption(u64, "GENESIS_NONCE", 3349);
    core.addOptions("core_options", core_options);

    return core;
}
