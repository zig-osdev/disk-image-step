const std = @import("std");
const Dimmer = @import("dimmer").BuildInterface;

pub const KiB = 1024;
pub const MiB = 1024 * KiB;
pub const GiB = 1024 * MiB;

pub fn build(b: *std.Build) void {
    const dimmer_dep = b.dependency("dimmer", .{});

    const dimmer: Dimmer = .init(b, dimmer_dep);

    const install_step = b.getInstallStep();

    installDebugDisk(dimmer, install_step, "empty.img", 50 * KiB, .empty);
    installDebugDisk(dimmer, install_step, "fill-0x00.img", 50 * KiB, .{ .fill = 0x00 });
    installDebugDisk(dimmer, install_step, "fill-0xAA.img", 50 * KiB, .{ .fill = 0xAA });
    installDebugDisk(dimmer, install_step, "fill-0xFF.img", 50 * KiB, .{ .fill = 0xFF });
    installDebugDisk(dimmer, install_step, "paste-file.img", 50 * KiB, .{ .paste_file = b.path("build.zig.zon") });

    // installDebugDisk(dimmer, install_step, "empty-mbr.img", 50 * MiB, .{
    //     .mbr_part_table = .{
    //         .partitions = .{
    //             null,
    //             null,
    //             null,
    //             null,
    //         },
    //     },
    // });

    // installDebugDisk(dimmer, install_step, "manual-offset-mbr.img", 50 * MiB, .{
    //     .mbr_part_table = .{
    //         .partitions = .{
    //             &.{ .offset = 2048 + 0 * 10 * MiB, .size = 10 * MiB, .bootable = true, .type = .fat32_lba, .data = .empty },
    //             &.{ .offset = 2048 + 1 * 10 * MiB, .size = 10 * MiB, .bootable = false, .type = .ntfs, .data = .empty },
    //             &.{ .offset = 2048 + 2 * 10 * MiB, .size = 10 * MiB, .bootable = false, .type = .linux_swap, .data = .empty },
    //             &.{ .offset = 2048 + 3 * 10 * MiB, .size = 10 * MiB, .bootable = false, .type = .linux_fs, .data = .empty },
    //         },
    //     },
    // });

    // installDebugDisk(dimmer, install_step, "auto-offset-mbr.img", 50 * MiB, .{
    //     .mbr_part_table = .{
    //         .partitions = .{
    //             &.{ .size = 7 * MiB, .bootable = true, .type = .fat32_lba, .data = .empty },
    //             &.{ .size = 8 * MiB, .bootable = false, .type = .ntfs, .data = .empty },
    //             &.{ .size = 9 * MiB, .bootable = false, .type = .linux_swap, .data = .empty },
    //             &.{ .size = 10 * MiB, .bootable = false, .type = .linux_fs, .data = .empty },
    //         },
    //     },
    // });

    // installDebugDisk(dimmer, install_step, "empty-fat32.img", 50 * MiB, .{
    //     .vfat = .{
    //         .format = .fat32,
    //         .label = "EMPTY",
    //         .items = &.{},
    //     },
    // });

    // installDebugDisk(dimmer, install_step, "initialized-fat32.img", 50 * MiB, .{
    //     .vfat = .{
    //         .format = .fat32,
    //         .label = "ROOTFS",
    //         .items = &.{
    //             .{ .empty_dir = "boot/EFI/refind/icons" },
    //             .{ .empty_dir = "/boot/EFI/nixos/.extra-files/" },
    //             .{ .empty_dir = "Users/xq/" },
    //             .{ .copy_dir = .{ .source = b.path("dummy/Windows"), .destination = "Windows" } },
    //             .{ .copy_file = .{ .source = b.path("dummy/README.md"), .destination = "Users/xq/README.md" } },
    //         },
    //     },
    // });

    // installDebugDisk(dimmer, install_step, "initialized-fat32-in-mbr-partitions.img", 100 * MiB, .{
    //     .mbr = .{
    //         .partitions = .{
    //             &.{
    //                 .size = 90 * MiB,
    //                 .bootable = true,
    //                 .type = .fat32_lba,
    //                 .data = .{
    //                     .vfat = .{
    //                         .format = .fat32,
    //                         .label = "ROOTFS",
    //                         .items = &.{
    //                             .{ .empty_dir = "boot/EFI/refind/icons" },
    //                             .{ .empty_dir = "/boot/EFI/nixos/.extra-files/" },
    //                             .{ .empty_dir = "Users/xq/" },
    //                             .{ .copy_dir = .{ .source = b.path("dummy/Windows"), .destination = "Windows" } },
    //                             .{ .copy_file = .{ .source = b.path("dummy/README.md"), .destination = "Users/xq/README.md" } },
    //                         },
    //                     },
    //                 },
    //             },
    //             null,
    //             null,
    //             null,
    //         },
    //     },
    // });

    // TODO: Implement GPT partition support
    // installDebugDisk(debug_step, "empty-gpt.img", 50 * MiB, .{
    //     .gpt = .{
    //         .partitions = &.{},
    //     },
    // });
}

fn installDebugDisk(
    dimmer: Dimmer,
    install_step: *std.Build.Step,
    name: []const u8,
    size: u64,
    content: Dimmer.Content,
) void {
    const disk_file = dimmer.createDisk(size, content);

    const install_disk = install_step.owner.addInstallFile(
        disk_file,
        name,
    );
    install_step.dependOn(&install_disk.step);
}
