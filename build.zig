const std = @import("std");

pub const BuildInterface = @import("src/BuildInterface.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const test_step = b.step("test", "Runs the test suite.");

    // Dependency Setup:
    const zfat_dep = b.dependency("zfat", .{
        // .max_long_name_len = 121,
        .code_page = .us,
        .@"volume-count" = @as(u32, 1),
        .@"sector-size" = @as(u32, 512),
        // .rtc = .dynamic,
        .mkfs = true,
        .exfat = true,
        .label = true,
    });

    const zfat_mod = zfat_dep.module("zfat");

    const args_dep = b.dependency("args", .{});
    const args_mod = args_dep.module("args");

    const dim_mod = b.addModule("dim", .{
        .root_source_file = b.path("src/dim.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dim_mod.addImport("args", args_mod);
    dim_mod.addImport("zfat", zfat_mod);

    const dim_exe = b.addExecutable(.{
        .name = "dimmer",
        .root_module = dim_mod,
    });
    b.installArtifact(dim_exe);

    const dim_tests = b.addTest(.{
        .root_module = dim_mod,
    });
    const run_dim_tests = b.addRunArtifact(dim_tests);
    test_step.dependOn(&run_dim_tests.step);

    const behaviour_tests_step = b.step("behaviour", "Run all behaviour tests");
    for (behaviour_tests) |script| {
        const step_name = b.dupe(script);
        std.mem.replaceScalar(u8, step_name, '/', '-');
        const script_test = b.step(step_name, b.fmt("Run {s} behaviour test", .{script}));

        const run_behaviour = b.addRunArtifact(dim_exe);
        run_behaviour.addArg("--output");
        _ = run_behaviour.addOutputFileArg("disk.img");
        run_behaviour.addArg("--script");
        run_behaviour.addFileArg(b.path(script));
        run_behaviour.addArgs(&.{ "--size", "30M" });
        script_test.dependOn(&run_behaviour.step);

        behaviour_tests_step.dependOn(script_test);
    }
}

const behaviour_tests: []const []const u8 = &.{
    "tests/basic/empty.dis",
    "tests/basic/fill-0x00.dis",
    "tests/basic/fill-0xAA.dis",
    "tests/basic/fill-0xFF.dis",
    "tests/basic/raw.dis",
    "tests/part/mbr/minimal.dis",
};
