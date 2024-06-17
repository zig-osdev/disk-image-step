const std = @import("std");
const builtin = @import("builtin");

fn root() []const u8 {
    return comptime (std.fs.path.dirname(@src().file) orelse ".");
}
const build_root = root();

pub const KiB = 1024;
pub const MiB = 1024 * KiB;
pub const GiB = 1024 * MiB;

fn usageDemo(
    b: *std.Build,
    dependency: *std.Build.Dependency,
    debug_step: *std.Build.Step,
) void {
    installDebugDisk(dependency, debug_step, "uninitialized.img", 50 * MiB, .uninitialized);

    installDebugDisk(dependency, debug_step, "empty-mbr.img", 50 * MiB, .{
        .mbr = .{
            .partitions = .{
                null,
                null,
                null,
                null,
            },
        },
    });

    installDebugDisk(dependency, debug_step, "manual-offset-mbr.img", 50 * MiB, .{
        .mbr = .{
            .partitions = .{
                &.{ .offset = 2048 + 0 * 10 * MiB, .size = 10 * MiB, .bootable = true, .type = .fat32_lba, .data = .uninitialized },
                &.{ .offset = 2048 + 1 * 10 * MiB, .size = 10 * MiB, .bootable = false, .type = .ntfs, .data = .uninitialized },
                &.{ .offset = 2048 + 2 * 10 * MiB, .size = 10 * MiB, .bootable = false, .type = .linux_swap, .data = .uninitialized },
                &.{ .offset = 2048 + 3 * 10 * MiB, .size = 10 * MiB, .bootable = false, .type = .linux_fs, .data = .uninitialized },
            },
        },
    });

    installDebugDisk(dependency, debug_step, "auto-offset-mbr.img", 50 * MiB, .{
        .mbr = .{
            .partitions = .{
                &.{ .size = 7 * MiB, .bootable = true, .type = .fat32_lba, .data = .uninitialized },
                &.{ .size = 8 * MiB, .bootable = false, .type = .ntfs, .data = .uninitialized },
                &.{ .size = 9 * MiB, .bootable = false, .type = .linux_swap, .data = .uninitialized },
                &.{ .size = 10 * MiB, .bootable = false, .type = .linux_fs, .data = .uninitialized },
            },
        },
    });

    installDebugDisk(dependency, debug_step, "empty-fat32.img", 50 * MiB, .{
        .fs = .{
            .format = .fat32,
            .label = "EMPTY",
            .items = &.{},
        },
    });

    installDebugDisk(dependency, debug_step, "initialized-fat32.img", 50 * MiB, .{
        .fs = .{
            .format = .fat32,
            .label = "ROOTFS",
            .items = &.{
                .{ .empty_dir = "boot/EFI/refind/icons" },
                .{ .empty_dir = "/boot/EFI/nixos/.extra-files/" },
                .{ .empty_dir = "Users/xq/" },
                .{ .copy_dir = .{ .source = b.path("dummy/Windows"), .destination = "Windows" } },
                .{ .copy_file = .{ .source = b.path("dummy/README.md"), .destination = "Users/xq/README.md" } },
            },
        },
    });

    installDebugDisk(dependency, debug_step, "initialized-fat32-in-mbr-partitions.img", 100 * MiB, .{
        .mbr = .{
            .partitions = .{
                &.{
                    .size = 90 * MiB,
                    .bootable = true,
                    .type = .fat32_lba,
                    .data = .{
                        .fs = .{
                            .format = .fat32,
                            .label = "ROOTFS",
                            .items = &.{
                                .{ .empty_dir = "boot/EFI/refind/icons" },
                                .{ .empty_dir = "/boot/EFI/nixos/.extra-files/" },
                                .{ .empty_dir = "Users/xq/" },
                                .{ .copy_dir = .{ .source = b.path("dummy/Windows"), .destination = "Windows" } },
                                .{ .copy_file = .{ .source = b.path("dummy/README.md"), .destination = "Users/xq/README.md" } },
                            },
                        },
                    },
                },
                null,
                null,
                null,
            },
        },
    });

    // TODO: Implement GPT partition support
    // installDebugDisk(debug_step, "empty-gpt.img", 50 * MiB, .{
    //     .gpt = .{
    //         .partitions = &.{},
    //     },
    // });
}

