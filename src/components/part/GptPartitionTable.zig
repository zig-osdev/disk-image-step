const std = @import("std");
const MbrPartTable = @import("MbrPartitionTable.zig");
const dim = @import("../../dim.zig");

const PartTable = @This();

const block_size = 512; // TODO support other block sizes

disk_id: ?Guid,
partitions: []Partition,

pub fn parse(ctx: dim.Context) !dim.Content {
    const pt = try ctx.alloc_object(PartTable);
    pt.* = PartTable{
        .disk_id = null,
        .partitions = undefined,
    };

    var partitions = std.ArrayList(Partition).init(ctx.get_arena());
    loop: while (true) {
        const kw = try ctx.parse_enum(enum {
            guid,
            part,
            endgpt,
        });
        switch (kw) {
            .guid => {
                const guid_str = try ctx.parse_string();
                if (guid_str.len != 36)
                    return ctx.report_fatal_error("Invalid disk GUID: wrong length", .{});

                pt.disk_id = Guid.parse(guid_str[0..36].*) catch |err|
                    return ctx.report_fatal_error("Invalid disk GUID: {}", .{err});
            },
            .part => (try partitions.addOne()).* = try parsePartition(ctx),
            .endgpt => break :loop,
        }
    }

    pt.partitions = partitions.items;

    if (pt.partitions.len != 0) {
        for (pt.partitions[0..pt.partitions.len -| 2], 0..) |part, i| {
            if (part.size == null) {
                try ctx.report_nonfatal_error("GPT partition {} does not have a size, but it is not last.", .{i});
            }
        }

        var all_auto = true;
        var all_manual = true;

        for (pt.partitions) |part| {
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

    if (pt.partitions.len > 128) {
        return ctx.report_fatal_error("number of partitions ({}) exceeded maximum of 128", .{pt.partitions.len});
    }

    return .create_handle(pt, .create(PartTable, .{
        .render_fn = render,
    }));
}

fn parsePartition(ctx: dim.Context) !Partition {
    var part = Partition{
        .type = undefined,
        .part_id = null,
        .size = null,
        .name = @splat(0),
        .offset = null,
        .attributes = .{
            .required = false,
            .no_block_io_protocol = false,
            .legacy = false,
        },
        .contains = .empty,
    };

    var updater: dim.FieldUpdater(Partition, &.{
        .part_id,
        .size,
        .name,
        .offset,
        .attributes,
    }) = .init(ctx, &part);

    parse_loop: while (true) {
        const kw = try ctx.parse_enum(enum {
            type,
            name,
            guid,
            size,
            offset,
            contains,
            endpart,
        });
        switch (kw) {
            .type => {
                const type_name = try ctx.parse_string();

                const type_guid = known_types.get(type_name) orelse blk: {
                    if (type_name.len == 36) if (Guid.parse(type_name[0..36].*)) |guid| break :blk guid else |_| {};
                    return ctx.report_fatal_error("unknown partition type: `{}`", .{std.zig.fmtEscapes(type_name)});
                };

                try updater.set(.type, type_guid);
            },
            .name => {
                const string = try ctx.parse_string();
                const name = stringToName(string) catch return error.BadStringLiteral;

                try updater.set(.name, name);
            },
            .guid => {
                const string = try ctx.parse_string();
                if (string.len != 36)
                    return ctx.report_fatal_error("Invalid partition GUID: wrong length", .{});

                try updater.set(.part_id, Guid.parse(string[0..36].*) catch |err| {
                    return ctx.report_fatal_error("Invalid partition GUID: {}", .{err});
                });
            },
            .size => try updater.set(.size, try ctx.parse_mem_size()),
            .offset => try updater.set(.offset, try ctx.parse_mem_size()),
            .contains => try updater.set(.contains, try ctx.parse_content()),
            .endpart => break :parse_loop,
        }
    }

    try updater.validate();

    return part;
}

pub fn render(table: *PartTable, stream: *dim.BinaryStream) dim.Content.RenderError!void {
    const random = std.crypto.random;

    const lba_len = stream.length / block_size;
    const secondary_pth_lba = lba_len - 1;
    const secondary_pe_array_lba = secondary_pth_lba - 32;
    const max_partition_lba = secondary_pe_array_lba - 1;

    // create the partition entry array, lba 2 through 33
    var pe_blocks: [block_size * 32]u8 = @splat(0);
    const partition_entries = std.mem.bytesAsSlice([0x80]u8, &pe_blocks);

    var next_lba: u64 = 34;
    for (table.partitions[0..], partition_entries[0..table.partitions.len], 0..) |partition, *entry, i| {
        const offset = partition.offset orelse next_lba * block_size;
        const size = partition.size orelse if (i == table.partitions.len - 1)
            ((max_partition_lba + 1) * block_size) - offset
        else
            return error.ConfigurationError;

        if (offset % block_size != 0) {
            std.log.err("partition offset is not divisible by {}!", .{block_size});
            return error.ConfigurationError;
        }

        if (size % block_size != 0) {
            std.log.err("partition size is not divisible by {}!", .{block_size});
            return error.ConfigurationError;
        }

        const start_lba = @divExact(offset, block_size);
        const end_lba = @divExact(size + offset, block_size) - 1;

        if (start_lba <= 33) {
            std.log.err("partition {} overlaps with gpt. the partition begins at lba {}, and the gpt ends at {}", .{ i + 1, start_lba, 33 });
            return error.ConfigurationError;
        }

        if (end_lba >= secondary_pe_array_lba) {
            std.log.err("partition {} overlaps with backup gpt. the partition ends at lba {}, and the backup gpt starts at {}", .{ i + 1, end_lba, secondary_pe_array_lba });
            return error.ConfigurationError;
        }

        entry[0x00..0x10].* = @bitCast(partition.type);
        entry[0x10..0x20].* = @bitCast(partition.part_id orelse Guid.rand(random));
        std.mem.writeInt(u64, entry[0x20..0x28], start_lba, .little);
        std.mem.writeInt(u64, entry[0x28..0x30], end_lba, .little);
        // TODO attributes
        entry[0x38..].* = @bitCast(partition.name);

        var sub_view = try stream.slice(offset, size);
        try partition.contains.render(&sub_view);

        next_lba = end_lba + 1;
    }

    // create the protective mbr
    var mbr: MbrPartTable = .{
        .bootloader = null,
        .disk_id = null,
        .partitions = .{ .{
            .offset = block_size,
            .size = null,
            .bootable = false,
            .type = 0xee,
            .contains = .empty,
        }, null, null, null },
    };

    var gpt_header_block: [block_size]u8 = @splat(0);
    const gpt_header = gpt_header_block[0x0..0x5c];

    gpt_header[0x00..0x08].* = "EFI PART".*;
    gpt_header[0x08..0x0c].* = .{ 0x0, 0x0, 0x1, 0x0 };
    std.mem.writeInt(u32, gpt_header[0x0c..0x10], 0x5c, .little); // Header size
    std.mem.writeInt(u64, gpt_header[0x18..0x20], 1, .little); // LBA of this header
    std.mem.writeInt(u64, gpt_header[0x20..0x28], secondary_pth_lba, .little); // LBA of other header
    std.mem.writeInt(u64, gpt_header[0x28..0x30], 34, .little); // First usable LBA
    std.mem.writeInt(u64, gpt_header[0x30..0x38], max_partition_lba, .little); // Last usable LBA
    gpt_header[0x38..0x48].* = @bitCast(table.disk_id orelse Guid.rand(random));
    std.mem.writeInt(u64, gpt_header[0x48..0x50], 2, .little); // First LBA of the partition entry array
    std.mem.writeInt(u32, gpt_header[0x50..0x54], 0x80, .little); // Number of partition entries
    std.mem.writeInt(u32, gpt_header[0x54..0x58], 0x80, .little); // Size of a partition entry

    var backup_gpt_header_block: [block_size]u8 = gpt_header_block;
    const backup_gpt_header = backup_gpt_header_block[0x0..0x5c];

    std.mem.writeInt(u64, backup_gpt_header[0x18..0x20], secondary_pth_lba, .little); // LBA of this header
    std.mem.writeInt(u64, backup_gpt_header[0x20..0x28], 1, .little); // LBA of other header
    std.mem.writeInt(u64, backup_gpt_header[0x48..0x50], secondary_pe_array_lba, .little); // First LBA of the backup partition entry array

    const pe_array_crc32 = std.hash.Crc32.hash(&pe_blocks);
    std.mem.writeInt(u32, gpt_header[0x58..0x5c], pe_array_crc32, .little); // CRC32 of partition entries array
    std.mem.writeInt(u32, backup_gpt_header[0x58..0x5c], pe_array_crc32, .little); // CRC32 of partition entries array

    const gpt_header_crc32 = std.hash.Crc32.hash(gpt_header);
    std.mem.writeInt(u32, gpt_header[0x10..0x14], gpt_header_crc32, .little); // CRC32 of header

    const backup_gpt_header_crc32 = std.hash.Crc32.hash(backup_gpt_header);
    std.mem.writeInt(u32, backup_gpt_header[0x10..0x14], backup_gpt_header_crc32, .little); // CRC32 of backup header

    // write everything we generated to disk
    try mbr.render(stream);
    try stream.write(block_size, &gpt_header_block);
    try stream.write(block_size * 2, &pe_blocks);
    try stream.write(block_size * secondary_pe_array_lba, &pe_blocks);
    try stream.write(block_size * secondary_pth_lba, &backup_gpt_header_block);
}

fn crc32Header(header: [0x5c]u8) u32 {
    var crc32 = std.hash.Crc32.init();
    crc32.update(header[0x00..0x14]);
    crc32.update(header[0x18..]);
    return crc32.final();
}

pub const Guid = extern struct {
    time_low: u32, // LE
    time_mid: u16, // LE
    time_high_and_version: u16, // LE
    clock_seq_high_and_reserved: u8,
    clock_seq_low: u8,
    node: [6]u8, // byte array

    pub const epoch = -12219292725;

    pub fn rand(random: std.Random) Guid {
        var ret: Guid = undefined;
        random.bytes(std.mem.asBytes(&ret));

        ret.clock_seq_high_and_reserved &= 0b00111111;
        ret.clock_seq_high_and_reserved |= 0b10000000;

        ret.time_high_and_version &= std.mem.nativeToLittle(u16, 0b00001111_11111111);
        ret.time_high_and_version |= std.mem.nativeToLittle(u16, 0b01000000_00000000);

        return ret;
    }

    pub fn parse(str: [36]u8) !Guid {
        const tl_hex = str[0..8];
        if (str[8] != '-') return error.MissingSeparator;
        const tm_hex = str[9..13];
        if (str[13] != '-') return error.MissingSeparator;
        const th_hex = str[14..18];
        if (str[18] != '-') return error.MissingSeparator;
        const cs_hex = str[19..23];
        if (str[23] != '-') return error.MissingSeparator;
        const node_hex = str[24..36];

        const tl_be: u32 = @bitCast(try hexToBytes(tl_hex.*));
        const tm_be: u16 = @bitCast(try hexToBytes(tm_hex.*));
        const th_be: u16 = @bitCast(try hexToBytes(th_hex.*));
        const cs_bytes = try hexToBytes(cs_hex.*);
        const node_bytes = try hexToBytes(node_hex.*);

        const tl_le = @byteSwap(tl_be);
        const tm_le = @byteSwap(tm_be);
        const th_le = @byteSwap(th_be);
        const csh = cs_bytes[0];
        const csl = cs_bytes[1];

        return Guid{
            .time_low = tl_le,
            .time_mid = tm_le,
            .time_high_and_version = th_le,
            .clock_seq_high_and_reserved = csh,
            .clock_seq_low = csl,
            .node = node_bytes,
        };
    }

    fn HexToBytesType(comptime T: type) type {
        const ti = @typeInfo(T);
        const len = @divExact(ti.array.len, 2);
        return @Type(.{ .array = .{
            .len = len,
            .child = u8,
            .sentinel_ptr = null,
        } });
    }

    fn hexToBytes(hex: anytype) !HexToBytesType(@TypeOf(hex)) {
        var ret: [@divExact(hex.len, 2)]u8 = undefined;

        for (0..ret.len) |i| {
            const hi = try std.fmt.charToDigit(hex[i * 2], 16);
            const lo = try std.fmt.charToDigit(hex[i * 2 + 1], 16);
            ret[i] = (hi << 4) | lo;
        }

        return ret;
    }
};

pub const Partition = struct {
    type: Guid,
    part_id: ?Guid,

    offset: ?u64 = null,
    size: ?u64 = null,

    name: [36]u16,

    attributes: Attributes,

    contains: dim.Content,

    pub const Attributes = packed struct(u64) {
        required: bool, // should be true for an esp
        no_block_io_protocol: bool,
        legacy: bool,

        reserved: u45 = 0,

        type_specific: u16 = 0,
    };
};

// TODO fill from https://en.wikipedia.org/wiki/GUID_Partition_Table#Partition_type_GUIDs
pub const known_types = std.StaticStringMap(Guid).initComptime(.{
    .{ "unused", Guid.parse("00000000-0000-0000-0000-000000000000".*) catch unreachable },
    .{ "efi-system", Guid.parse("C12A7328-F81F-11D2-BA4B-00A0C93EC93B".*) catch unreachable },
});

// struct {
//     pub const unused: Guid = .{};

//     pub const microsoft_basic_data: Guid = .{};
//     pub const microsoft_reserved: Guid = .{};

//     pub const windows_recovery: Guid = .{};

//     pub const plan9: Guid = .{};

//     pub const linux_swap: Guid = .{};
//     pub const linux_fs: Guid = .{};
//     pub const linux_reserved: Guid = .{};
//     pub const linux_lvm: Guid = .{};
// };

pub fn nameLiteral(comptime name: []const u8) [36]u16 {
    return comptime blk: {
        var buf: [36]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(&buf, name) catch |err| @compileError(@tagName(err));
        @memset(buf[len..], 0);
        break :blk &buf;
    };
}

pub fn stringToName(name: []const u8) ![36]u16 {
    var buf: [36]u16 = @splat(0);

    if (try std.unicode.calcUtf16LeLen(name) > 36) return error.StringTooLong;

    _ = try std.unicode.utf8ToUtf16Le(&buf, name);
    return buf;
}
