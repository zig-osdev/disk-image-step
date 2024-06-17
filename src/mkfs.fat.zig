const std = @import("std");
const fatfs = @import("fat");
const shared = @import("shared.zig");

const App = shared.App(@This());

pub const main = App.main;

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .fatfs, .level = .warn },
    },
};

var fat_disk: fatfs.Disk = fatfs.Disk{
    .getStatusFn = disk_getStatus,
    .initializeFn = disk_initialize,
    .readFn = disk_read,
    .writeFn = disk_write,
    .ioctlFn = disk_ioctl,
};

var filesystem_format: fatfs.DiskFormat = undefined;

var filesystem: fatfs.FileSystem = undefined;

const format_mapping = std.StaticStringMap(fatfs.DiskFormat).initComptime(&.{
    .{ "fat12", .fat },
    .{ "fat16", .fat },
    .{ "fat32", .fat32 },
    .{ "exfat", .exfat },
});

pub fn init(file_system: []const u8) !void {
    filesystem_format = format_mapping.get(file_system) orelse return error.InvalidFilesystem;
    fatfs.disks[0] = &fat_disk;
}

pub fn format() !void {
    var workspace: [8192]u8 = undefined;
    try fatfs.mkfs("0:", .{
        .filesystem = filesystem_format,
        .fats = .two,
        .sector_align = 0, // default/auto
        .rootdir_size = 512, // randomly chosen, might need adjustment
        .use_partitions = false,
    }, &workspace);
}

pub fn mount() !void {
    try filesystem.mount("0:", true);
}

pub fn mkdir(path: []const u8) !void {
    const joined = try std.mem.concatWithSentinel(App.allocator, u8, &.{ "0:/", path }, 0);
    fatfs.mkdir(joined) catch |err| switch (err) {
        error.Exist => {}, // this is good
        else => |e| return e,
    };
}

pub fn mkfile(path: []const u8, host_file: std.fs.File) !void {
    const path_z = try App.allocator.dupeZ(u8, path);
    defer App.allocator.free(path_z);

    const stat = try host_file.stat();

    const size = std.math.cast(u32, stat.size) orelse return error.FileTooBig;

    _ = size;

    var fs_file = try fatfs.File.create(path_z);
    defer fs_file.close();

    var fifo = std.fifo.LinearFifo(u8, .{ .Static = 8192 }).init();
    try fifo.pump(
        host_file.reader(),
        fs_file.writer(),
    );
}

fn disk_getStatus(intf: *fatfs.Disk) fatfs.Disk.Status {
    _ = intf;
    return fatfs.Disk.Status{
        .initialized = true,
        .disk_present = true,
        .write_protected = false,
    };
}

fn disk_initialize(intf: *fatfs.Disk) fatfs.Disk.Error!fatfs.Disk.Status {
    return disk_getStatus(intf);
}

fn disk_read(intf: *fatfs.Disk, buff: [*]u8, sector: fatfs.LBA, count: c_uint) fatfs.Disk.Error!void {
    _ = intf;

    const blocks = std.mem.bytesAsSlice(shared.Block, buff[0 .. count * shared.BlockDevice.block_size]);
    for (blocks, 0..) |*block, i| {
        block.* = App.device.read(sector + i) catch return error.IoError;
    }
}

fn disk_write(intf: *fatfs.Disk, buff: [*]const u8, sector: fatfs.LBA, count: c_uint) fatfs.Disk.Error!void {
    _ = intf;

    const block_ptr = @as([*]const [512]u8, @ptrCast(buff));

    var i: usize = 0;
    while (i < count) : (i += 1) {
        App.device.write(sector + i, block_ptr[i]) catch return error.IoError;
    }
}

fn disk_ioctl(intf: *fatfs.Disk, cmd: fatfs.IoCtl, buff: [*]u8) fatfs.Disk.Error!void {
    _ = intf;

    switch (cmd) {
        .sync => App.device.file.sync() catch return error.IoError,

        .get_sector_count => {
            const size: *fatfs.LBA = @ptrCast(@alignCast(buff));
            size.* = @intCast(App.device.count);
        },
        .get_sector_size => {
            const size: *fatfs.WORD = @ptrCast(@alignCast(buff));
            size.* = 512;
        },
        .get_block_size => {
            const size: *fatfs.DWORD = @ptrCast(@alignCast(buff));
            size.* = 1;
        },

        else => return error.InvalidParameter,
    }
}
