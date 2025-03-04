const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const test_step = b.step("test", "Runs the test suite.");

    // // Dependency Setup:
    // const zfat_dep = b.dependency("zfat", .{
    //     // .max_long_name_len = 121,
    //     .code_page = .us,
    //     .@"volume-count" = @as(u32, 1),
    //     .@"sector-size" = @as(u32, 512),
    //     // .rtc = .dynamic,
    //     .mkfs = true,
    //     .exfat = true,
    // });

    // const zfat_mod = zfat_dep.module("zfat");

    // const mkfs_fat = b.addExecutable(.{
    //     .name = "mkfs.fat",
    //     .target = b.graph.host,
    //     .optimize = .ReleaseSafe,
    //     .root_source_file = b.path("src/mkfs.fat.zig"),
    // });
    // mkfs_fat.root_module.addImport("fat", zfat_mod);
    // mkfs_fat.linkLibC();
    // b.installArtifact(mkfs_fat);

    const dim_mod = b.addModule("dim", .{
        .root_source_file = b.path("src/dim.zig"),
        .target = target,
        .optimize = optimize,
    });

    const dim_exe = b.addExecutable(.{
        .name = "dim",
        .root_module = dim_mod,
    });
    b.installArtifact(dim_exe);

    const dim_tests = b.addTest(.{
        .root_module = dim_mod,
    });
    const run_dim_tests = b.addRunArtifact(dim_tests);
    test_step.dependOn(&run_dim_tests.step);
}
