const std = @import("std");
const dim = @import("../../dim.zig");

pub fn execute(ctx: dim.Context) !void {
    _ = ctx;
    @panic("gpt-part not implemented yet!");
}

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

        // data: Content,

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
