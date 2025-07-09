//!
//! The `mbr-part` content will assembly a managed boot record partition table.
//!
//!
const std = @import("std");
const dim = @import("../../dim.zig");

const PartTable = @This();

const block_size = 512;

bootloader: ?dim.Content,
disk_id: ?u32,
partitions: [4]?Partition,

pub fn parse(ctx: dim.Context) !dim.Content {
    const pf = try ctx.alloc_object(PartTable);
    pf.* = .{
        .bootloader = null,
        .disk_id = null,
        .partitions = .{
            null,
            null,
            null,
            null,
        },
    };

    var next_part_id: usize = 0;
    var last_part_id: ?usize = null;
    while (next_part_id < pf.partitions.len) {
        const kw = try ctx.parse_enum(enum {
            bootloader,
            part,
            ignore,
        });
        switch (kw) {
            .bootloader => {
                const bootloader_content = try ctx.parse_content();
                if (pf.bootloader != null) {
                    try ctx.report_nonfatal_error("mbr-part.bootloader specified twice!", .{});
                }
                pf.bootloader = bootloader_content;
            },
            .ignore => {
                pf.partitions[next_part_id] = null;
                next_part_id += 1;
            },
            .part => {
                pf.partitions[next_part_id] = try parse_partition(ctx);
                last_part_id = next_part_id;
                next_part_id += 1;
            },
        }
    }

    if (last_part_id) |part_id| {
        for (0..part_id -| 1) |prev| {
            if (pf.partitions[prev].?.size == null) {
                try ctx.report_nonfatal_error("MBR partition {} does not have a size, but is not last.", .{prev});
            }
        }

        var all_auto = true;
        var all_manual = true;
        for (pf.partitions) |part_or_null| {
            const part = part_or_null orelse continue;

            if (part.offset != null) {
                all_auto = false;
            } else {
                all_manual = false;
            }
        }

        if (!all_auto and !all_manual) {
            try ctx.report_nonfatal_error("not all partitions have an explicit offset!", .{});
        }
    }

    return .create_handle(pf, .create(PartTable, .{
        .render_fn = render,
    }));
}

fn parse_partition(ctx: dim.Context) !Partition {
    var part: Partition = .{
        .offset = null,
        .size = null,
        .bootable = false,
        .type = 0x00,
        .contains = .empty,
    };

    var updater: dim.FieldUpdater(Partition, &.{
        .offset,
        .size,
        .bootable,
    }) = .init(ctx, &part);

    parse_loop: while (true) {
        const kw = try ctx.parse_enum(enum {
            type,
            bootable,
            size,
            offset,
            contains,
            endpart,
        });
        try switch (kw) {
            .type => {
                const part_name = try ctx.parse_string();

                const encoded = if (std.fmt.parseInt(u8, part_name, 0)) |value|
                    value
                else |_|
                    known_partition_types.get(part_name) orelse blk: {
                        try ctx.report_nonfatal_error("unknown partition type '{}'", .{std.zig.fmtEscapes(part_name)});
                        break :blk 0x00;
                    };

                try updater.set(.type, encoded);
            },
            .bootable => updater.set(.bootable, true),
            .size => updater.set(.size, try ctx.parse_mem_size()),
            .offset => updater.set(.offset, try ctx.parse_mem_size()),
            .contains => updater.set(.contains, try ctx.parse_content()),
            .endpart => break :parse_loop,
        };
    }

    try updater.validate();

    return part;
}