pub fn build(b: *std.Build) void {
    // Steps:

    const debug_step = b.step("debug", "Builds a basic exemplary disk image.");

    // Dependency Setup:

    const zfat_dep = b.dependency("zfat", .{
        // .max_long_name_len = 121,
        .code_page = .us,
        .@"volume-count" = @as(u32, 1),
        .@"sector-size" = @as(u32, 512),
        // .rtc = .dynamic,
        .mkfs = true,
        .exfat = true,
    });

    const zfat_mod = zfat_dep.module("zfat");

    const mkfs_fat = b.addExecutable(.{
        .name = "mkfs.fat",
        .target = b.host,
        .optimize = .ReleaseSafe,
        .root_source_file = b.path("src/mkfs.fat.zig"),
    });
    mkfs_fat.root_module.addImport("fat", zfat_mod);
    mkfs_fat.linkLibC();
    b.installArtifact(mkfs_fat);

    // Usage:
    var self_dep = std.Build.Dependency{
        .builder = b,
    };
    usageDemo(b, &self_dep, debug_step);
}

fn resolveFilesystemMaker(dependency: *std.Build.Dependency, fs: FileSystem.Format) std.Build.LazyPath {
    return switch (fs) {
        .fat12, .fat16, .fat32, .exfat => dependency.artifact("mkfs.fat").getEmittedBin(),

        .custom => |path| path,

        else => std.debug.panic("Unsupported builtin file system: {s}", .{@tagName(fs)}),
    };
}

fn relpath(b: *std.Build, path: []const u8) std.Build.LazyPath {
    return .{
        .cwd_relative = b.pathFromRoot(path),
    };
}

fn installDebugDisk(
    dependency: *std.Build.Dependency,
    install_step: *std.Build.Step,
    name: []const u8,
    size: u64,
    content: Content,
) void {
    const initialize_disk = initializeDisk(dependency, size, content);
    const install_disk = install_step.owner.addInstallFile(initialize_disk.getImageFile(), name);
    install_step.dependOn(&install_disk.step);
}

pub fn initializeDisk(dependency: *std.Build.Dependency, size: u64, content: Content) *InitializeDiskStep {
    const ids = dependency.builder.allocator.create(InitializeDiskStep) catch @panic("out of memory");

    ids.* = InitializeDiskStep{
        .step = std.Build.Step.init(.{
            .owner = dependency.builder, // TODO: Is this correct?
            .id = .custom,
            .name = "initialize disk",
            .makeFn = InitializeDiskStep.make,
            .first_ret_addr = @returnAddress(),
            .max_rss = 0,
        }),
        .disk_file = .{ .step = &ids.step },
        .content = content.dupe(dependency.builder) catch @panic("out of memory"),
        .size = size,
    };

    ids.content.resolveFileSystems(dependency);

    ids.content.pushDependenciesTo(&ids.step);

    return ids;
}

