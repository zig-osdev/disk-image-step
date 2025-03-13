const std = @import("std");
const dim = @import("../../dim.zig");
const common = @import("common.zig");

const fatfs = @import("zfat");

const block_size = 512;
const max_path_len = 8192; // this should be enough

const FAT = @This();

format_as: FatType,
label: ?[]const u8 = null,
ops: std.ArrayList(common.FsOperation),

pub fn parse(ctx: dim.Context) !dim.Content {
    const fat_type = try ctx.parse_enum(FatType);

    const pf = try ctx.alloc_object(FAT);
    pf.* = .{
        .format_as = fat_type,
        .ops = .init(ctx.get_arena()),
    };

    try common.parse_ops(
        ctx,
        "endfat",
        Appender{ .fat = pf },
    );

    return .create_handle(pf, .create(@This(), .{
        .render_fn = render,
    }));
}

const Appender = struct {
    fat: *FAT,

    pub fn append_common_op(self: @This(), op: common.FsOperation) !void {
        try self.fat.ops.append(op);
    }

    pub fn parse_custom_op(self: @This(), ctx: dim.Context, str_op: []const u8) !void {
        const Op = enum { label };
        const op = std.meta.stringToEnum(Op, str_op) orelse return ctx.report_fatal_error(
            "Unknown file system operation '{s}'",
            .{str_op},
        );
        switch (op) {
            .label => {
                self.fat.label = try ctx.parse_string();
            },
        }
    }
};

fn render(self: *FAT, stream: *dim.BinaryStream) dim.Content.RenderError!void {
    var bsd: BinaryStreamDisk = .{ .stream = stream };

    const min_size, const max_size = self.format_as.get_size_limits();

    if (stream.length < min_size) {
        // TODO(fqu): Report fatal erro!
        std.log.err("cannot format {} bytes with {s}: min required size is {}", .{
            @as(dim.DiskSize, @enumFromInt(stream.length)),
            @tagName(self.format_as),
            @as(dim.DiskSize, @enumFromInt(min_size)),
        });
        return;
    }

    if (stream.length > max_size) {
        // TODO(fqu): Report warning
        std.log.warn("will not use all available space: available space is {}, but maximum size for {s} is {}", .{
            @as(dim.DiskSize, @enumFromInt(stream.length)),
            @tagName(self.format_as),
            @as(dim.DiskSize, @enumFromInt(min_size)),
        });
    }

    var filesystem: fatfs.FileSystem = undefined;

    fatfs.disks[0] = &bsd.disk;
    defer fatfs.disks[0] = null;

    var workspace: [8192]u8 = undefined;
    fatfs.mkfs("0:", .{
        .filesystem = self.format_as.get_zfat_type(),
        .fats = .two,
        .sector_align = 0, // default/auto
        .rootdir_size = 512, // randomly chosen, might need adjustment
        .use_partitions = false,
    }, &workspace) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteProtected => @panic("bug in zfat"),
        error.InvalidParameter => @panic("bug in zfat disk wrapper"),
        error.DiskErr => return error.IoError,
        error.NotReady => @panic("bug in zfat disk wrapper"),
        error.InvalidDrive => @panic("bug in AtomicOps"),
        error.MkfsAborted => return error.IoError,
    };

    const ops = self.ops.items;
    if (ops.len > 0) {
        filesystem.mount("0:", true) catch |err| switch (err) {
            error.NotEnabled => @panic("bug in zfat"),
            error.DiskErr => return error.IoError,
            error.NotReady => @panic("bug in zfat disk wrapper"),
            error.InvalidDrive => @panic("bug in AtomicOps"),
            error.NoFilesystem => @panic("bug in zfat"),
        };

        const wrapper = AtomicOps{};

        for (ops) |op| {
            try op.execute(wrapper);
        }
    }
}

