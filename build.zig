const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

const Environment = enum {
    dev,
    prod,
};

pub fn build(b: *std.Build) void {
    const env = b.option(Environment, "env", "Environment to build for") orelse .dev;
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const Hash = [Sha256.digest_length]u8;
    const core_opts = b.addOptions();
    core_opts.addOption(u4, "genesis_difficulty", 2);
    core_opts.addOption(Hash, "genesis_prev_hash", @as(Hash, @splat(0)));
    core_opts.addOption([]const u8, "genesis_data", "GENESIS");
    core_opts.addOption(i64, "genesis_timestamp", 199_204);
    core_opts.addOption(u64, "genesis_nonce", 3_349);
    core_opts.addOption(u16, "mine_rate_ms", 5_000);
    core_opts.addOption(i128, "initial_balance", 500);
    const core = b.addModule("core", .{
        .optimize = optimize,
        .target = target,
        .root_source_file = b.path("src/core/root.zig"),
    });

    core.addOptions("options", core_opts);

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

    const mod_options = b.addOptions();
    mod_options.addOption(Environment, "environment", env);
    mod.addOptions("options", mod_options);
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
    run_cmd.addPassthruArgs();

    const core_tests = b.addTest(.{
        .root_module = core,
        .name = "core",
    });

    const run_core_tests = b.addRunArtifact(core_tests);

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .name = "lib",
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        .name = "blox",
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");

    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