pub const InitializeDiskStep = struct {
    const IoPump = std.fifo.LinearFifo(u8, .{ .Static = 8192 });

    step: std.Build.Step,

    content: Content,
    size: u64,

    disk_file: std.Build.GeneratedFile,

    pub fn getImageFile(ids: *InitializeDiskStep) std.Build.LazyPath {
        return .{ .generated = .{
            .file = &ids.disk_file,
        } };
    }

    fn addDirectoryToCache(b: *std.Build, manifest: *std.Build.Cache.Manifest, parent: std.fs.Dir, path: []const u8) !void {
        var dir = try parent.openDir(path, .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(b.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            switch (entry.kind) {
                .file => {
                    const abs_path = try entry.dir.realpathAlloc(b.allocator, entry.basename);
                    defer b.allocator.free(abs_path);
                    _ = try manifest.addFile(abs_path, null);
                },
                .directory => try addDirectoryToCache(b, manifest, entry.dir, entry.basename),

                else => return error.Unsupported,
            }
        }
    }

    fn addToCacheManifest(b: *std.Build, asking: *std.Build.Step, manifest: *std.Build.Cache.Manifest, content: Content) !void {
        manifest.hash.addBytes(@tagName(content));
        switch (content) {
            .uninitialized => {},

            .mbr => |table| { //  MbrTable
                manifest.hash.addBytes(&table.bootloader);
                for (table.partitions) |part_or_null| {
                    const part = part_or_null orelse {
                        manifest.hash.addBytes("none");
                        break;
                    };
                    manifest.hash.add(part.bootable);
                    manifest.hash.add(part.offset orelse 0x04_03_02_01);
                    manifest.hash.add(part.size);
                    manifest.hash.add(part.type);
                    try addToCacheManifest(b, asking, manifest, part.data);
                }
            },

            .gpt => |table| { //  GptTable
                manifest.hash.addBytes(&table.disk_id);

                for (table.partitions) |part| {
                    manifest.hash.addBytes(&part.part_id);
                    manifest.hash.addBytes(&part.type);
                    manifest.hash.addBytes(std.mem.sliceAsBytes(&part.name));

                    manifest.hash.add(part.offset orelse 0x04_03_02_01);
                    manifest.hash.add(part.size);

                    manifest.hash.add(@as(u32, @bitCast(part.attributes)));

                    try addToCacheManifest(b, asking, manifest, part.data);
                }
            },

            .fs => |fs| { //  FileSystem
                manifest.hash.add(@as(u64, fs.items.len));
                manifest.hash.addBytes(@tagName(fs.format));
                manifest.hash.addBytes(fs.executable.?.getPath2(b, asking));

                // TODO: Properly add internal file system
                for (fs.items) |entry| {
                    manifest.hash.addBytes(@tagName(entry));
                    switch (entry) {
                        .empty_dir => |dir| {
                            manifest.hash.addBytes(dir);
                        },
                        .copy_dir => |dir| {
                            manifest.hash.addBytes(dir.destination);
                            try addDirectoryToCache(b, manifest, std.fs.cwd(), dir.source.getPath2(b, asking));
                        },
                        .copy_file => |file| {
                            manifest.hash.addBytes(file.destination);
                            _ = try manifest.addFile(file.source.getPath2(b, asking), null);
                        },
                    }
                }
            },
            .data => |data| {
                const path = data.getPath2(b, asking);
                _ = try manifest.addFile(path, null);
            },
            .binary => |binary| {
                const path = binary.getEmittedBin().getPath2(b, asking);
                _ = try manifest.addFile(path, null);
            },
        }
    }

    const HumanContext = std.BoundedArray(u8, 256);

    const DiskImage = struct {
        path: []const u8,
        handle: *std.fs.File,
    };

    fn writeDiskImage(b: *std.Build, asking: *std.Build.Step, disk: DiskImage, base: u64, length: u64, content: Content, context: *HumanContext) !void {
        try disk.handle.seekTo(base);

        const context_len = context.len;
        defer context.len = context_len;

        context.appendSliceAssumeCapacity(".");
        context.appendSliceAssumeCapacity(@tagName(content));

        switch (content) {
            .uninitialized => {},

            .mbr => |table| { //  MbrTable
                {
                    var boot_sector: [512]u8 = .{0} ** 512;

                    @memcpy(boot_sector[0..table.bootloader.len], &table.bootloader);

                    std.mem.writeInt(u32, boot_sector[0x1B8..0x1BC], if (table.disk_id) |disk_id| disk_id else 0x0000_0000, .little);
                    std.mem.writeInt(u16, boot_sector[0x1BC..0x1BE], 0x0000, .little);

                    var all_auto = true;
                    var all_manual = true;
                    for (table.partitions) |part_or_null| {
                        const part = part_or_null orelse continue;

                        if (part.offset != null) {
                            all_auto = false;
                        } else {
                            all_manual = false;
                        }
                    }

                    if (!all_auto and !all_manual) {
                        std.log.err("{s}: not all partitions have an explicit offset!", .{context.slice()});
                        return error.InvalidSectorBoundary;
                    }

                    const part_base = 0x01BE;
                    var auto_offset: u64 = 2048;
                    for (table.partitions, 0..) |part_or_null, part_id| {
                        const reset_len = context.len;
                        defer context.len = reset_len;

                        var buffer: [64]u8 = undefined;
                        context.appendSliceAssumeCapacity(std.fmt.bufPrint(&buffer, "[{}]", .{part_id}) catch unreachable);

                        const desc = boot_sector[part_base + 16 * part_id ..][0..16];

                        if (part_or_null) |part| {
                            // https://wiki.osdev.org/MBR#Partition_table_entry_format

                            const part_offset = part.offset orelse auto_offset;

                            if ((part_offset % 512) != 0) {
                                std.log.err("{s}: .offset is not divisible by 512!", .{context.slice()});
                                return error.InvalidSectorBoundary;
                            }
                            if ((part.size % 512) != 0) {
                                std.log.err("{s}: .size is not divisible by 512!", .{context.slice()});
                                return error.InvalidSectorBoundary;
                            }

                            const lba_u64 = @divExact(part_offset, 512);
                            const size_u64 = @divExact(part.size, 512);

                            const lba = std.math.cast(u32, lba_u64) orelse {
                                std.log.err("{s}: .offset is out of bounds!", .{context.slice()});
                                return error.InvalidSectorBoundary;
                            };
                            const size = std.math.cast(u32, size_u64) orelse {
                                std.log.err("{s}: .size is out of bounds!", .{context.slice()});
                                return error.InvalidSectorBoundary;
                            };

                            desc[0] = if (part.bootable) 0x80 else 0x00;

                            desc[1..4].* = mbr.encodeMbrChsEntry(lba); // chs_start
                            desc[4] = @intFromEnum(part.type);
                            desc[5..8].* = mbr.encodeMbrChsEntry(lba + size - 1); // chs_end
                            std.mem.writeInt(u32, desc[8..12], lba, .little); // lba_start
                            std.mem.writeInt(u32, desc[12..16], size, .little); // block_count

                            auto_offset += part.size;
                        } else {
                            @memset(desc, 0); // inactive
                        }
                    }
                    boot_sector[0x01FE] = 0x55;
                    boot_sector[0x01FF] = 0xAA;

                    try disk.handle.writeAll(&boot_sector);
                }

                {
                    var auto_offset: u64 = 2048;
                    for (table.partitions, 0..) |part_or_null, part_id| {
                        const part = part_or_null orelse continue;

                        const reset_len = context.len;
                        defer context.len = reset_len;

                        var buffer: [64]u8 = undefined;
                        context.appendSliceAssumeCapacity(std.fmt.bufPrint(&buffer, "[{}]", .{part_id}) catch unreachable);

                        try writeDiskImage(b, asking, disk, base + auto_offset, part.size, part.data, context);

                        auto_offset += part.size;
                    }
                }
            },

            .gpt => |table| { //  GptTable
                _ = table;
                std.log.err("{s}: GPT partition tables not supported yet!", .{context.slice()});
                return error.GptUnsupported;
            },

            .fs => |fs| {
                const maker_exe = fs.executable.?.getPath2(b, asking);

                try disk.handle.sync();

                // const disk_image_path = switch (builtin.os.tag) {
                //     .linux => blk: {
                //         const self_pid = std.os.linux.getpid();
                //         break :blk b.fmt("/proc/{}/fd/{}", .{ self_pid, disk.handle });
                //     },

                //     else => @compileError("TODO: Support this on other OS as well!"),
                // };

                var argv = std.ArrayList([]const u8).init(b.allocator);
                defer argv.deinit();

                try argv.appendSlice(&.{
                    maker_exe, // exe
                    disk.path, // image file
                    b.fmt("0x{X:0>8}", .{base}), // filesystem offset (bytes)
                    b.fmt("0x{X:0>8}", .{length}), // filesystem length (bytes)
                    @tagName(fs.format), // filesystem type
                    "format", // cmd 1: format the disk
                    "mount", // cmd 2: mount it internally
                });

                for (fs.items) |item| {
                    switch (item) {
                        .empty_dir => |dir| {
                            try argv.append(b.fmt("mkdir:{s}", .{dir}));
                        },
                        .copy_dir => |src_dst| {
                            try argv.append(b.fmt("dir:{s}:{s}", .{
                                src_dst.source.getPath2(b, asking),
                                src_dst.destination,
                            }));
                        },
                        .copy_file => |src_dst| {
                            try argv.append(b.fmt("file:{s}:{s}", .{
                                src_dst.source.getPath2(b, asking),
                                src_dst.destination,
                            }));
                        },
                    }
                }

                // use shared access to the file:
                const stdout = b.run(argv.items);

                try disk.handle.sync();

                _ = stdout;
            },

            .data => |data| {
                const path = data.getPath2(b, asking);
                try copyFileToImage(disk, length, std.fs.cwd(), path, context.slice());
            },

            .binary => |binary| {
                const path = binary.getEmittedBin().getPath2(b, asking);
                try copyFileToImage(disk, length, std.fs.cwd(), path, context.slice());
            },
        }
    }

    fn copyFileToImage(disk: DiskImage, max_length: u64, dir: std.fs.Dir, path: []const u8, context: []const u8) !void {
        errdefer std.log.err("{s}: failed to copy data to image.", .{context});

        var file = try dir.openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        if (stat.size > max_length) {
            var realpath_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            std.log.err("{s}: The file '{!s}' exceeds the size of the container. The file is {:.2} large, while the container only allows for {:.2}.", .{
                context,
                dir.realpath(path, &realpath_buffer),
                std.fmt.fmtIntSizeBin(stat.size),
                std.fmt.fmtIntSizeBin(max_length),
            });
            return error.FileTooLarge;
        }

        var pumper = IoPump.init();

        try pumper.pump(file.reader(), disk.handle.writer());

        const padding = max_length - stat.size;
        if (padding > 0) {
            try disk.handle.writer().writeByteNTimes(' ', padding);
        }
    }

    fn make(step: *std.Build.Step, progress: std.Progress.Node) !void {
        const b = step.owner;
        _ = progress;

        const ids: *InitializeDiskStep = @fieldParentPtr("step", step);

        var man = b.graph.cache.obtain();
        defer man.deinit();

        man.hash.addBytes(&.{ 232, 8, 75, 249, 2, 210, 51, 118, 171, 12 }); // Change when impl changes

        try addToCacheManifest(b, step, &man, ids.content);

        step.result_cached = try step.cacheHit(&man);
        const digest = man.final();

        const output_components = .{ "o", &digest, "disk.img" };
        const output_sub_path = b.pathJoin(&output_components);
        const output_sub_dir_path = std.fs.path.dirname(output_sub_path).?;
        b.cache_root.handle.makePath(output_sub_dir_path) catch |err| {
            return step.fail("unable to make path '{}{s}': {s}", .{
                b.cache_root, output_sub_dir_path, @errorName(err),
            });
        };

        ids.disk_file.path = try b.cache_root.join(b.allocator, &output_components);

        if (step.result_cached)
            return;

        {
            const disk_path = ids.disk_file.path.?;

            var disk = try std.fs.cwd().createFile(disk_path, .{});
            defer disk.close();

            try disk.seekTo(ids.size - 1);
            try disk.writeAll("\x00");
            try disk.seekTo(0);

            var context = HumanContext{};
            context.appendSliceAssumeCapacity("disk");

            const disk_image = DiskImage{
                .path = disk_path,
                .handle = &disk,
            };

            try writeDiskImage(b, step, disk_image, 0, ids.size, ids.content, &context);
        }

        // if (!step.result_cached)
        try step.writeManifest(&man);
    }
};

pub const Content = union(enum) {
    uninitialized,

    mbr: mbr.Table,
    gpt: gpt.Table,

    fs: FileSystem,

    data: std.Build.LazyPath,

    binary: *std.Build.Step.Compile,

    pub fn dupe(content: Content, b: *std.Build) !Content {
        const allocator = b.allocator;

        switch (content) {
            .uninitialized => return content,
            .mbr => |table| {
                var copy = table;
                for (&copy.partitions) |*part| {
                    if (part.*) |*p| {
                        const buf = try b.allocator.create(mbr.Partition);
                        buf.* = p.*.*;
                        buf.data = try buf.data.dupe(b);
                        p.* = buf;
                    }
                }
                return .{ .mbr = copy };
            },
            .gpt => |table| {
                var copy = table;
                const partitions = try allocator.dupe(gpt.Partition, table.partitions);
                for (partitions) |*part| {
                    part.data = try part.data.dupe(b);
                }
                copy.partitions = partitions;
                return .{ .gpt = copy };
            },
            .fs => |fs| {
                var copy = fs;

                copy.label = try allocator.dupe(u8, fs.label);
                const items = try allocator.dupe(FileSystem.Item, fs.items);
                for (items) |*item| {
                    switch (item.*) {
                        .empty_dir => |*dir| {
                            dir.* = try allocator.dupe(u8, dir.*);
                        },
                        .copy_dir, .copy_file => |*cp| {
                            const cp_new = .{
                                .destination = try allocator.dupe(u8, cp.destination),
                                .source = cp.source.dupe(b),
                            };
                            cp.* = cp_new;
                        },
                    }
                }
                copy.items = items;

                switch (copy.format) {
                    .custom => |*path| path.* = path.dupe(b),
                    else => {},
                }

                return .{ .fs = copy };
            },
            .data => |data| {
                return .{ .data = data.dupe(b) };
            },
            .binary => |binary| {
                return .{ .binary = binary };
            },
        }
    }

    pub fn pushDependenciesTo(content: Content, step: *std.Build.Step) void {
        switch (content) {
            .uninitialized => {},
            .mbr => |table| {
                for (table.partitions) |part| {
                    if (part) |p| {
                        p.data.pushDependenciesTo(step);
                    }
                }
            },
            .gpt => |table| {
                for (table.partitions) |part| {
                    part.data.pushDependenciesTo(step);
                }
            },
            .fs => |fs| {
                for (fs.items) |item| {
                    switch (item) {
                        .empty_dir => {},
                        .copy_dir, .copy_file => |*cp| {
                            cp.source.addStepDependencies(step);
                        },
                    }
                }
                if (fs.format == .custom) {
                    fs.format.custom.addStepDependencies(step);
                }
                fs.executable.?.addStepDependencies(step); // Must be resolved already, invoke resolveFileSystems before!
            },
            .data => |data| data.addStepDependencies(step),
            .binary => |binary| step.dependOn(&binary.step),
        }
    }

    pub fn resolveFileSystems(content: *Content, dependency: *std.Build.Dependency) void {
        switch (content.*) {
            .uninitialized => {},
            .mbr => |*table| {
                for (&table.partitions) |*part| {
                    if (part.*) |p| {
                        @constCast(&p.data).resolveFileSystems(dependency);
                    }
                }
            },
            .gpt => |*table| {
                for (table.partitions) |*part| {
                    @constCast(&part.data).resolveFileSystems(dependency);
                }
            },
            .fs => |*fs| {
                fs.executable = resolveFilesystemMaker(dependency, fs.format);
            },
            .data, .binary => {},
        }
    }
};

pub const mbr = struct {
    pub const Table = struct {
        bootloader: [440]u8 = .{0} ** 440,
        disk_id: ?u32 = null,
        partitions: [4]?*const Partition,
    };

    pub const Partition = struct {
        offset: ?u64 = null,
        size: u64,

        bootable: bool,
        type: PartitionType,

        data: Content,
    };

    /// https://en.wikipedia.org/wiki/Partition_type
    pub const PartitionType = enum(u8) {
        empty = 0x00,

        fat12 = 0x01,
        ntfs = 0x07,

        fat32_chs = 0x0B,
        fat32_lba = 0x0C,

        fat16_lba = 0x0E,

        linux_swap = 0x82,
        linux_fs = 0x83,
        linux_lvm = 0x8E,

        // Output from fdisk (util-linux 2.38.1)
        // 00 Leer             27 Verst. NTFS Win  82 Linux Swap / So  c1 DRDOS/sec (FAT-
        // 01 FAT12            39 Plan 9           83 Linux            c4 DRDOS/sec (FAT-
        // 02 XENIX root       3c PartitionMagic   84 versteckte OS/2  c6 DRDOS/sec (FAT-
        // 03 XENIX usr        40 Venix 80286      85 Linux erweitert  c7 Syrinx
        // 04 FAT16 <32M       41 PPC PReP Boot    86 NTFS Datenträge  da Keine Dateisyst
        // 05 Erweiterte       42 SFS              87 NTFS Datenträge  db CP/M / CTOS / .
        // 06 FAT16            4d QNX4.x           88 Linux Klartext   de Dell Dienstprog
        // 07 HPFS/NTFS/exFAT  4e QNX4.x 2. Teil   8e Linux LVM        df BootIt
        // 08 AIX              4f QNX4.x 3. Teil   93 Amoeba           e1 DOS-Zugriff
        // 09 AIX bootfähig    50 OnTrack DM       94 Amoeba BBT       e3 DOS R/O
        // 0a OS/2-Bootmanage  51 OnTrack DM6 Aux  9f BSD/OS           e4 SpeedStor
        // 0b W95 FAT32        52 CP/M             a0 IBM Thinkpad Ru  ea Linux erweitert
        // 0c W95 FAT32 (LBA)  53 OnTrack DM6 Aux  a5 FreeBSD          eb BeOS Dateisyste
        // 0e W95 FAT16 (LBA)  54 OnTrackDM6       a6 OpenBSD          ee GPT
        // 0f W95 Erw. (LBA)   55 EZ-Drive         a7 NeXTSTEP         ef EFI (FAT-12/16/
        // 10 OPUS             56 Golden Bow       a8 Darwin UFS       f0 Linux/PA-RISC B
        // 11 Verst. FAT12     5c Priam Edisk      a9 NetBSD           f1 SpeedStor
        // 12 Compaq Diagnost  61 SpeedStor        ab Darwin Boot      f4 SpeedStor
        // 14 Verst. FAT16 <3  63 GNU HURD oder S  af HFS / HFS+       f2 DOS sekundär
        // 16 Verst. FAT16     64 Novell Netware   b7 BSDi Dateisyste  f8 EBBR geschützt
        // 17 Verst. HPFS/NTF  65 Novell Netware   b8 BSDI Swap        fb VMware VMFS
        // 18 AST SmartSleep   70 DiskSecure Mult  bb Boot-Assistent   fc VMware VMKCORE
        // 1b Verst. W95 FAT3  75 PC/IX            bc Acronis FAT32 L  fd Linux RAID-Auto
        // 1c Verst. W95 FAT3  80 Altes Minix      be Solaris Boot     fe LANstep
        // 1e Verst. W95 FAT1  81 Minix / altes L  bf Solaris          ff BBT
        // 24 NEC DOS

        _,
    };

    pub fn encodeMbrChsEntry(lba: u32) [3]u8 {
        var chs = lbaToChs(lba);

        if (chs.cylinder >= 1024) {
            chs = .{
                .cylinder = 1023,
                .head = 255,
                .sector = 63,
            };
        }

        const cyl: u10 = @intCast(chs.cylinder);
        const head: u8 = @intCast(chs.head);
        const sect: u6 = @intCast(chs.sector);

        const sect_cyl: u8 = @as(u8, 0xC0) & @as(u8, @truncate(cyl >> 2)) + sect;
        const sect_8: u8 = @truncate(cyl);

        return .{ head, sect_cyl, sect_8 };
    }

    const CHS = struct {
        cylinder: u32,
        head: u8, // limit: 256
        sector: u6, // limit: 64

        pub fn init(c: u32, h: u8, s: u6) CHS {
            return .{ .cylinder = c, .head = h, .sector = s };
        }
    };

    pub fn lbaToChs(lba: u32) CHS {
        const hpc = 255;
        const spt = 63;

        // C, H and S are the cylinder number, the head number, and the sector number
        // LBA is the logical block address
        // HPC is the maximum number of heads per cylinder (reported by disk drive, typically 16 for 28-bit LBA)
        // SPT is the maximum number of sectors per track (reported by disk drive, typically 63 for 28-bit LBA)
        // LBA = (C * HPC + H) * SPT + (S - 1)

        const sector = (lba % spt);
        const cyl_head = (lba / spt);

        const head = (cyl_head % hpc);
        const cyl = (cyl_head / hpc);

        return CHS{
            .sector = @intCast(sector + 1),
            .head = @intCast(head),
            .cylinder = cyl,
        };
    }
};

// test "lba to chs" {
//     // table from https://en.wikipedia.org/wiki/Logical_block_addressing#CHS_conversion
//     try std.testing.expectEqual(mbr.CHS.init(0, 0, 1), mbr.lbaToChs(0));
//     try std.testing.expectEqual(mbr.CHS.init(0, 0, 2), mbr.lbaToChs(1));
//     try std.testing.expectEqual(mbr.CHS.init(0, 0, 3), mbr.lbaToChs(2));
//     try std.testing.expectEqual(mbr.CHS.init(0, 0, 63), mbr.lbaToChs(62));
//     try std.testing.expectEqual(mbr.CHS.init(0, 1, 1), mbr.lbaToChs(63));
//     try std.testing.expectEqual(mbr.CHS.init(0, 15, 1), mbr.lbaToChs(945));
//     try std.testing.expectEqual(mbr.CHS.init(0, 15, 63), mbr.lbaToChs(1007));
//     try std.testing.expectEqual(mbr.CHS.init(1, 0, 1), mbr.lbaToChs(1008));
//     try std.testing.expectEqual(mbr.CHS.init(1, 0, 63), mbr.lbaToChs(1070));
//     try std.testing.expectEqual(mbr.CHS.init(1, 1, 1), mbr.lbaToChs(1071));
//     try std.testing.expectEqual(mbr.CHS.init(1, 1, 63), mbr.lbaToChs(1133));
//     try std.testing.expectEqual(mbr.CHS.init(1, 2, 1), mbr.lbaToChs(1134));
//     try std.testing.expectEqual(mbr.CHS.init(1, 15, 63), mbr.lbaToChs(2015));
//     try std.testing.expectEqual(mbr.CHS.init(2, 0, 1), mbr.lbaToChs(2016));
//     try std.testing.expectEqual(mbr.CHS.init(15, 15, 63), mbr.lbaToChs(16127));
//     try std.testing.expectEqual(mbr.CHS.init(16, 0, 1), mbr.lbaToChs(16128));
//     try std.testing.expectEqual(mbr.CHS.init(31, 15, 63), mbr.lbaToChs(32255));
//     try std.testing.expectEqual(mbr.CHS.init(32, 0, 1), mbr.lbaToChs(32256));
//     try std.testing.expectEqual(mbr.CHS.init(16319, 15, 63), mbr.lbaToChs(16450559));
//     try std.testing.expectEqual(mbr.CHS.init(16382, 15, 63), mbr.lbaToChs(16514063));
// }

pub const gpt = struct {
    pub const Guid = [16]u8;

    pub const Table = struct {
        disk_id: Guid,

        partitions: []const Partition,
    };

    pub const Partition = struct {
        type: Guid,
        part_id: Guid,

        offset: ?u64 = null,
        size: u64,

        name: [36]u16,

        attributes: Attributes,

        data: Content,

        pub const Attributes = packed struct(u32) {
            system: bool,
            efi_hidden: bool,
            legacy: bool,
            read_only: bool,
            hidden: bool,
            no_automount: bool,

            padding: u26 = 0,
        };
    };

    /// https://en.wikipedia.org/wiki/GUID_Partition_Table#Partition_type_GUIDs
    pub const PartitionType = struct {
        pub const unused: Guid = .{};

        pub const microsoft_basic_data: Guid = .{};
        pub const microsoft_reserved: Guid = .{};

        pub const windows_recovery: Guid = .{};

        pub const plan9: Guid = .{};

        pub const linux_swap: Guid = .{};
        pub const linux_fs: Guid = .{};
        pub const linux_reserved: Guid = .{};
        pub const linux_lvm: Guid = .{};
    };

    pub fn nameLiteral(comptime name: []const u8) [36]u16 {
        return comptime blk: {
            var buf: [36]u16 = undefined;
            const len = std.unicode.utf8ToUtf16Le(&buf, name) catch |err| @compileError(@tagName(err));
            @memset(buf[len..], 0);
            break :blk &buf;
        };
    }
};

pub const FileSystem = struct {
    pub const Format = union(enum) {
        pub const Tag = std.meta.Tag(@This());

        fat12,
        fat16,
        fat32,

        ext2,
        ext3,
        ext4,

        exfat,
        ntfs,

        iso_9660,
        iso_13490,
        udf,

        /// usage: mkfs.<tool> <image> <base> <length> <filesystem> <ops...>
        ///  <image> is a path to the image file
        ///  <base> is the byte base of the file system
        ///  <length> is the byte length of the file system
        ///  <filesystem> is the file system that should be used to format
        ///  <ops...> is a list of operations that should be performed on the file system:
        ///  - format            Formats the disk image.
        ///  - mount             Mounts the file system, must be before all following:
        ///  - mkdir:<dst>       Creates directory <dst> and all necessary parents.
        ///  - file:<src>:<dst>  Copy <src> to path <dst>. If <dst> exists, it will be overwritten.
        ///  - dir:<src>:<dst>   Copy <src> recursively into <dst>. If <dst> exists, they will be merged.
        ///
        /// <dst> paths are always rooted, even if they don't start with a /, and always use / as a path separator.
        ///
        custom: std.Build.LazyPath,
    };

    pub const Copy = struct {
        source: std.Build.LazyPath,
        destination: []const u8,
    };

    pub const Item = union(enum) {
        empty_dir: []const u8,
        copy_dir: Copy,
        copy_file: Copy,
    };

    format: Format,
    label: []const u8,
    items: []const Item,

    // private:
    executable: ?std.Build.LazyPath = null,
};

pub const FileSystemBuilder = struct {
    b: *std.Build,
    list: std.ArrayListUnmanaged(FileSystem.Item),

    pub fn init(b: *std.Build) FileSystemBuilder {
        return FileSystemBuilder{
            .b = b,
            .list = .{},
        };
    }

    pub fn finalize(fsb: *FileSystemBuilder, options: struct {
        format: FileSystem.Format,
        label: []const u8,
    }) FileSystem {
        return FileSystem{
            .format = options.format,
            .label = fsb.b.dupe(options.label),
            .items = fsb.list.toOwnedSlice(fsb.b.allocator) catch @panic("out of memory"),
        };
    }

    pub fn addFile(fsb: *FileSystemBuilder, source: std.Build.LazyPath, destination: []const u8) void {
        fsb.list.append(fsb.b.allocator, .{
            .copy_file = .{
                .source = source.dupe(fsb.b),
                .destination = fsb.b.dupe(destination),
            },
        }) catch @panic("out of memory");
    }

    pub fn addDirectory(fsb: *FileSystemBuilder, source: std.Build.LazyPath, destination: []const u8) void {
        fsb.list.append(fsb.b.allocator, .{
            .copy_dir = .{
                .source = source.dupe(fsb.b),
                .destination = fsb.b.dupe(destination),
            },
        }) catch @panic("out of memory");
    }

    pub fn mkdir(fsb: *FileSystemBuilder, destination: []const u8) void {
        fsb.list.append(fsb.b.allocator, .{
            .empty_dir = fsb.b.dupe(destination),
        }) catch @panic("out of memory");
    }
};
