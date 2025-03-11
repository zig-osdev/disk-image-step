//!
//! The `mbr-part` content will assembly a managed boot record partition table.
//!
//!
const std = @import("std");
const dim = @import("../../dim.zig");

const PartTable = @This();

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
                pf.partitions[next_part_id] = .unused;
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
        .type = .empty,
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
            .type => updater.set(.type, try ctx.parse_enum(PartitionType)),
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

fn render(self: *PartTable, stream: *dim.BinaryStream) dim.Content.RenderError!void {
    _ = self;
    _ = stream;
}

// .mbr => |table| { //  MbrTable
//     {
//         var boot_sector: [512]u8 = .{0} ** 512;

//         @memcpy(boot_sector[0..table.bootloader.len], &table.bootloader);

//         std.mem.writeInt(u32, boot_sector[0x1B8..0x1BC], if (table.disk_id) |disk_id| disk_id else 0x0000_0000, .little);
//         std.mem.writeInt(u16, boot_sector[0x1BC..0x1BE], 0x0000, .little);

//         var all_auto = true;
//         var all_manual = true;
//         for (table.partitions) |part_or_null| {
//             const part = part_or_null orelse continue;

//             if (part.offset != null) {
//                 all_auto = false;
//             } else {
//                 all_manual = false;
//             }
//         }

//         if (!all_auto and !all_manual) {
//            std.log.err("{s}: not all partitions have an explicit offset!", .{context.slice()});
//             return error.InvalidSectorBoundary;
//         }

//         const part_base = 0x01BE;
//         var auto_offset: u64 = 2048;
//         for (table.partitions, 0..) |part_or_null, part_id| {
//             const reset_len = context.len;
//             defer context.len = reset_len;

//             var buffer: [64]u8 = undefined;
//             context.appendSliceAssumeCapacity(std.fmt.bufPrint(&buffer, "[{}]", .{part_id}) catch unreachable);

//             const desc = boot_sector[part_base + 16 * part_id ..][0..16];

//             if (part_or_null) |part| {
//                 // https://wiki.osdev.org/MBR#Partition_table_entry_format

//                 const part_offset = part.offset orelse auto_offset;

//                 if ((part_offset % 512) != 0) {
//                     std.log.err("{s}: .offset is not divisible by 512!", .{context.slice()});
//                     return error.InvalidSectorBoundary;
//                 }
//                 if ((part.size % 512) != 0) {
//                     std.log.err("{s}: .size is not divisible by 512!", .{context.slice()});
//                     return error.InvalidSectorBoundary;
//                 }

//                 const lba_u64 = @divExact(part_offset, 512);
//                 const size_u64 = @divExact(part.size, 512);

//                 const lba = std.math.cast(u32, lba_u64) orelse {
//                     std.log.err("{s}: .offset is out of bounds!", .{context.slice()});
//                     return error.InvalidSectorBoundary;
//                 };
//                 const size = std.math.cast(u32, size_u64) orelse {
//                     std.log.err("{s}: .size is out of bounds!", .{context.slice()});
//                     return error.InvalidSectorBoundary;
//                 };

//                 desc[0] = if (part.bootable) 0x80 else 0x00;

//                 desc[1..4].* = mbr.encodeMbrChsEntry(lba); // chs_start
//                 desc[4] = @intFromEnum(part.type);
//                 desc[5..8].* = mbr.encodeMbrChsEntry(lba + size - 1); // chs_end
//                 std.mem.writeInt(u32, desc[8..12], lba, .little); // lba_start
//                 std.mem.writeInt(u32, desc[12..16], size, .little); // block_count

//                 auto_offset += part.size;
//             } else {
//                 @memset(desc, 0); // inactive
//             }
//         }
//         boot_sector[0x01FE] = 0x55;
//         boot_sector[0x01FF] = 0xAA;

//         try disk.handle.writeAll(&boot_sector);
//     }

//     {
//         var auto_offset: u64 = 2048;
//         for (table.partitions, 0..) |part_or_null, part_id| {
//             const part = part_or_null orelse continue;

//             const reset_len = context.len;
//             defer context.len = reset_len;

//             var buffer: [64]u8 = undefined;
//             context.appendSliceAssumeCapacity(std.fmt.bufPrint(&buffer, "[{}]", .{part_id}) catch unreachable);

//             try writeDiskImage(b, asking, disk, base + auto_offset, part.size, part.data, context);

//             auto_offset += part.size;
//         }
//     }
// },

pub const Partition = struct {
    pub const unused: Partition = .{
        .offset = null,
        .size = 0,
        .bootable = false,
        .type = .empty,
        .contains = .empty,
    };

    offset: ?u64 = null,
    size: ?u64,

    bootable: bool,
    type: PartitionType,

    contains: dim.Content,
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