const FatType = enum {
    fat12,
    fat16,
    fat32,
    // exfat,

    fn get_zfat_type(fat: FatType) fatfs.DiskFormat {
        return switch (fat) {
            .fat12 => .fat,
            .fat16 => .fat,
            .fat32 => .fat32,
            // .exfat => .exfat,
        };
    }

    fn get_size_limits(fat: FatType) struct { u64, u64 } {
        // see https://en.wikipedia.org/wiki/Design_of_the_FAT_file_system#Size_limits
        return switch (fat) {
            .fat12 => .{ 512, 133_824_512 }, // 512 B ... 127 MB
            .fat16 => .{ 2_091_520, 2_147_090_432 }, // 2042.5 kB ... 2047 MB
            .fat32 => .{ 33_548_800, 1_099_511_578_624 }, // 32762.5 kB ... 1024 GB
        };
    }
};

const AtomicOps = struct {
    pub fn mkdir(ops: AtomicOps, path: []const u8) !void {
        _ = ops;

        var path_buffer: [max_path_len:0]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&path_buffer);

        const joined = try std.mem.concatWithSentinel(fba.allocator(), u8, &.{ "0:/", path }, 0);
        fatfs.mkdir(joined) catch |err| switch (err) {
            error.Exist => {}, // this is good
            else => |e| return e,
        };
    }

    pub fn mkfile(ops: AtomicOps, path: []const u8, host_file: std.fs.File) !void {
        _ = ops;

        var path_buffer: [max_path_len:0]u8 = undefined;
        if (path.len > path_buffer.len)
            return error.InvalidPath;
        @memcpy(path_buffer[0..path.len], path);
        path_buffer[path.len] = 0;

        const path_z = path_buffer[0..path.len :0];

        const stat = try host_file.stat();

        const size = std.math.cast(u32, stat.size) orelse return error.FileTooBig;

        _ = size;

        var fs_file = try fatfs.File.create(path_z);
        defer fs_file.close();

        var fifo: std.fifo.LinearFifo(u8, .{ .Static = 8192 }) = .init();
        try fifo.pump(
            host_file.reader(),
            fs_file.writer(),
        );
    }
};

const BinaryStreamDisk = struct {
    disk: fatfs.Disk = .{
        .getStatusFn = disk_getStatus,
        .initializeFn = disk_initialize,
        .readFn = disk_read,
        .writeFn = disk_write,
        .ioctlFn = disk_ioctl,
    },
    stream: *dim.BinaryStream,

    fn disk_getStatus(intf: *fatfs.Disk) fatfs.Disk.Status {
        _ = intf;
        return .{
            .initialized = true,
            .disk_present = true,
            .write_protected = false,
        };
    }

    fn disk_initialize(intf: *fatfs.Disk) fatfs.Disk.Error!fatfs.Disk.Status {
        return disk_getStatus(intf);
    }

    fn disk_read(intf: *fatfs.Disk, buff: [*]u8, sector: fatfs.LBA, count: c_uint) fatfs.Disk.Error!void {
        const bsd: *BinaryStreamDisk = @fieldParentPtr("disk", intf);

        bsd.stream.read(block_size * sector, buff[0 .. count * block_size]) catch return error.IoError;
    }

    fn disk_write(intf: *fatfs.Disk, buff: [*]const u8, sector: fatfs.LBA, count: c_uint) fatfs.Disk.Error!void {
        const bsd: *BinaryStreamDisk = @fieldParentPtr("disk", intf);

        bsd.stream.write(block_size * sector, buff[0 .. count * block_size]) catch return error.IoError;
    }

    fn disk_ioctl(intf: *fatfs.Disk, cmd: fatfs.IoCtl, buff: [*]u8) fatfs.Disk.Error!void {
        const bsd: *BinaryStreamDisk = @fieldParentPtr("disk", intf);

        switch (cmd) {
            .sync => {},

            .get_sector_count => {
                const size: *fatfs.LBA = @ptrCast(@alignCast(buff));
                size.* = @intCast(bsd.stream.length / block_size);
            },
            .get_sector_size => {
                const size: *fatfs.WORD = @ptrCast(@alignCast(buff));
                size.* = block_size;
            },
            .get_block_size => {
                const size: *fatfs.DWORD = @ptrCast(@alignCast(buff));
                size.* = 1;
            },

            else => return error.InvalidParameter,
        }
    }
};