pub fn render(table: *PartTable, stream: *dim.BinaryStream) dim.Content.RenderError!void {
    const last_part_id = blk: {
        var last: usize = 0;
        for (table.partitions, 0..) |p, i| {
            if (p != null)
                last = i;
        }
        break :blk last;
    };

    const PartInfo = struct {
        offset: u64,
        size: u64,
    };
    var part_infos: [4]?PartInfo = @splat(null);

    // Compute and write boot sector, based on the follow:
    // - https://en.wikipedia.org/wiki/Master_boot_record#Sector_layout
    {
        var boot_sector: [block_size]u8 = @splat(0);

        if (table.bootloader) |bootloader| {
            var sector: dim.BinaryStream = .init_buffer(&boot_sector);

            try bootloader.render(&sector);

            const upper_limit: u64 = if (table.disk_id != null)
                0x01B8
            else
                0x1BE;

            if (sector.virtual_offset >= upper_limit) {
                // TODO(fqu): Emit warning diagnostics here that parts of the bootloader will be overwritten by the MBR data.
            }
        }

        if (table.disk_id) |disk_id| {
            std.mem.writeInt(u32, boot_sector[0x1B8..0x1BC], disk_id, .little);
        }

        // TODO(fqu): Implement "0x5A5A if copy-protected"
        std.mem.writeInt(u16, boot_sector[0x1BC..0x1BE], 0x0000, .little);

        const part_base = 0x01BE;
        var auto_offset: u64 = 2048 * block_size; // TODO(fqu): Make this configurable by allowing `offset` on the first partition, but still allow auto-layouting
        for (table.partitions, &part_infos, 0..) |part_or_null, *pinfo, part_id| {
            const desc: *[16]u8 = boot_sector[part_base + 16 * part_id ..][0..16];

            // Initialize to "inactive" state
            desc.* = @splat(0);
            pinfo.* = null;

            if (part_or_null) |part| {
                // https://wiki.osdev.org/MBR#Partition_table_entry_format

                const part_offset = part.offset orelse auto_offset;
                const part_size = part.size orelse if (part_id == last_part_id)
                    std.mem.alignBackward(u64, stream.length - part_offset, block_size)
                else
                    return error.ConfigurationError;

                pinfo.* = .{
                    .offset = part_offset,
                    .size = part_size,
                };

                if ((part_offset % block_size) != 0) {
                    std.log.err("partition offset is not divisible by {}!", .{block_size});
                    return error.ConfigurationError;
                }
                if ((part_size % block_size) != 0) {
                    std.log.err("partition size is not divisible by {}!", .{block_size});
                    return error.ConfigurationError;
                }

                const lba_u64 = @divExact(part_offset, block_size);
                const size_u64 = @divExact(part_size, block_size);

                const lba = std.math.cast(u32, lba_u64) orelse {
                    std.log.err("partition offset is out of bounds!", .{});
                    return error.ConfigurationError;
                };
                const size = std.math.cast(u32, size_u64) orelse {
                    std.log.err("partition size is out of bounds!", .{});
                    return error.ConfigurationError;
                };

                desc[0] = if (part.bootable) 0x80 else 0x00;

                desc[1..4].* = encodeMbrChsEntry(lba); // chs_start
                desc[4] = part.type;
                desc[5..8].* = encodeMbrChsEntry(lba + size - 1); // chs_end
                std.mem.writeInt(u32, desc[8..12], lba, .little); // lba_start
                std.mem.writeInt(u32, desc[12..16], size, .little); // block_count

                auto_offset += part_size;
            }
        }
        boot_sector[0x01FE] = 0x55;
        boot_sector[0x01FF] = 0xAA;

        try stream.write(0, &boot_sector);
    }

    for (part_infos, table.partitions) |maybe_info, maybe_part| {
        const part = maybe_part orelse continue;
        const info = maybe_info orelse unreachable;

        var sub_view = try stream.slice(info.offset, info.size);

        try part.contains.render(&sub_view);
    }
}

pub const Partition = struct {
    offset: ?u64,
    size: ?u64,

    bootable: bool,
    type: u8,

    contains: dim.Content,
};

// TODO: Fill from https://en.wikipedia.org/wiki/Partition_type
const known_partition_types = std.StaticStringMap(u8).initComptime(.{
    .{ "empty", 0x00 },

    .{ "fat12", 0x01 },

    .{ "ntfs", 0x07 },

    .{ "fat32-chs", 0x0B },
    .{ "fat32-lba", 0x0C },

    .{ "fat16-lba", 0x0E },

    .{ "linux-swap", 0x82 },
    .{ "linux-fs", 0x83 },
    .{ "linux-lvm", 0x8E },
});

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
