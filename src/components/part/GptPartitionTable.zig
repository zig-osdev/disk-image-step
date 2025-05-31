const std = @import("std");
const dim = @import("../../dim.zig");

pub fn execute(ctx: dim.Context) !void {
    _ = ctx;
    @panic("gpt-part not implemented yet!");
}

const block_size = 512;

const PartTable = @This();

disk_id: Guid,
partitions: []Partition,

fn render(table: *PartTable, stream: *dim.BinaryStream) dim.Content.RenderError!void {
    {
        var pmbr: [block_size]u8 = @splat(0);
        var efi_prot: *[16]u8 = &pmbr[0x1BE..][0..16];
        std.mem.writeInt(u48, &efi_prot[1], 0x000200, .little);
        efi_prot[4] = 0xEE;
        // TODO: ending CHS
        std.mem.writeInt(u64, &efi_prot[8], 1, .little);
        // TODO: size in LBA

        pmbr[0x01FE] = 0x55;
        pmbr[0x01FF] = 0xAA;

        try stream.write(0, &pmbr);
    }
    {
        var gpt_header: [block_size]u8 = @splat(0);
        @memcpy(&gpt_header[0..8], "EFI PART");
        std.mem.writeInt(u32, &gpt_header[8..12], 0x00010000, .little);
        std.mem.writeInt(u32, &gpt_header[12..16], 96, .little);
        // TODO: header CRC
        std.mem.writeInt(u64, &gpt_header[24..32], 1, .little);
        // TODO: alternate lba
        // TODO: first usable lba
        // TODO: last usable lba
        @memcpy(&gpt_header[56..72], &table.disk_id);
        std.mem.writeInt(u64, &gpt_header[72..80], 2, .little);
        std.mem.writeInt(u32, &gpt_header[80..84], table.partitions.len, .little);
        std.mem.writeInt(u32, &gpt_header[84..88], 128, .little);
        // TODO: partition array CRC
    }
}

pub const Guid = [16]u8;

fn parseGuid(str: []const u8) !Guid {
    @setEvalBranchQuota(4096);

    var guid: Guid = undefined;

    if (str.len != 36 or std.mem.count(u8, str, "-") != 4 or str[8] != '-' or str[13] != '-' or str[18] != '-' or str[23] != '-') {
        return error.InvalidUuid;
    }

    const set_1 = try std.fmt.parseInt(u32, str[0..8], 16);
    const set_2 = try std.fmt.parseInt(u16, str[9..13], 16);
    const set_3 = try std.fmt.parseInt(u16, str[14..18], 16);
    const set_4 = try std.fmt.parseInt(u16, str[19..23], 16);
    const set_5 = try std.fmt.parseInt(u48, str[24..36], 16);

    std.mem.writeInt(u32, &guid[0], set_1, .big);
    std.mem.writeInt(u16, &guid[4], set_2, .big);
    std.mem.writeInt(u16, &guid[6], set_3, .big);
    std.mem.writeInt(u16, &guid[8], set_4, .big);
    std.mem.writeInt(u48, &guid[10], set_5, .big);

    return guid;
}

pub const Partition = struct {
    type: Guid,
    part_id: Guid,

    offset: ?u64 = null,
    size: u64,

    name: [35:0]u16,

    attributes: Attributes,

    data: dim.Content,

    pub const Attributes = packed struct(u32) {
        system: bool,
        efi_hidden: bool,
        legacy: bool,
        read_only: bool,
        hidden: bool,
        no_automount: bool,

        padding: u10 = 0,
        user: u16,
    };
};

/// https://en.wikipedia.org/wiki/GUID_Partition_Table#Partition_type_GUIDs
pub const PartitionType = struct {
    pub const unused: Guid = parseGuid("00000000-0000-0000-0000-000000000000") catch unreachable;

    pub const esp: Guid = parseGuid("C12A7328-F81F-11D2-BA4B-00A0C93EC93B") catch unreachable;
    pub const legacy_mbr: Guid = parseGuid("024DEE41-33E7-11D3-9D69-0008C781F39F") catch unreachable;
    pub const bios_boot: Guid = parseGuid("21686148-6449-6E6F-744E-656564454649") catch unreachable;

    pub const microsoft_basic_data: Guid = parseGuid("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7") catch unreachable;
    pub const microsoft_reserved: Guid = parseGuid("E3C9E316-0B5C-4DB8-817D-F92DF00215AE") catch unreachable;

    pub const windows_recovery: Guid = parseGuid("DE94BBA4-06D1-4D40-A16A-BFD50179D6AC") catch unreachable;

    pub const plan9: Guid = parseGuid("C91818F9-8025-47AF-89D2-F030D7000C2C") catch unreachable;

    pub const linux_swap: Guid = parseGuid("0657FD6D-A4AB-43C4-84E5-0933C84B4F4F") catch unreachable;
    pub const linux_fs: Guid = parseGuid("0FC63DAF-8483-4772-8E79-3D69D8477DE4") catch unreachable;
    pub const linux_reserved: Guid = parseGuid("8DA63339-0007-60C0-C436-083AC8230908") catch unreachable;
    pub const linux_lvm: Guid = parseGuid("E6D6D379-F507-44C2-A23C-238F2A3DF928") catch unreachable;
};

pub fn nameLiteral(comptime name: []const u8) [35:0]u16 {
    return comptime blk: {
        var buf: [35:0]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(&buf, name) catch |err| @compileError(@tagName(err));
        @memset(buf[len..], 0);
        break :blk &buf;
    };
}
