const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

const Env = enum {
    dev,
    prod,
};

pub fn build(b: *std.Build) void {
    const env = b.option(Env, "env", "Environment to build for") orelse .dev;
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("blox", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const volt = b.dependency("volt", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("volt", volt.module("volt"));

    const Hash = [Sha256.digest_length]u8;
    const options = b.addOptions();
    options.addOption(u4, "genesis_difficulty", 2);
    options.addOption(Hash, "genesis_prev_hash", @as(Hash, @splat(0)));
    options.addOption([]const u8, "genesis_data", "GENESIS");
    options.addOption(i64, "genesis_timestamp", 199_204);
    options.addOption(u64, "genesis_nonce", 3_349);
    options.addOption(u16, "mine_rate_ms", 3_000);
    options.addOption(Env, "env", env);
    mod.addOptions("options", options);

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

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");

    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
